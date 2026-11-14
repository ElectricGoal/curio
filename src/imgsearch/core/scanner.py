"""Recursive image discovery with content hashing."""

from __future__ import annotations

import hashlib
import os
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from stat import S_ISREG

from imgsearch.config import SUPPORTED_EXTENSIONS


@dataclass(frozen=True)
class DiscoveredFile:
    """A candidate image found on disk."""

    abs_path: Path
    rel_path: str  # POSIX-style relative to scan root
    mtime: float
    size: int


def is_image(path: Path) -> bool:
    """Return True if the path has a supported image extension."""
    return path.suffix.lower() in SUPPORTED_EXTENSIONS


def scan(root: Path, recursive: bool = True) -> Iterator[DiscoveredFile]:
    """Walk `root` yielding image files.

    Hidden entries (names starting with a dot) are skipped at every level:
    that covers the index directory itself and caches such as `.thumbnails`,
    and matches what Finder and the desktop app show. Hidden folders are
    pruned rather than walked, so large dot-directories cost nothing.

    The scanner is read-only and does not open files. Callers decide when to
    hash or embed based on mtime staleness.
    """
    root = root.resolve()
    if not root.is_dir():
        raise NotADirectoryError(f"{root} is not a directory")

    for directory, subdirs, filenames in os.walk(root):
        # Pruning in place stops os.walk from descending into hidden folders.
        subdirs[:] = sorted(d for d in subdirs if not d.startswith(".")) if recursive else []
        for name in sorted(filenames):
            if name.startswith("."):
                continue
            path = Path(directory, name)
            if not is_image(path):
                continue
            try:
                stat = path.stat()
            except OSError:
                # File disappeared between listing and stat — skip silently
                continue
            if not S_ISREG(stat.st_mode):
                continue
            yield DiscoveredFile(
                abs_path=path,
                rel_path=path.relative_to(root).as_posix(),
                mtime=stat.st_mtime,
                size=stat.st_size,
            )


def sha1_of_file(path: Path, chunk_size: int = 1 << 20) -> str:
    """Compute SHA1 digest of a file. Used only when mtime indicates a change."""
    h = hashlib.sha1()
    with path.open("rb") as fh:
        while True:
            chunk = fh.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()
