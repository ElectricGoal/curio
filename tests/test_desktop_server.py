"""Persistent serve loop: request ids, queueing, cancellation, shutdown."""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

from imgsearch.desktop.server import serve


def _run(lines: list[dict | str], **kwargs) -> list[dict]:
    """Feed requests to a serve loop and return everything it emitted."""
    text = "".join((line if isinstance(line, str) else json.dumps(line)) + "\n" for line in lines)
    events: list[dict] = []
    lock = threading.Lock()

    def emit(event: dict) -> None:
        with lock:
            events.append(event)

    assert serve(io.StringIO(text), emit, **kwargs) == 0
    return events


def _final(events: list[dict], request_id: str) -> dict:
    return next(e for e in events if e.get("id") == request_id and e["type"] != "progress")


def test_serve_announces_ready_and_tags_responses(color_engine, photo_folder):
    folder = str(photo_folder)
    events = _run(
        [
            {"id": "i", "action": "index", "folder": folder, "model": "clip-vit-b32"},
            {"id": "s", "action": "search", "folder": folder, "text": "red", "k": 1},
            {"id": "m", "action": "models"},
        ]
    )

    assert events[0] == {"type": "ready"}
    assert _final(events, "i")["data"]["count"] == 6
    assert _final(events, "s")["data"]["images"][0]["name"].startswith("red")
    assert _final(events, "m")["data"]["models"]
    assert all(e.get("id") == "i" for e in events if e.get("message") == "Indexing images")
    # One model instance served both the index and the search.
    assert len(color_engine.created) == 1


def test_serve_survives_bad_requests(color_engine, photo_folder):
    events = _run(
        [
            "this is not json",
            "[1, 2, 3]",
            {"id": "x", "action": "teleport"},
            {"id": "y", "action": "search", "folder": str(photo_folder / "missing"), "text": "red"},
            {"id": "ok", "action": "models"},
        ]
    )

    assert sum(1 for e in events if e.get("message") == "Malformed request") == 2
    assert _final(events, "x")["type"] == "error"
    assert "Unknown action" in _final(events, "x")["message"]
    assert "does not exist" in _final(events, "y")["message"]
    assert _final(events, "ok")["type"] == "result"


def _wait_for_reader_to_finish() -> None:
    """Block until the serve loop's reader thread has consumed all its input."""
    while any(thread.name == "imgsearch-reader" for thread in threading.enumerate()):
        time.sleep(0.005)


def test_serve_cancels_a_queued_request(color_engine, photo_folder):
    folder = str(photo_folder)
    # Hold the index until every line (including the cancel) has been read,
    # so the search is guaranteed to still be queued when it is cancelled.
    color_engine.before_encode = lambda size: _wait_for_reader_to_finish()
    events = _run(
        [
            {"id": "i", "action": "index", "folder": folder, "model": "clip-vit-b32"},
            {"id": "s", "action": "search", "folder": folder, "text": "red"},
            {"action": "cancel", "target": "s"},
            {"id": "after", "action": "search", "folder": folder, "text": "blue", "k": 1},
        ]
    )

    assert _final(events, "s") == {
        "id": "s",
        "type": "error",
        "code": "cancelled",
        "message": "Cancelled",
    }
    assert _final(events, "i")["data"]["count"] == 6
    assert _final(events, "after")["data"]["images"][0]["name"].startswith("blue")


def test_serve_rejects_ids_it_cannot_track(color_engine):
    events = _run(
        [
            {"id": ["not", "hashable"], "action": "models"},
            {"action": "cancel", "target": {"also": "unhashable"}},
            {"id": "ok", "action": "models"},
        ]
    )

    assert sum(1 for e in events if e.get("message") == "Malformed request") == 1
    assert _final(events, "ok")["type"] == "result"


def test_serve_refuses_a_duplicate_in_flight_id(color_engine, photo_folder):
    folder = str(photo_folder)
    color_engine.before_encode = lambda size: _wait_for_reader_to_finish()
    events = _run(
        [
            {"id": "same", "action": "index", "folder": folder, "model": "clip-vit-b32"},
            {"id": "same", "action": "search", "folder": folder, "text": "red"},
        ]
    )

    replies = [e for e in events if e.get("id") == "same" and e["type"] != "progress"]
    assert sorted(e["type"] for e in replies) == ["error", "result"]
    assert "already running" in next(e for e in replies if e["type"] == "error")["message"]


