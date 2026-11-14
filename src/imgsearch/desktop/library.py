"""Read-only views of a photo folder: file listing and index freshness."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any

from imgsearch.config import FAISS_FILE, INDEX_DIR_NAME, MANIFEST_FILE, META_DB_FILE, MODEL_REGISTRY

SKIPPED_FILE = "skipped.json"


def folder_path(request: dict[str, Any]) -> Path:
    raw = request.get("folder")
    if not isinstance(raw, str) or not raw:
        raise ValueError("Choose a folder first.")
    path = Path(raw).expanduser().resolve()
    if not path.is_dir():
        raise ValueError(f"Folder does not exist: {path}")
    return path


def image_record(path: Path) -> dict[str, Any]:
    stat = path.stat()
    return {"path": str(path), "name": path.name, "size": stat.st_size, "modified": stat.st_mtime}


def read_manifest(folder: Path) -> dict[str, Any] | None:
    """The folder's index manifest, or None when there is no usable index."""
    index_dir = folder / INDEX_DIR_NAME
    if not all((index_dir / name).exists() for name in (MANIFEST_FILE, META_DB_FILE, FAISS_FILE)):
        return None
    try:
        manifest = json.loads((index_dir / MANIFEST_FILE).read_text())
    except (OSError, ValueError):
        return None
    return manifest if isinstance(manifest, dict) else None


def read_skipped(folder: Path) -> dict[str, float]:
    """Images the last index run could not decode, keyed by relative path → mtime."""
    try:
        data = json.loads((folder / INDEX_DIR_NAME / SKIPPED_FILE).read_text())
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {str(k): float(v) for k, v in data.items() if isinstance(v, int | float)}


def write_skipped(folder: Path, skipped: dict[str, float]) -> None:
    path = folder / INDEX_DIR_NAME / SKIPPED_FILE
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(skipped, indent=2, sort_keys=True))
    tmp.replace(path)


def browse(folder: Path) -> dict[str, Any]:
    from imgsearch.core.scanner import scan

    images = []
    for entry in scan(folder):
        try:
            images.append(image_record(entry.abs_path))
        except OSError:
            continue
    images.sort(key=lambda item: item["path"].casefold())
    return {"images": images, "total": len(images)}


def _indexed_mtimes(meta_db: Path) -> dict[str, float]:
    """Read path → mtime straight from SQLite, without touching the index files."""
    connection = sqlite3.connect(f"file:{meta_db}?mode=ro", uri=True)
    try:
        return dict(connection.execute("SELECT rel_path, mtime FROM images"))
    finally:
        connection.close()


def status(folder: Path) -> dict[str, Any]:
    """How much of the folder is searchable, and how much work an update would be."""
    from imgsearch.core.scanner import scan

    on_disk = {entry.rel_path: entry.mtime for entry in scan(folder)}
    manifest = read_manifest(folder)
    indexed: dict[str, float] = {}
    if manifest is not None:
        try:
            indexed = _indexed_mtimes(folder / INDEX_DIR_NAME / META_DB_FILE)
        except sqlite3.Error:
            manifest = None  # being replaced right now; report it as not ready
    if manifest is None:
        return {
            "indexed": False,
            "total": len(on_disk),
            "count": 0,
            "pending": len(on_disk),
            "missing": 0,
            "unreadable": 0,
            "model": None,
            "model_name": None,
            "model_available": None,
            "updated_at": None,
        }
    skipped = read_skipped(folder)
    unreadable = sum(1 for path, mtime in on_disk.items() if skipped.get(path) == mtime)
    stale = sum(1 for path, mtime in on_disk.items() if indexed.get(path) != mtime)
    alias = manifest.get("model_alias") or None
    spec = MODEL_REGISTRY.get(alias) if alias else None
    return {
        "indexed": True,
        "total": len(on_disk),
        "count": len(indexed),
        "pending": max(0, stale - unreadable),
        "missing": sum(1 for path in indexed if path not in on_disk),
        "unreadable": unreadable,
        "model": alias,
        "model_name": spec.display_name if spec else manifest.get("model_id"),
        # False when the index was built with a model this app no longer offers.
        "model_available": spec is not None,
        "updated_at": manifest.get("updated_at"),
    }
