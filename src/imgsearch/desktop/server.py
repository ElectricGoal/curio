"""Request routing for the desktop engine: one-shot and persistent modes."""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import queue
import sys
import threading
import time
from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Final, TextIO

from imgsearch.desktop import indexing, library, model_store, searching
from imgsearch.desktop.session import Cancelled, EmbedderCache, Emit, Session
from imgsearch.desktop.storage import LOCK_RELATIVE, configure_storage

# Quick, read-only actions answered immediately, even while an index is running.
LIGHT_ACTIONS: Final = frozenset({"models", "status", "browse"})
# Actions that must not overlap with another engine process or the CLI.
EXCLUSIVE_ACTIONS: Final = frozenset(
    {"index", "search", "duplicates", "download_model", "delete_model"}
)
IDLE_UNLOAD_SECONDS: Final = 600.0
_BUSY_MESSAGE: Final = "Another indexing, search, or model operation is running."
_PARENT_POLL_SECONDS: Final = 1.0


class Busy(ValueError):
    """Another process holds the engine lock."""


@contextlib.contextmanager
def _exclusive(root: Path) -> Iterator[None]:
    lock_path = root / LOCK_RELATIVE
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Busy(_BUSY_MESSAGE) from exc
        yield


def _route(session: Session, request: dict[str, Any]) -> Any:
    action = request.get("action")
    if action == "models":
        return model_store.list_models(session.root)
    if action == "download_model":
        return model_store.download_model(session, _model_argument(request))
    if action == "delete_model":
        return model_store.delete_model(session, _model_argument(request))
    if action not in ("browse", "status", "warm", "index", "search", "duplicates"):
        raise ValueError(f"Unknown action: {action}")
    folder = library.folder_path(request)
    if action == "browse":
        return library.browse(folder)
    if action == "status":
        _recover_if_idle(session.root, folder)
        return library.status(folder)
    if action == "warm":
        return searching.warm(session, folder)
    if action == "index":
        return indexing.run_index(session, folder, request)
    if action == "search":
        return searching.run_search(session, folder, request)
    return searching.run_duplicates(session, folder, request)


def _recover_if_idle(root: Path, folder: Path) -> None:
    """Restore an index left parked by a rebuild that crashed.

    Only when nothing holds the engine lock: a backup directory is also what a
    rebuild that is running right now looks like.
    """
    if not indexing.has_interrupted_rebuild(folder):
        return
    with contextlib.suppress(Busy), _exclusive(root):
        indexing.recover_interrupted_rebuild(folder)


def _model_argument(request: dict[str, Any]) -> str:
    model = request.get("model")
    if not isinstance(model, str) or not model:
        raise ValueError("Choose a model first.")
    return model


def _execute(session: Session, request: dict[str, Any]) -> Any:
    session.check_cancelled()
    if request.get("action") not in EXCLUSIVE_ACTIONS:
        return _route(session, request)
    with _exclusive(session.root):
        return _route(session, request)


def dispatch(request: dict[str, Any], emit: Emit = lambda event: None) -> Any:
    """Answer one request with a fresh session. Raises on failure."""
    session = Session(
        root=configure_storage(),
        emit=emit,
        cancelled=threading.Event(),
        embedders=EmbedderCache(),
    )
    return _execute(session, request)


class Engine:
    """Answers many requests, keeping the model warm between them."""

    def __init__(self, emit: Emit) -> None:
        self._emit = emit
        self._root = configure_storage()
        self._embedders = EmbedderCache()

    def handle(self, request: dict[str, Any], cancelled: threading.Event) -> None:
        """Run one request to completion and emit exactly one result or error."""
        request_id = request.get("id")

        def tagged(event: dict[str, Any]) -> None:
            self._emit({"id": request_id, **event})

        # Light actions run on helper threads and must not share the model cache.
        light = request.get("action") in LIGHT_ACTIONS
        session = Session(
            root=self._root,
            emit=tagged,
            cancelled=cancelled,
            embedders=EmbedderCache() if light else self._embedders,
        )
        try:
            data = _execute(session, request)
            # Emitted inside the try: a reply that cannot be serialised must
            # still end the request with an error rather than with silence.
            tagged({"type": "result", "data": data})
        except Cancelled:
            tagged({"type": "error", "code": "cancelled", "message": "Cancelled"})
        except Busy as exc:
            tagged({"type": "error", "code": "busy", "message": str(exc)})
        except Exception as exc:
            sys.stderr.write(f"imgsearch: {request.get('action')} failed: {exc!r}\n")
            tagged({"type": "error", "code": "failed", "message": str(exc) or type(exc).__name__})

    def unload(self) -> None:
        self._embedders.release()


