"""Desktop engine actions: status, incremental indexing, search, duplicates."""

from __future__ import annotations

import json
import threading
from pathlib import Path

import pytest
from PIL import Image

from imgsearch.desktop import dispatch
from imgsearch.desktop.session import Cancelled
from tests.conftest import ALT_MODEL

MODEL = "clip-vit-b32"


def _index(folder: Path, **extra):
    events: list[dict] = []
    result = dispatch(
        {"action": "index", "folder": str(folder), "model": MODEL, **extra}, events.append
    )
    return result, events


def test_status_tracks_new_changed_and_removed_images(color_engine, photo_folder):
    before = dispatch({"action": "status", "folder": str(photo_folder)})
    assert before == {
        "indexed": False,
        "total": 6,
        "count": 0,
        "pending": 6,
        "missing": 0,
        "unreadable": 0,
        "model": None,
        "model_name": None,
        "model_available": None,
        "updated_at": None,
    }

    _index(photo_folder)
    fresh = dispatch({"action": "status", "folder": str(photo_folder)})
    assert (fresh["indexed"], fresh["count"], fresh["pending"], fresh["missing"]) == (True, 6, 0, 0)
    assert fresh["model"] == MODEL
    assert fresh["model_name"] == "OpenAI CLIP ViT-B/32"

    Image.new("RGB", (16, 16), "red").save(photo_folder / "new.png")
    (photo_folder / "blue.png").unlink()
    stale = dispatch({"action": "status", "folder": str(photo_folder)})
    assert (stale["total"], stale["pending"], stale["missing"]) == (6, 1, 1)


def test_updating_an_index_keeps_the_model_it_was_built_with(color_engine, photo_folder):
    _index(photo_folder)
    Image.new("RGB", (16, 16), "blue").save(photo_folder / "later.png")

    # The app's selected model differs from the index; an update must not fail.
    result = dispatch({"action": "index", "folder": str(photo_folder), "model": ALT_MODEL})

    assert result["model"] == MODEL
    assert (result["count"], result["added"], result["cancelled"]) == (7, 1, False)


def test_cancelled_index_keeps_finished_batches(color_engine, photo_folder):
    from imgsearch.desktop.server import Engine

    cancel = threading.Event()
    color_engine.before_encode = lambda size: cancel.set()
    events: list[dict] = []
    engine = Engine(events.append)

    engine.handle(
        {"id": "a", "action": "index", "folder": str(photo_folder), "model": MODEL, "batch": 2},
        cancel,
    )

    result = events[-1]
    assert result["type"] == "result"
    assert result["data"]["cancelled"] is True
    assert result["data"]["count"] == 2
    assert result["data"]["remaining"] == 4
    status = dispatch({"action": "status", "folder": str(photo_folder)})
    assert (status["count"], status["pending"]) == (2, 4)

    # Resuming finishes the remaining images without re-embedding the first batch.
    color_engine.before_encode = None
    resumed, _ = _index(photo_folder, batch=2)
    assert (resumed["count"], resumed["added"]) == (6, 4)


def test_cancelled_rebuild_restores_previous_index(color_engine, photo_folder):
    from imgsearch.desktop.server import Engine

    _index(photo_folder)
    manifest = photo_folder / ".imgsearch/manifest.json"
    original = manifest.read_text()
    cancel = threading.Event()
    color_engine.before_encode = lambda size: cancel.set()
    events: list[dict] = []

    Engine(events.append).handle(
        {
            "id": "r",
            "action": "index",
            "folder": str(photo_folder),
            "model": ALT_MODEL,
            "rebuild": True,
            "batch": 2,
        },
        cancel,
    )

    assert events[-1] == {"id": "r", "type": "error", "code": "cancelled", "message": "Cancelled"}
    assert manifest.read_text() == original
    assert not list(photo_folder.glob(".imgsearch-backup-*"))


