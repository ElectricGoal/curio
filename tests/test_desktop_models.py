"""Model library actions: listing, download progress, removal."""

from __future__ import annotations

from imgsearch.desktop import dispatch


def test_models_describe_each_choice(tmp_path, monkeypatch):
    monkeypatch.setenv("IMGSEARCH_PROJECT_ROOT", str(tmp_path))
    models = dispatch({"action": "models"})["models"]
    assert [m["alias"] for m in models] == ["mobileclip-s4", "clip-vit-b32"]
    default = models[0]
    assert default["default"] is True
    # The default is the heavier model, so each card must say what it costs.
    assert "4.3 GB" in default["summary"]
    assert "1.7 GB" in models[1]["summary"]
    assert sum(1 for m in models if m["default"]) == 1
    assert all(m["summary"] for m in models)
    assert all(m["installed"] is False and m["size"] == 0 for m in models)


def test_download_reports_bytes_and_marks_model_installed(tmp_path, monkeypatch):
    from imgsearch.desktop import model_store

    monkeypatch.setenv("IMGSEARCH_PROJECT_ROOT", str(tmp_path))
    listing = [("config.json", 10), ("model.safetensors", 990), ("tf_model.h5", 5000)]
    monkeypatch.setattr(model_store, "_repo_files", lambda spec: listing)
    monkeypatch.setattr(model_store, "_POLL_SECONDS", 0.01)
    requested: dict = {}

    def fake_snapshot(spec, hub, patterns):
        import time

        requested["patterns"] = patterns
        blobs = hub / "models--openai--clip-vit-base-patch32" / "blobs"
        blobs.mkdir(parents=True)
        (blobs / "weights.incomplete").write_bytes(b"x" * 400)
        time.sleep(0.1)
        (blobs / "weights.incomplete").write_bytes(b"x" * 1000)
        time.sleep(0.1)

    monkeypatch.setattr(model_store, "_snapshot", fake_snapshot)
    events: list[dict] = []

    result = dispatch({"action": "download_model", "model": "clip-vit-b32"}, events.append)

    assert result == {"model": "clip-vit-b32", "installed": True}
    assert "tf_model.h5" not in requested["patterns"]
    byte_events = [e for e in events if e.get("unit") == "bytes"]
    assert byte_events, "expected byte-level progress"
    assert all(e["total"] == 1000 for e in byte_events)
    assert byte_events[-1]["current"] == 1000
    assert any(0 < e["current"] < 1000 for e in byte_events)
    listed = next(
        m for m in dispatch({"action": "models"})["models"] if m["alias"] == "clip-vit-b32"
    )
    assert listed["installed"] is True


def test_failed_download_is_not_marked_installed(tmp_path, monkeypatch):
    import pytest

    from imgsearch.desktop import model_store

    monkeypatch.setenv("IMGSEARCH_PROJECT_ROOT", str(tmp_path))
    monkeypatch.setattr(model_store, "_repo_files", lambda spec: [("model.safetensors", 10)])

    def failing_snapshot(spec, hub, patterns):
        raise OSError("network unreachable")

    monkeypatch.setattr(model_store, "_snapshot", failing_snapshot)
    with pytest.raises(OSError):
        dispatch({"action": "download_model", "model": "clip-vit-b32"})
    listed = next(
        m for m in dispatch({"action": "models"})["models"] if m["alias"] == "clip-vit-b32"
    )
    assert listed["installed"] is False


def test_download_that_fetches_nothing_is_an_error(tmp_path, monkeypatch):
    import pytest

    from imgsearch.desktop import model_store

    monkeypatch.setenv("IMGSEARCH_PROJECT_ROOT", str(tmp_path))
    monkeypatch.setattr(model_store, "_repo_files", lambda spec: [("README.md", 10)])
    monkeypatch.setattr(model_store, "_snapshot", lambda spec, hub, patterns: None)
    with pytest.raises(ValueError, match="No files could be downloaded"):
        dispatch({"action": "download_model", "model": "clip-vit-b32"})


def test_offline_download_explains_itself(tmp_path, monkeypatch):
    import pytest

    from imgsearch.desktop import model_store

    def unreachable(spec):
        raise OSError("Temporary failure in name resolution")

    monkeypatch.setenv("IMGSEARCH_PROJECT_ROOT", str(tmp_path))
    monkeypatch.setattr(model_store, "_repo_files", unreachable)
    with pytest.raises(ValueError, match="internet connection"):
        dispatch({"action": "download_model", "model": "clip-vit-b32"})
