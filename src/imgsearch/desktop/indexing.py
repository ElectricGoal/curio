"""Build or update a folder's search index with progress, cancel and checkpoints."""

from __future__ import annotations

import contextlib
import shutil
import time
import uuid
from collections.abc import Iterator
from pathlib import Path
from typing import Any, Final

from imgsearch.config import (
    DEFAULT_MODEL_ALIAS,
    INDEX_DIR_NAME,
    MANIFEST_FILE,
    MODEL_REGISTRY,
    resolve_model,
)
from imgsearch.desktop import estimate
from imgsearch.desktop.library import read_manifest, read_skipped, write_skipped
from imgsearch.desktop.session import Cancelled, Session
from imgsearch.desktop.storage import mark_model_complete

# Persist to disk this often so quitting or crashing mid-run loses little work.
CHECKPOINT_SECONDS: Final = 60.0
DEFAULT_BATCH: Final = 8
MAX_BATCH: Final = 128
_BACKUP_PREFIX: Final = INDEX_DIR_NAME + "-backup-"


def _backups(folder: Path) -> list[Path]:
    return sorted(
        (p for p in folder.glob(_BACKUP_PREFIX + "*") if p.is_dir() and not p.is_symlink()),
        key=lambda p: p.stat().st_mtime,
    )


def has_interrupted_rebuild(folder: Path) -> bool:
    """Whether a parked index exists (a rebuild is running, or one crashed)."""
    return bool(_backups(folder))


def recover_interrupted_rebuild(folder: Path) -> None:
    """Tidy up after a rebuild that died before it could restore or drop its backup.

    A rebuild writes its manifest only once, at the very end, so a missing
    manifest means the replacement never finished: the newest backup is put
    back. Leftover backups are removed either way. Call this only while
    holding the engine lock, so a rebuild in progress is never mistaken for a
    dead one.
    """
    backups = _backups(folder)
    if not backups:
        return
    index_dir = folder / INDEX_DIR_NAME
    if not (index_dir / MANIFEST_FILE).exists() and not index_dir.is_symlink():
        if index_dir.exists():
            shutil.rmtree(index_dir)
        backups.pop().rename(index_dir)
    for leftover in backups:
        shutil.rmtree(leftover, ignore_errors=True)


@contextlib.contextmanager
def replacing_index(folder: Path) -> Iterator[None]:
    """Set the current index aside; restore it if the block fails or is cancelled."""
    index_dir = folder / INDEX_DIR_NAME
    if index_dir.is_symlink():
        raise ValueError("Refusing to rebuild a symlinked index")
    backup: Path | None = None
    if index_dir.exists():
        backup = index_dir.with_name(_BACKUP_PREFIX + uuid.uuid4().hex)
        index_dir.rename(backup)
    try:
        yield
    except BaseException:
        if backup is not None:
            if index_dir.exists():
                shutil.rmtree(index_dir)
            backup.rename(index_dir)
        raise
    if backup is not None:
        # The new index is complete; a leftover backup is cleaned up next time.
        shutil.rmtree(backup, ignore_errors=True)


def _batch_size(request: dict[str, Any]) -> int:
    try:
        return max(1, min(MAX_BATCH, int(request.get("batch", DEFAULT_BATCH))))
    except (TypeError, ValueError) as exc:
        raise ValueError("Batch size must be a whole number.") from exc


def _model_alias(folder: Path, request: dict[str, Any], rebuild: bool) -> str:
    """An update continues with the index's own model; only a rebuild switches."""
    requested = request.get("model") or DEFAULT_MODEL_ALIAS
    if rebuild:
        return requested
    existing = (read_manifest(folder) or {}).get("model_alias")
    if existing and existing not in MODEL_REGISTRY:
        raise ValueError(
            f"This folder was indexed with a model that is no longer available ({existing}). "
            "Rebuild its index to continue."
        )
    return existing or requested


def run_index(session: Session, folder: Path, request: dict[str, Any]) -> dict[str, Any]:
    rebuild = bool(request.get("rebuild"))
    alias = _model_alias(folder, request, rebuild)
    spec = resolve_model(alias)
    batch = _batch_size(request)
    recover_interrupted_rebuild(folder)
    expected = _expected_images(request)
    if not rebuild:
        return _update(session, folder, alias, spec, batch, expected, keep_partial=True)
    with replacing_index(folder):
        return _update(session, folder, alias, spec, batch, expected, keep_partial=False)