def test_interrupted_rebuild_is_recovered_on_next_index(color_engine, photo_folder):
    _index(photo_folder)
    index_dir = photo_folder / ".imgsearch"
    # Simulate a crash mid-rebuild: old index parked as a backup, new one not yet written.
    index_dir.rename(photo_folder / ".imgsearch-backup-deadbeef")

    result, _ = _index(photo_folder)

    assert (result["count"], result["added"]) == (6, 0)
    assert not list(photo_folder.glob(".imgsearch-backup-*"))


def test_status_recovers_an_interrupted_rebuild_without_reindexing(color_engine, photo_folder):
    _index(photo_folder)
    (photo_folder / ".imgsearch").rename(photo_folder / ".imgsearch-backup-deadbeef")

    status = dispatch({"action": "status", "folder": str(photo_folder)})

    assert (status["indexed"], status["count"]) == (True, 6)
    assert not list(photo_folder.glob(".imgsearch-backup-*"))


def test_rebuild_never_checkpoints_so_a_crash_cannot_hide_the_old_index(
    color_engine, photo_folder, monkeypatch
):
    from imgsearch.desktop import indexing

    _index(photo_folder)
    monkeypatch.setattr(indexing, "CHECKPOINT_SECONDS", 0.0)
    manifest = photo_folder / ".imgsearch/manifest.json"
    seen: list[bool] = []
    color_engine.before_encode = lambda size: seen.append(manifest.exists())

    _index(photo_folder, model=ALT_MODEL, rebuild=True, batch=2)

    # Mid-rebuild there is never a manifest, so recovery would restore the backup.
    assert seen == [False, False, False]
    assert json.loads(manifest.read_text())["model_alias"] == ALT_MODEL


def test_update_checkpoints_while_it_runs(color_engine, photo_folder, monkeypatch):
    from imgsearch.desktop import indexing

    monkeypatch.setattr(indexing, "CHECKPOINT_SECONDS", 0.0)
    manifest = photo_folder / ".imgsearch/manifest.json"
    seen: list[bool] = []
    color_engine.before_encode = lambda size: seen.append(manifest.exists())

    _index(photo_folder, batch=2)

    assert seen == [False, True, True]


def test_failed_update_keeps_the_batches_that_succeeded(color_engine, photo_folder):
    calls: list[int] = []

    def fail_on_second_batch(size: int) -> None:
        calls.append(size)
        if len(calls) == 2:
            raise RuntimeError("GPU hiccup")

    color_engine.before_encode = fail_on_second_batch
    with pytest.raises(RuntimeError, match="GPU hiccup"):
        _index(photo_folder, batch=2)

    status = dispatch({"action": "status", "folder": str(photo_folder)})
    assert (status["indexed"], status["count"], status["pending"]) == (True, 2, 4)


def _retire_index_model(folder: Path) -> None:
    """Make the folder's index look like it was built with a model since removed."""
    manifest = folder / ".imgsearch/manifest.json"
    data = json.loads(manifest.read_text())
    manifest.write_text(
        json.dumps({**data, "model_alias": "retired-model", "model_id": "x/retired"})
    )


def test_index_built_with_a_removed_model_asks_for_a_rebuild(color_engine, photo_folder):
    _index(photo_folder)
    _retire_index_model(photo_folder)

    status = dispatch({"action": "status", "folder": str(photo_folder)})
    assert (status["indexed"], status["model"], status["model_available"]) == (
        True,
        "retired-model",
        False,
    )
    assert status["model_name"] == "x/retired"
    with pytest.raises(ValueError, match="no longer available.*Rebuild"):
        dispatch({"action": "search", "folder": str(photo_folder), "text": "red"})
    with pytest.raises(ValueError, match="no longer available.*Rebuild"):
        dispatch({"action": "index", "folder": str(photo_folder), "model": MODEL})
    with pytest.raises(ValueError, match="no longer available"):
        dispatch({"action": "duplicates", "folder": str(photo_folder)})

    rebuilt, _ = _index(photo_folder, rebuild=True)
    assert (rebuilt["count"], rebuilt["model"]) == (6, MODEL)
    assert dispatch({"action": "status", "folder": str(photo_folder)})["model_available"] is True