def serve(
    stdin: TextIO,
    emit: Emit,
    *,
    idle_unload_seconds: float = IDLE_UNLOAD_SECONDS,
    stop_with_parent: bool = False,
) -> int:
    """Answer requests from ``stdin`` until it closes.

    Heavy work runs one request at a time on this thread (model frameworks are
    happiest on the main thread). A reader thread keeps accepting input so a
    ``cancel`` message or a quick status check is never stuck behind an index.

    Closing ``stdin`` lets queued work finish. With ``stop_with_parent``, the
    engine also cancels everything if the app that launched it disappears, so
    a crashed app never leaves an index running unseen.
    """
    engine = Engine(emit)
    work: queue.Queue[tuple[dict[str, Any], threading.Event] | None] = queue.Queue()
    cancels: dict[Any, threading.Event] = {}
    guard = threading.Lock()
    helpers = ThreadPoolExecutor(max_workers=2, thread_name_prefix="imgsearch-light")

    def finish(request: dict[str, Any], cancelled: threading.Event) -> None:
        try:
            engine.handle(request, cancelled)
        except Exception as exc:  # handle() reports its own failures; this is the last resort
            sys.stderr.write(f"imgsearch: could not reply to {request.get('id')!r}: {exc!r}\n")
        finally:
            with guard:
                if cancels.get(request.get("id")) is cancelled:
                    del cancels[request.get("id")]

    def accept(line: str) -> None:
        try:
            request = json.loads(line)
        except ValueError:
            request = None
        if not isinstance(request, dict) or not _valid_id(request.get("id")):
            emit({"type": "error", "code": "failed", "message": "Malformed request"})
            return
        if request.get("action") == "cancel":
            target = request.get("target")
            with guard:
                event = cancels.get(target) if _valid_id(target) else None
            if event is not None:
                event.set()
            return
        cancelled = threading.Event()
        with guard:
            if request.get("id") in cancels:
                duplicate = True
            else:
                duplicate = False
                cancels[request.get("id")] = cancelled
        if duplicate:
            emit(
                {
                    "id": request.get("id"),
                    "type": "error",
                    "code": "failed",
                    "message": "A request with this id is already running",
                }
            )
        elif request.get("action") in LIGHT_ACTIONS:
            helpers.submit(finish, request, cancelled)
        else:
            work.put((request, cancelled))

    def cancel_everything() -> None:
        with guard:
            for event in cancels.values():
                event.set()

    def read() -> None:
        try:
            for line in stdin:
                if line.strip():
                    accept(line)
        except Exception as exc:
            sys.stderr.write(f"imgsearch: stopped reading requests: {exc!r}\n")
        finally:
            work.put(None)  # input closed: finish what is queued, then stop

    def watch_parent(parent: int) -> None:
        while os.getppid() == parent:
            time.sleep(_PARENT_POLL_SECONDS)
        cancel_everything()
        work.put(None)

    emit({"type": "ready"})
    threading.Thread(target=read, daemon=True, name="imgsearch-reader").start()
    if stop_with_parent:
        threading.Thread(
            target=watch_parent, args=(os.getppid(),), daemon=True, name="imgsearch-parent-watch"
        ).start()
    while True:
        try:
            item = work.get(timeout=idle_unload_seconds)
        except queue.Empty:
            engine.unload()  # idle: give the model's memory back
            continue
        if item is None:
            break
        finish(*item)
    helpers.shutdown(wait=True)
    return 0


def _valid_id(value: Any) -> bool:
    """Request ids key the cancel table, so they must be absent or simple."""
    return value is None or isinstance(value, str | int)


def _claim_stdout() -> TextIO:
    """Reserve the real stdout for protocol lines.

    Model libraries (and native code beneath them) occasionally print to
    stdout; pointing file descriptor 1 at stderr keeps that noise out of the
    JSON stream the app parses.
    """
    sys.stdout.flush()
    protocol = os.fdopen(os.dup(1), "w", encoding="utf-8")
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    return protocol


def _line_emitter(output: TextIO) -> Emit:
    guard = threading.Lock()

    def emit(event: dict[str, Any]) -> None:
        line = json.dumps(event)
        with guard:
            output.write(line + "\n")
            output.flush()

    return emit


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    emit = _line_emitter(_claim_stdout())
    # Undecodable bytes must not end the session; they fail as one bad request.
    sys.stdin.reconfigure(errors="replace")
    if "--serve" in arguments:
        return serve(sys.stdin, emit, stop_with_parent=True)
    try:
        request = json.loads(sys.stdin.readline())
        if not isinstance(request, dict):
            raise ValueError("Malformed request")
        emit({"type": "result", "data": dispatch(request, emit)})
    except Exception as exc:
        emit({"type": "error", "code": "failed", "message": str(exc) or type(exc).__name__})
        return 1
    return 0