def _expected_images(request: dict[str, Any]) -> int | None:
    """The app's count of images to index, used only to estimate time up front."""
    value = request.get("expected")
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def _update(
    session: Session,
    folder: Path,
    alias: str,
    spec: Any,
    batch: int,
    expected: int | None,
    *,
    keep_partial: bool,
) -> dict[str, Any]:
    from imgsearch.commands.index import _chunks, _embed_prepared, _prefetch_batches
    from imgsearch.core.index import Index
    from imgsearch.core.scanner import scan

    started = time.monotonic()
    # Creating the embedder imports torch before FAISS, which macOS requires.
    embedder = session.embedders.get(alias, spec)
    timings = estimate.timings_for(session.root)
    progress = estimate.IndexProgress(
        timings.get(alias), model_loaded=session.embedders.is_loaded(alias), expected=expected
    )
    with Index(folder, spec, alias) as index:
        index.open(create=True)
        session.progress("Scanning images", estimate=progress.scanning())
        discovered = list(scan(folder))
        plan = index.plan(discovered)
        index.apply_deletes(plan.to_delete_ids)
        index.apply_mtime_touches(plan.to_touch_mtime)
        on_disk = {entry.rel_path for entry in discovered}
        skipped = {path: mtime for path, mtime in read_skipped(folder).items() if path in on_disk}
        total = len(plan.to_embed)
        processed = added = failed = 0
        cancelled = False
        if total:
            session.check_cancelled()
            if not session.embedders.is_loaded(alias):
                session.progress("Loading model", estimate=progress.loading(total))
                load_started = time.monotonic()
                embedder = session.embedders.load(alias, spec)
                timings.record(alias, load_seconds=time.monotonic() - load_started)
            embedder = session.embedders.load(alias, spec)
            mark_model_complete(session.root, spec)
            progress.embedding_started()
            session.progress(
                "Indexing images", 0, total, "images", estimate=progress.embedding(0, total)
            )
            chunks = _chunks(plan.to_embed, batch)
            checkpoint = time.monotonic()
            try:
                # closing() stops the loader thread promptly when we leave early.
                with contextlib.closing(_prefetch_batches(chunks, spec.image_size)) as batches:
                    for chunk, prepared in zip(chunks, batches, strict=False):
                        files, vectors, hashes, dims, failures = _embed_prepared(embedder, prepared)
                        index.add_batch(files, vectors, hashes, dims)
                        for entry, loaded in zip(chunk, prepared, strict=True):
                            if loaded is None:
                                skipped[entry.rel_path] = entry.mtime
                            else:
                                skipped.pop(entry.rel_path, None)
                        processed += len(prepared)
                        added += len(files)
                        failed += failures
                        session.progress(
                            "Indexing images",
                            processed,
                            total,
                            "images",
                            estimate=progress.embedding(processed, total),
                        )
                        if session.cancelled.is_set():
                            if not keep_partial:
                                raise Cancelled()
                            cancelled = True
                            break
                        # A rebuild is all-or-nothing: checkpointing it would make a
                        # half-built index look finished to crash recovery.
                        if keep_partial and time.monotonic() - checkpoint >= CHECKPOINT_SECONDS:
                            index.commit()
                            checkpoint = time.monotonic()
            except Exception:
                if keep_partial:
                    # Keep the batches that did succeed; the next update resumes.
                    with contextlib.suppress(Exception):
                        index.commit()
                raise
            timings.record(alias, images_per_second=progress.measured_rate())
        session.progress("Saving search index", estimate=progress.saving())
        index.commit()
        write_skipped(folder, skipped)
        return {
            "count": index.count,
            "added": added,
            "skipped": failed,
            "removed": len(plan.to_delete_ids),
            "remaining": total - processed,
            "cancelled": cancelled,
            "model": alias,
            "model_name": spec.display_name,
            "seconds": round(time.monotonic() - started, 2),
        }
