"""Overall 0–100% progress with a time estimate, across every phase of a task."""

from __future__ import annotations

from pathlib import Path

import pytest

from imgsearch.desktop import dispatch
from imgsearch.desktop.estimate import IndexProgress, ModelTiming, Timings

MODEL = "clip-vit-b32"


class FakeClock:
    def __init__(self) -> None:
        self.now = 100.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def _progress(*, loaded: bool = False, expected: int | None = 1000):
    clock = FakeClock()
    timing = ModelTiming(load_seconds=30.0, images_per_second=20.0)
    return IndexProgress(timing, model_loaded=loaded, expected=expected, clock=clock), clock


def test_estimate_is_available_from_the_first_moment():
    progress, _ = _progress()

    first = progress.scanning()

    assert first.fraction == 0.0
    # 30 s to load + 1000 images at 20/s + a little for scanning and saving
    assert first.eta == pytest.approx(81.0, abs=1.5)
    assert 0.0 < first.ceiling < 0.05


def test_without_a_hint_the_scan_reports_zero_and_no_guess():
    progress, _ = _progress(expected=None)

    first = progress.scanning()

    assert (first.fraction, first.eta) == (0.0, None)


def test_loading_the_model_is_part_of_the_bar_not_a_spinner():
    progress, clock = _progress()
    progress.scanning()
    clock.advance(1.0)

    loading = progress.loading(total=1000)

    assert loading.eta == pytest.approx(80.5, abs=0.1)  # 30 load + 50 embed + save
    assert loading.fraction == pytest.approx(1.0 / 81.5, abs=0.001)
    # The bar may glide through the load, but not into the embedding share.
    assert loading.ceiling == pytest.approx(31.0 / 81.5, abs=0.001)


def test_a_loaded_model_costs_no_load_time():
    progress, clock = _progress(loaded=True)
    progress.scanning()
    clock.advance(1.0)
    progress.embedding_started()

    start = progress.embedding(0, 1000)

    assert start.eta == pytest.approx(50.5, abs=0.1)


def test_embedding_uses_the_measured_rate_once_there_is_enough_evidence():
    progress, clock = _progress(loaded=True)
    progress.embedding_started()
    clock.advance(0.2)
    early = progress.embedding(8, 1000)
    assert early.eta == pytest.approx(992 / 20 + 0.5, abs=0.1), "too early: trust the stored rate"

    clock.advance(9.8)  # 200 images in 10 s → 20/s measured… then it slows down
    progress.embedding(200, 1000)
    clock.advance(40.0)  # now 400 images in 50 s → 8/s
    slow = progress.embedding(400, 1000)

    assert slow.eta == pytest.approx(600 / 8 + 0.5, abs=0.5)
    assert slow.fraction == pytest.approx(50.0 / (50.0 + 75.5), abs=0.01)
    assert slow.fraction <= slow.ceiling <= 0.99


def test_saving_is_the_last_sliver_and_never_claims_100_percent():
    progress, clock = _progress(loaded=True)
    progress.embedding_started()
    clock.advance(50.0)

    saving = progress.saving()

    assert 0.98 < saving.fraction < 1.0
    assert saving.ceiling <= 0.99 or saving.ceiling == pytest.approx(saving.fraction)
    assert saving.eta == pytest.approx(0.5, abs=0.01)


def test_measured_rate_requires_enough_images():
    progress, clock = _progress(loaded=True)
    progress.embedding_started()
    clock.advance(1.0)
    progress.embedding(8, 8)
    assert progress.measured_rate() is None, "8 images is noise, not a rate"

    clock.advance(1.0)
    progress.embedding(64, 64)
    assert progress.measured_rate() == pytest.approx(32.0)


def test_timings_persist_and_fall_back_to_defaults(tmp_path: Path):
    path = tmp_path / "nested" / "timings.json"
    timings = Timings(path)
    assert timings.get("anything") == ModelTiming()

    timings.record("m", load_seconds=12.5)
    timings.record("m", images_per_second=90.0)
    timings.record("other", load_seconds=3.0)

    assert Timings(path).get("m") == ModelTiming(load_seconds=12.5, images_per_second=90.0)
    assert Timings(path).get("other").images_per_second == ModelTiming().images_per_second

    path.write_text("{ not json")
    assert Timings(path).get("m") == ModelTiming(), "a corrupt file must not break indexing"


