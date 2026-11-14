"""Overall progress (0–1) and time remaining for long engine tasks.

A task such as indexing has phases of very different lengths: a quick scan, a
model load that can take most of a minute, the embedding itself, and a save.
Reporting them as one bar needs a common unit, and the only honest one is
time: the position on the bar is ``elapsed / (elapsed + estimated remaining)``.

The remaining time comes from what this machine did before — how long each
model took to load and how many images per second it embedded — so an estimate
exists from the first moment, and from what the current run is measuring once
there is enough of it.
"""

from __future__ import annotations

import json
import sys
import time
from collections.abc import Callable
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from typing import Final

TIMINGS_RELATIVE: Final = ".runtime/timings.json"
# Used until a model has been timed on this machine.
DEFAULT_LOAD_SECONDS: Final = 30.0
DEFAULT_IMAGES_PER_SECOND: Final = 20.0
SCAN_SECONDS_PER_IMAGE: Final = 0.0005
MIN_SCAN_SECONDS: Final = 0.2
SAVE_SECONDS: Final = 0.5
# A rate measured over fewer images, or less time, is too noisy to act on.
MIN_IMAGES_FOR_RATE: Final = 16
MIN_SECONDS_FOR_RATE: Final = 1.0
# The bar only reaches 100% when the task has actually finished.
MAX_UNFINISHED_FRACTION: Final = 0.99


@dataclass(frozen=True)
class ModelTiming:
    """How one model has performed on this machine."""

    load_seconds: float = DEFAULT_LOAD_SECONDS
    images_per_second: float = DEFAULT_IMAGES_PER_SECOND


@dataclass(frozen=True)
class Estimate:
    """Where a task stands, as sent to the app with each progress event."""

    fraction: float
    """Share of the whole task completed, 0–1."""
    eta: float | None
    """Seconds remaining, or None when there is nothing yet to base one on."""
    ceiling: float
    """How far the bar may glide before the next event: the end of this phase."""


class Timings:
    """Per-model timings remembered between runs."""

    def __init__(self, path: Path) -> None:
        self._path = path

    def _read(self) -> dict[str, dict[str, float]]:
        try:
            data = json.loads(self._path.read_text())
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def get(self, alias: str) -> ModelTiming:
        stored = self._read().get(alias)
        timing = ModelTiming()
        if not isinstance(stored, dict):
            return timing
        known = {
            key: float(value)
            for key, value in stored.items()
            if key in asdict(timing) and isinstance(value, int | float) and value > 0
        }
        return replace(timing, **known)

    def record(
        self,
        alias: str,
        *,
        load_seconds: float | None = None,
        images_per_second: float | None = None,
    ) -> None:
        """Remember a measurement. Never fails the task it was measured on."""
        measured = {
            key: max(round(value, 3), 0.001)  # a very fast load still counts as measured
            for key, value in (
                ("load_seconds", load_seconds),
                ("images_per_second", images_per_second),
            )
            if value is not None and value > 0
        }
        if not measured:
            return
        data = self._read()
        previous = data.get(alias)
        data[alias] = {**(previous if isinstance(previous, dict) else {}), **measured}
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self._path.with_suffix(".json.tmp")
            temporary.write_text(json.dumps(data, indent=2, sort_keys=True))
            temporary.replace(self._path)
        except OSError as exc:
            sys.stderr.write(f"imgsearch: could not save timings: {exc}\n")


def timings_for(root: Path) -> Timings:
    return Timings(root / TIMINGS_RELATIVE)


def _position(elapsed: float, phase_remaining: float, later: float, floor: float) -> Estimate:
    """Place a moment on the bar given the time left in this phase and after it."""
    remaining = max(0.0, phase_remaining) + max(0.0, later)
    whole = elapsed + remaining
    fraction = elapsed / whole if whole > 0 else 0.0
    # Never backwards (a slower-than-expected phase holds the bar still instead).
    fraction = max(floor, min(fraction, 1.0))
    phase_end = (elapsed + max(0.0, phase_remaining)) / whole if whole > 0 else fraction
    ceiling = max(fraction, min(phase_end, MAX_UNFINISHED_FRACTION))
    return Estimate(fraction=fraction, eta=remaining, ceiling=ceiling)


class IndexProgress:
    """Tracks one index run through scan → load → embed → save."""

    def __init__(
        self,
        timing: ModelTiming,
        *,
        model_loaded: bool,
        expected: int | None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._timing = timing
        self._load_remaining = 0.0 if model_loaded else timing.load_seconds
        self._expected = expected
        self._clock = clock
        self._started = clock()
        self._embed_started: float | None = None
        self._processed = 0
        self._floor = 0.0

    def _emit(self, phase_remaining: float, later: float) -> Estimate:
        estimate = _position(self._clock() - self._started, phase_remaining, later, self._floor)
        self._floor = estimate.fraction
        return estimate

    def scanning(self) -> Estimate:
        """The run has just begun. ``expected`` is the app's count of images to do."""
        if self._expected is None:
            return Estimate(fraction=0.0, eta=None, ceiling=0.02)
        scan = max(MIN_SCAN_SECONDS, self._expected * SCAN_SECONDS_PER_IMAGE)
        later = self._load_remaining + self._embed_seconds(self._expected) + SAVE_SECONDS
        position = self._emit(scan, later if self._expected else SAVE_SECONDS)
        # This is the starting line: the bar begins at exactly zero.
        self._floor = 0.0
        return replace(position, fraction=0.0)

    def loading(self, total: int) -> Estimate:
        """The scan found ``total`` images to embed and the model must be loaded."""
        return self._emit(self._load_remaining, self._embed_seconds(total) + SAVE_SECONDS)

    def embedding_started(self) -> None:
        self._load_remaining = 0.0
        self._embed_started = self._clock()

    def embedding(self, processed: int, total: int) -> Estimate:
        self._processed = processed
        return self._emit(self._embed_seconds(total - processed), SAVE_SECONDS)

    def saving(self) -> Estimate:
        return self._emit(SAVE_SECONDS, 0.0)

    def measured_rate(self) -> float | None:
        """Images per second in this run, once it is worth trusting."""
        if self._embed_started is None or self._processed < MIN_IMAGES_FOR_RATE:
            return None
        elapsed = self._clock() - self._embed_started
        if elapsed < MIN_SECONDS_FOR_RATE:
            return None
        return self._processed / elapsed

    def _embed_seconds(self, images: int) -> float:
        rate = self.measured_rate() or self._timing.images_per_second
        return max(0, images) / rate


class RateProgress:
    """Progress for work measured in one unit (bytes, rows) at a steady rate."""

    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._started = clock()
        self._floor = 0.0

    def at(self, done: float, total: float, *, finishing: float = 0.0) -> Estimate:
        """``finishing`` reserves the tail of the bar for work after the counted part."""
        share = (1.0 - finishing) * (min(done, total) / total if total > 0 else 0.0)
        fraction = max(self._floor, min(share, 1.0))
        self._floor = fraction
        elapsed = self._clock() - self._started
        eta = elapsed / fraction * (1.0 - fraction) if fraction > 0 and elapsed > 0 else None
        return Estimate(fraction=fraction, eta=eta, ceiling=fraction)


START: Final = Estimate(fraction=0.0, eta=None, ceiling=0.02)
DONE: Final = Estimate(fraction=1.0, eta=0.0, ceiling=1.0)
