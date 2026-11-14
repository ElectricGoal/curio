"""Per-request context plus the model cache that outlives requests."""

from __future__ import annotations

import gc
import sys
import threading
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from imgsearch.config import ModelSpec
from imgsearch.desktop.estimate import Estimate

Event = dict[str, Any]
Emit = Callable[[Event], None]


class Cancelled(Exception):
    """The request was cancelled by the app before it finished."""


class EmbedderCache:
    """Keeps the most recently used model in memory between requests.

    Loading a model takes seconds; encoding a query takes milliseconds. Holding
    one model warm is what makes repeat searches feel instant. Only one model
    is retained so switching models does not double memory use.
    """

    def __init__(self) -> None:
        self._alias: str | None = None
        self._embedder: Any = None
        self._loaded = False

    def get(self, alias: str, spec: ModelSpec) -> Any:
        """Return the (possibly not yet loaded) embedder for ``alias``."""
        if self._embedder is None or self._alias != alias:
            self.release()
            # Looked up at call time so tests can substitute the factory.
            from imgsearch.core import embedder as embedder_module

            self._embedder = embedder_module.create_embedder(spec)
            self._alias = alias
        return self._embedder

    def load(self, alias: str, spec: ModelSpec) -> Any:
        """Return the embedder for ``alias`` with its weights in memory."""
        embedder = self.get(alias, spec)
        if not self._loaded:
            embedder.load()
            self._loaded = True
        return embedder

    def is_loaded(self, alias: str | None = None) -> bool:
        return self._loaded and (alias is None or alias == self._alias)

    def release(self) -> None:
        """Drop the cached model and hand its memory back to the system."""
        had_model = self._embedder is not None
        self._embedder = None
        self._alias = None
        self._loaded = False
        if not had_model:
            return
        gc.collect()
        torch = sys.modules.get("torch")
        try:
            if torch is not None and torch.backends.mps.is_available():
                torch.mps.empty_cache()
        except Exception as exc:  # pragma: no cover - depends on the torch build
            sys.stderr.write(f"imgsearch: could not release GPU cache: {exc}\n")


@dataclass(frozen=True)
class Session:
    """Everything one request handler needs from its surroundings."""

    root: Path
    emit: Emit
    cancelled: threading.Event
    embedders: EmbedderCache

    def progress(
        self,
        message: str,
        current: int | None = None,
        total: int | None = None,
        unit: str | None = None,
        *,
        estimate: Estimate | None = None,
    ) -> None:
        """Report where the task stands.

        ``current``/``total`` count the thing being worked on (images, bytes);
        ``estimate`` places this moment on the task's single 0–100% bar.
        """
        event: Event = {"type": "progress", "message": message}
        if current is not None and total is not None:
            event["current"] = current
            event["total"] = total
        if unit is not None:
            event["unit"] = unit
        if estimate is not None:
            event["fraction"] = round(estimate.fraction, 4)
            event["eta"] = None if estimate.eta is None else round(estimate.eta, 1)
            event["ceiling"] = round(max(estimate.ceiling, estimate.fraction), 4)
        self.emit(event)

    def check_cancelled(self) -> None:
        if self.cancelled.is_set():
            raise Cancelled()
