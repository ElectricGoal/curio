"""The model library: what can be used, what is downloaded, and how to fetch it."""

from __future__ import annotations

import importlib.util
import shutil
import threading
from fnmatch import fnmatch
from pathlib import Path
from typing import Any, Final

from imgsearch.config import DEFAULT_MODEL_ALIAS, MODEL_REGISTRY, ModelSpec, resolve_model
from imgsearch.desktop import estimate
from imgsearch.desktop.session import Session
from imgsearch.desktop.storage import (
    COMPLETE_MARKER,
    directory_size,
    hub_dir,
    is_model_complete,
    model_cache_dir,
)

_POLL_SECONDS = 0.5
# Share of a download's bar kept for the final verification step.
_VERIFY_SHARE: Final = 0.01
_METADATA_PATTERNS: Final = ("*.json", "*.txt", "*.model", "*.tiktoken")
_MOBILECLIP_HINT: Final = (
    "Requires MobileCLIP support. In Terminal: source scripts/env.sh && uv sync --extra mobileclip"
)
SUMMARIES: Final[dict[str, str]] = {
    "mobileclip-s4": (
        "Recommended. The best search quality here. Uses about 4.3 GB of memory, "
        "which is tight on an 8 GB Mac."
    ),
    "clip-vit-b32": (
        "The light option: about 1.7 GB of memory and five times faster to index, "
        "with less accurate results for detailed descriptions."
    ),
}


def download_patterns(spec: ModelSpec, filenames: list[str]) -> list[str]:
    """Select runtime assets, avoiding duplicate framework exports."""
    metadata = list(_METADATA_PATTERNS)
    if spec.family == "mobileclip":
        return metadata + ["mobileclip_s4.pt"]
    safe = [name for name in filenames if name.endswith(".safetensors")]
    if safe:
        return metadata + safe
    return metadata + [
        name for name in filenames if name.startswith("pytorch_model") and name.endswith(".bin")
    ]


def _available(spec: ModelSpec) -> bool:
    return spec.family != "mobileclip" or importlib.util.find_spec("mobileclip") is not None


def list_models(root: Path) -> dict[str, Any]:
    models = []
    for alias, spec in MODEL_REGISTRY.items():
        available = _available(spec)
        models.append(
            {
                "alias": alias,
                "id": spec.id,
                "name": spec.display_name,
                "family": spec.family,
                "summary": SUMMARIES.get(alias, ""),
                "default": alias == DEFAULT_MODEL_ALIAS,
                "installed": is_model_complete(root, spec),
                "available": available,
                "availability_message": "" if available else _MOBILECLIP_HINT,
                "size": directory_size(model_cache_dir(root, spec)),
            }
        )
    return {"models": models, "storage": str(root / "models")}


def _repo_files(spec: ModelSpec) -> list[tuple[str, int]]:
    """Names and sizes of every file in the model's repository."""
    from huggingface_hub import HfApi

    info = HfApi().model_info(spec.id, files_metadata=True)
    return [(sibling.rfilename, sibling.size or 0) for sibling in info.siblings or []]


def _snapshot(spec: ModelSpec, hub: Path, patterns: list[str]) -> None:
    from huggingface_hub import snapshot_download

    snapshot_download(spec.id, cache_dir=str(hub), allow_patterns=patterns)


def download_model(session: Session, alias: str) -> dict[str, Any]:
    spec = resolve_model(alias)
    cache = model_cache_dir(session.root, spec)
    message = "Downloading " + spec.display_name
    session.progress(message, estimate=estimate.START)
    try:
        files = _repo_files(spec)
    except Exception as exc:
        raise ValueError(
            f"Could not reach Hugging Face to download {spec.display_name}. "
            "Check your internet connection and try again."
        ) from exc
    patterns = download_patterns(spec, [name for name, _ in files])
    total = sum(size for name, size in files if any(fnmatch(name, p) for p in patterns))
    finished = threading.Event()
    # Bytes already on disk (a resumed download) must not count towards the speed.
    progress = estimate.RateProgress()

    def report() -> None:
        while not finished.wait(_POLL_SECONDS):
            if total > 0:
                done = min(directory_size(cache), total)
                # Hold the bar just short of the end until the files are verified.
                position = progress.at(done, total, finishing=_VERIFY_SHARE)
                session.progress(message, done, total, "bytes", estimate=position)

    reporter = threading.Thread(target=report, daemon=True)
    reporter.start()
    try:
        _snapshot(spec, hub_dir(session.root), patterns)
    finally:
        finished.set()
        reporter.join()
    if directory_size(cache) == 0:
        raise ValueError(f"No files could be downloaded for {spec.display_name}.")
    session.progress(message, total, total, "bytes", estimate=estimate.DONE)
    (cache / COMPLETE_MARKER).touch()
    return {"model": alias, "installed": True}


def delete_model(session: Session, alias: str) -> dict[str, Any]:
    spec = resolve_model(alias)
    cache = model_cache_dir(session.root, spec)
    if cache.is_symlink():
        raise ValueError("Refusing to remove a symlinked model cache")
    session.progress("Removing " + spec.display_name, estimate=estimate.START)
    session.embedders.release()
    if cache.exists():
        shutil.rmtree(cache)
    return {"model": alias, "installed": False}