def test_index_progress_runs_from_zero_towards_one_without_gaps(color_engine, photo_folder):
    events: list[dict] = []

    dispatch(
        {"action": "index", "folder": str(photo_folder), "model": MODEL, "batch": 2, "expected": 6},
        events.append,
    )

    progress = [e for e in events if e["type"] == "progress"]
    assert [e["message"] for e in progress] == [
        "Scanning images",
        "Loading model",
        "Indexing images",
        "Indexing images",
        "Indexing images",
        "Indexing images",
        "Saving search index",
    ]
    # Every phase is on the bar — no event without a position.
    fractions = [e["fraction"] for e in progress]
    assert fractions[0] == 0.0
    assert fractions == sorted(fractions), "the bar never moves backwards"
    assert all(0.0 <= f < 1.0 for f in fractions)
    assert all(e["fraction"] <= e["ceiling"] <= 1.0 for e in progress)
    # …and every phase carries a time estimate.
    assert all(isinstance(e["eta"], float) and e["eta"] >= 0 for e in progress)
    # Image counts are still reported for the "n of m images" text.
    assert [(e["current"], e["total"]) for e in progress if "total" in e] == [
        (0, 6),
        (2, 6),
        (4, 6),
        (6, 6),
    ]


def test_index_remembers_how_long_this_model_takes(color_engine, photo_folder, tmp_path):
    from imgsearch.desktop import indexing

    indexing_min = indexing.estimate.MIN_IMAGES_FOR_RATE
    assert indexing_min > 6, "the fixture folder is too small to record a rate"
    dispatch({"action": "index", "folder": str(photo_folder), "model": MODEL})

    stored = Timings(tmp_path / "project/.runtime/timings.json").get(MODEL)

    assert stored.load_seconds != ModelTiming().load_seconds, "the load time was measured"
    assert stored.images_per_second == ModelTiming().images_per_second


def test_up_to_date_index_still_reports_progress(color_engine, photo_folder):
    dispatch({"action": "index", "folder": str(photo_folder), "model": MODEL})
    events: list[dict] = []

    dispatch({"action": "index", "folder": str(photo_folder), "model": MODEL}, events.append)

    assert [e["message"] for e in events] == ["Scanning images", "Saving search index"]
    assert all("fraction" in e and "eta" in e for e in events)


def test_download_and_duplicates_report_a_position_from_the_start(
    color_engine, photo_folder, monkeypatch
):
    from imgsearch.desktop import model_store

    monkeypatch.setattr(model_store, "_repo_files", lambda spec: [("model.safetensors", 1000)])
    monkeypatch.setattr(model_store, "_POLL_SECONDS", 0.01)

    def fake_snapshot(spec, hub, patterns):
        import time

        blobs = hub / "models--openai--clip-vit-base-patch32" / "blobs"
        blobs.mkdir(parents=True)
        for size in (250, 500, 1000):
            (blobs / "weights.incomplete").write_bytes(b"x" * size)
            time.sleep(0.05)

    monkeypatch.setattr(model_store, "_snapshot", fake_snapshot)
    events: list[dict] = []
    dispatch({"action": "download_model", "model": MODEL}, events.append)
    fractions = [e["fraction"] for e in events]
    assert fractions[0] == 0.0
    assert fractions == sorted(fractions)
    assert fractions[-1] == 1.0
    assert any(isinstance(e.get("eta"), float) for e in events), "a time estimate appears"

    dispatch({"action": "index", "folder": str(photo_folder), "model": MODEL})
    events.clear()
    dispatch({"action": "duplicates", "folder": str(photo_folder)}, events.append)
    fractions = [e["fraction"] for e in events]
    assert fractions[0] == 0.0
    assert fractions == sorted(fractions)
    assert len(fractions) >= 2
