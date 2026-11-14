"""Queries against an existing index: text/image search, warm-up, duplicates."""

from __future__ import annotations

from pathlib import Path
from typing import Any, Final

from imgsearch.config import DEFAULT_MODEL_ALIAS, ModelSpec, resolve_model
from imgsearch.desktop import estimate
from imgsearch.desktop.library import image_record, read_manifest
from imgsearch.desktop.session import Session
from imgsearch.desktop.storage import mark_model_complete

DEFAULT_RESULTS: Final = 100
MAX_RESULTS: Final = 500
DEFAULT_DUPLICATE_THRESHOLD: Final = 0.98
KEEP_STRATEGIES: Final = ("largest", "newest", "oldest", "highest-res")
# Share of the duplicates bar kept for grouping, after the comparison itself.
_GROUPING_SHARE: Final = 0.1


def _indexed_model(folder: Path) -> tuple[str, ModelSpec]:
    manifest = read_manifest(folder)
    if manifest is None:
        raise ValueError("This folder has not been indexed yet. Index it to enable search.")
    alias = manifest.get("model_alias") or manifest.get("model_id") or DEFAULT_MODEL_ALIAS
    try:
        return alias, resolve_model(alias)
    except ValueError as exc:
        raise ValueError(
            f"This folder was indexed with a model that is no longer available ({alias}). "
            "Rebuild its index to search it."
        ) from exc


def _load_model(session: Session, alias: str, spec: ModelSpec) -> Any:
    if not session.embedders.is_loaded(alias):
        session.progress("Loading model")
    embedder = session.embedders.load(alias, spec)
    mark_model_complete(session.root, spec)
    return embedder


def warm(session: Session, folder: Path) -> dict[str, Any]:
    """Load the folder's model ahead of the first search."""
    alias, spec = _indexed_model(folder)
    embedder = _load_model(session, alias, spec)
    # The first inference pays one-off GPU setup costs; spend them now rather
    # than on the user's first query.
    embedder.encode_text("warm up")
    return {"model": alias}


def _result_limit(request: dict[str, Any]) -> int:
    try:
        return max(1, min(MAX_RESULTS, int(request.get("k", DEFAULT_RESULTS))))
    except (TypeError, ValueError) as exc:
        raise ValueError("Result count must be a whole number.") from exc


def run_search(session: Session, folder: Path, request: dict[str, Any]) -> dict[str, Any]:
    from imgsearch.core.index import Index
    from imgsearch.core.preprocess import ImageLoadError

    text, image = request.get("text"), request.get("image")
    text = text.strip() if isinstance(text, str) else ""
    if bool(text) == bool(image):
        raise ValueError("Provide either text or an image query")
    limit = _result_limit(request)
    reference: Path | None = None
    if image:
        reference = Path(str(image)).expanduser()
        if not reference.is_file():
            raise ValueError(f"The reference image could not be found: {reference}")
    alias, spec = _indexed_model(folder)
    embedder = _load_model(session, alias, spec)
    session.check_cancelled()
    session.progress("Understanding your query")
    try:
        query = (
            embedder.encode_text(text)
            if reference is None
            else embedder.encode_images([reference])[0]
        )
    except ImageLoadError as exc:
        raise ValueError(f"The reference image could not be opened: {reference}") from exc
    session.progress("Finding matching images")
    with Index(folder, spec, alias) as index:
        index.open()
        hits = index.search(query, limit)
    images = []
    for hit in hits:
        try:
            record = image_record(folder / hit.rel_path)
        except OSError:
            continue  # indexed file was moved or deleted since the last update
        record["similarity"] = hit.similarity
        images.append(record)
    return {"images": images, "total": len(images), "model": alias}


def _threshold(request: dict[str, Any]) -> float:
    try:
        return max(0.5, min(1.0, float(request.get("threshold", DEFAULT_DUPLICATE_THRESHOLD))))
    except (TypeError, ValueError) as exc:
        raise ValueError("Similarity threshold must be a number.") from exc


def _existing(folder: Path, members: list[str]) -> list[str]:
    return [rel for rel in members if (folder / rel).is_file()]


def run_duplicates(session: Session, folder: Path, request: dict[str, Any]) -> dict[str, Any]:
    from imgsearch.core.duplicate_finder import build_groups, find_exact_groups, find_near_groups
    from imgsearch.core.index import Index

    keep = request.get("keep", "largest")
    if keep not in KEEP_STRATEGIES:
        raise ValueError(f"Unknown keep strategy: {keep!r}")
    threshold = _threshold(request)
    alias, spec = _indexed_model(folder)
    # Creating the embedder imports torch before FAISS, which macOS requires.
    session.embedders.get(alias, spec)
    session.progress("Comparing images", estimate=estimate.START)
    comparing = estimate.RateProgress()

    def compared(rows: int, total: int) -> None:
        # The tail of the bar is for choosing keepers and reading file sizes.
        position = comparing.at(rows, total, finishing=_GROUPING_SHARE)
        session.progress("Comparing images", estimate=position)

    with Index(folder, spec, alias) as index:
        index.open()
        exact = find_exact_groups(index.meta)
        near = (
            []
            if request.get("exact_only")
            else find_near_groups(index.vectors, index.meta, threshold, compared)
        )
    session.progress("Grouping duplicates", estimate=comparing.at(1, 1, finishing=_GROUPING_SHARE))
    exact = [group for group in (_existing(folder, g) for g in exact) if len(group) > 1]
    near = [
        (group, sim)
        for group, sim in ((_existing(folder, g), s) for g, s in near)
        if len(group) > 1
    ]
    session.check_cancelled()
    groups = []
    for group in build_groups(folder, exact, near, keep):
        files = []
        for rel, kept in [(group.keeper, True)] + [(rel, False) for rel in group.duplicates]:
            try:
                files.append({**image_record(folder / rel), "keep": kept})
            except OSError:
                continue
        if len(files) > 1 and files[0]["keep"]:
            groups.append({"kind": group.kind, "similarity": group.similarity, "files": files})
    redundant = [item for group in groups for item in group["files"] if not item["keep"]]
    return {
        "groups": groups,
        "redundant": len(redundant),
        "reclaimable": sum(item["size"] for item in redundant),
        "threshold": threshold,
    }