def test_unreadable_images_are_reported_once_not_forever_pending(color_engine, photo_folder):
    (photo_folder / "broken.jpg").write_bytes(b"this is not a jpeg")

    result, _ = _index(photo_folder)
    assert (result["count"], result["skipped"]) == (6, 1)

    status = dispatch({"action": "status", "folder": str(photo_folder)})
    assert (status["pending"], status["unreadable"]) == (0, 1)


def test_search_before_indexing_explains_what_to_do(color_engine, photo_folder):
    with pytest.raises(ValueError, match="has not been indexed"):
        dispatch({"action": "search", "folder": str(photo_folder), "text": "red"})


def test_search_ranks_matching_colour_first_and_reports_model(color_engine, photo_folder):
    _index(photo_folder)
    result = dispatch({"action": "search", "folder": str(photo_folder), "text": "green", "k": 2})
    assert sorted(image["name"] for image in result["images"]) == ["green-copy.png", "green.png"]
    assert result["model"] == MODEL
    assert result["total"] == 2


def test_search_rejects_missing_reference_image(color_engine, photo_folder):
    _index(photo_folder)
    with pytest.raises(ValueError, match="reference image"):
        dispatch(
            {
                "action": "search",
                "folder": str(photo_folder),
                "image": str(photo_folder / "gone.png"),
            }
        )


def test_duplicates_lists_groups_with_one_keeper_each(color_engine, photo_folder):
    _index(photo_folder)
    (photo_folder / "blue-copy.png").unlink()  # stale index rows must not appear

    result = dispatch({"action": "duplicates", "folder": str(photo_folder), "threshold": 0.99})

    assert len(result["groups"]) == 2
    assert result["redundant"] == 2
    for group in result["groups"]:
        assert group["kind"] == "similar"
        assert [item["keep"] for item in group["files"]] == [True, False]
        assert all(Path(item["path"]).exists() for item in group["files"])
    assert result["reclaimable"] == sum(
        item["size"] for group in result["groups"] for item in group["files"] if not item["keep"]
    )


def test_duplicates_exact_only_ignores_lookalikes(color_engine, photo_folder):
    (photo_folder / "red-twin.png").write_bytes((photo_folder / "red.png").read_bytes())
    _index(photo_folder)

    result = dispatch({"action": "duplicates", "folder": str(photo_folder), "exact_only": True})

    assert [group["kind"] for group in result["groups"]] == ["exact"]
    assert sorted(item["name"] for item in result["groups"][0]["files"]) == [
        "red-twin.png",
        "red.png",
    ]


def test_warm_loads_the_folder_model_once(color_engine, photo_folder):
    from imgsearch.desktop.server import Engine

    _index(photo_folder)
    color_engine.loaded.clear()
    events: list[dict] = []
    engine = Engine(events.append)
    request = {"folder": str(photo_folder)}

    engine.handle({"id": "1", "action": "warm", **request}, threading.Event())
    engine.handle({"id": "2", "action": "search", "text": "red", **request}, threading.Event())
    engine.handle({"id": "3", "action": "search", "text": "blue", **request}, threading.Event())

    assert [e["type"] for e in events if e["type"] != "progress"] == ["result"] * 3
    assert len(color_engine.created) == 2  # one for indexing above, one shared by the engine
    # Warm searches skip the "Loading model" step entirely.
    loading = [e for e in events if e.get("message") == "Loading model"]
    assert [e["id"] for e in loading] == ["1"]


def test_manifest_records_alias(color_engine, photo_folder):
    _index(photo_folder)
    manifest = json.loads((photo_folder / ".imgsearch/manifest.json").read_text())
    assert manifest["model_alias"] == MODEL


def test_cancel_before_start_raises(color_engine, photo_folder):
    from imgsearch.desktop.session import EmbedderCache, Session

    cancel = threading.Event()
    cancel.set()
    session = Session(
        root=photo_folder, emit=lambda event: None, cancelled=cancel, embedders=EmbedderCache()
    )
    with pytest.raises(Cancelled):
        session.check_cancelled()
