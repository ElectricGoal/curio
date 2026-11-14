"""Project-local storage layout shared by every desktop engine action."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Final

from imgsearch.config import ModelSpec

HUB_RELATIVE: Final = "models/huggingface/hub"
COMPLETE_MARKER: Final = ".imgsearch-complete"
LOCK_RELATIVE: Final = ".runtime/desktop.lock"

_ENVIRONMENT: Final[dict[str, str]] = {
    "HF_HOME": "models/huggingface",
    "HF_HUB_CACHE": HUB_RELATIVE,
    "TORCH_HOME": "models/torch",
    "XDG_CACHE_HOME": ".cache",
    "TMPDIR": ".runtime/tmp",
}


def configure_storage() -> Path:
    """Point model caches and temp files into the project and return its root."""
    root = Path(
        os.environ.get("IMGSEARCH_PROJECT_ROOT", Path(__file__).resolve().parents[3])
    ).resolve()
    for key, relative in _ENVIRONMENT.items():
        path = root / relative
        path.mkdir(parents=True, exist_ok=True)
        os.environ[key] = str(path)
    os.environ.setdefault("KMP_DUPLICATE_LIB_OK", "TRUE")
    os.environ.setdefault("OMP_NUM_THREADS", "1")
    return root


def hub_dir(root: Path) -> Path:
    return root / HUB_RELATIVE


def model_cache_dir(root: Path, spec: ModelSpec) -> Path:
    """Directory the Hugging Face hub uses for one model's files."""
    return hub_dir(root) / ("models--" + spec.id.replace("/", "--"))


def mark_model_complete(root: Path, spec: ModelSpec) -> None:
    """Record that a model's weights are fully present (download or first load)."""
    cache = model_cache_dir(root, spec)
    if cache.is_dir():
        (cache / COMPLETE_MARKER).touch()


def is_model_complete(root: Path, spec: ModelSpec) -> bool:
    return (model_cache_dir(root, spec) / COMPLETE_MARKER).exists()


def directory_size(path: Path) -> int:
    """Bytes stored under ``path``; symlinks are not followed or counted."""
    total = 0
    if not path.exists():
        return total
    for entry in path.rglob("*"):
        try:
            if entry.is_file() and not entry.is_symlink():
                total += entry.stat().st_size
        except OSError:
            continue  # file vanished mid-walk (an in-flight download was renamed)
    return total