def test_unserialisable_result_becomes_an_error(color_engine, monkeypatch):
    from imgsearch.desktop import model_store
    from imgsearch.desktop.server import Engine

    monkeypatch.setattr(model_store, "list_models", lambda root: {"models": object()})
    lines: list[str] = []
    engine = Engine(lambda event: lines.append(json.dumps(event)))

    engine.handle({"id": "m", "action": "models"}, threading.Event())

    assert [json.loads(line)["type"] for line in lines] == ["error"]


def test_engine_stops_when_the_app_that_launched_it_dies(tmp_path):
    """An orphaned engine must not keep working unseen."""
    root = Path(__file__).resolve().parents[1]
    env = {**os.environ, "IMGSEARCH_PROJECT_ROOT": str(tmp_path), "PYTHONPATH": str(root / "src")}
    pid_file = tmp_path / "engine.pid"
    # A stand-in "app": starts the engine with stdin held open, then dies abruptly.
    launcher = (
        "import os, subprocess, sys, time\n"
        "read_end, write_end = os.pipe()\n"
        "engine = subprocess.Popen([sys.executable, '-m', 'imgsearch.desktop', '--serve'],"
        " stdin=read_end, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, pass_fds=[write_end])\n"
        f"open({str(pid_file)!r}, 'w').write(str(engine.pid))\n"
        "time.sleep(1.5)\n"
        "os._exit(0)\n"
    )
    subprocess.run([sys.executable, "-c", launcher], env=env, check=True, timeout=60)
    engine_pid = int(pid_file.read_text())

    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            os.kill(engine_pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.1)
    os.kill(engine_pid, 9)
    raise AssertionError("engine kept running after its parent died")


def test_serve_unloads_model_when_idle(color_engine, photo_folder, monkeypatch):
    from imgsearch.desktop import session

    released: list[bool] = []
    original = session.EmbedderCache.release

    def tracking_release(self):
        released.append(self.is_loaded())
        original(self)

    monkeypatch.setattr(session.EmbedderCache, "release", tracking_release)
    read_end, write_end = os.pipe()
    events: list[dict] = []
    done = threading.Event()

    def emit(event: dict) -> None:
        events.append(event)
        if event.get("id") == "w" and event["type"] == "result":
            # Stay connected long enough for the idle timer to fire, then hang up.
            threading.Timer(0.5, lambda: (os.close(write_end), done.set())).start()

    folder = str(photo_folder)
    with os.fdopen(read_end) as stdin:
        os.write(
            write_end,
            (
                json.dumps(
                    {"id": "i", "action": "index", "folder": folder, "model": "clip-vit-b32"}
                )
                + "\n"
                + json.dumps({"id": "w", "action": "warm", "folder": folder})
                + "\n"
            ).encode(),
        )
        assert serve(stdin, emit, idle_unload_seconds=0.1) == 0
    assert done.is_set()
    assert True in released  # a loaded model was dropped while idle


def test_serve_subprocess_speaks_the_protocol_on_stdout_only(tmp_path):
    root = Path(__file__).resolve().parents[1]
    env = {**os.environ, "IMGSEARCH_PROJECT_ROOT": str(tmp_path), "PYTHONPATH": str(root / "src")}
    requests = [
        {"id": "1", "action": "models"},
        {"id": "2", "action": "status", "folder": str(tmp_path)},
    ]
    completed = subprocess.run(
        [sys.executable, "-m", "imgsearch.desktop", "--serve"],
        input="".join(json.dumps(r) + "\n" for r in requests),
        capture_output=True,
        text=True,
        env=env,
        timeout=120,
        check=True,
    )

    events = [json.loads(line) for line in completed.stdout.splitlines()]
    assert events[0] == {"type": "ready"}
    assert {e["id"] for e in events[1:]} == {"1", "2"}
    assert all(e["type"] == "result" for e in events[1:])


def test_one_shot_mode_still_answers_a_single_request(tmp_path):
    root = Path(__file__).resolve().parents[1]
    env = {**os.environ, "IMGSEARCH_PROJECT_ROOT": str(tmp_path), "PYTHONPATH": str(root / "src")}
    completed = subprocess.run(
        [sys.executable, "-m", "imgsearch.desktop"],
        input=json.dumps({"action": "models"}) + "\n",
        capture_output=True,
        text=True,
        env=env,
        timeout=120,
        check=True,
    )
    response = json.loads(completed.stdout.splitlines()[-1])
    assert response["type"] == "result"
    assert response["data"]["storage"] == str(tmp_path / "models")
