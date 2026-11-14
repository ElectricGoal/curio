from imgsearch.desktop import dispatch


def test_browse_and_local_model_storage(tmp_path, monkeypatch):
    monkeypatch.setenv("IMGSEARCH_PROJECT_ROOT", str(tmp_path / "project"))
    photos = tmp_path / "photos"
    photos.mkdir()
    (photos / "a.jpg").write_bytes(b"not decoded for browsing")
    (photos / "notes.txt").write_text("ignored")
    result = dispatch({"action": "browse", "folder": str(photos)})
    assert result["total"] == 1
    assert result["images"][0]["name"] == "a.jpg"
    assert dispatch({"action": "status", "folder": str(photos)})["indexed"] is False
    models = dispatch({"action": "models"})
    assert models["storage"] == str(tmp_path / "project/models")
    assert not any(model["installed"] for model in models["models"])


def test_delete_only_registered_cache(tmp_path, monkeypatch):
    import pytest

    monkeypatch.setenv("IMGSEARCH_PROJECT_ROOT", str(tmp_path))
    with pytest.raises(ValueError):
        dispatch({"action": "delete_model", "model": "../../photos"})
    cache = tmp_path / "models/huggingface/hub/models--openai--clip-vit-base-patch32"
    cache.mkdir(parents=True)
    (cache / ".imgsearch-complete").touch()
    assert next(
        m for m in dispatch({"action": "models"})["models"] if m["alias"] == "clip-vit-b32"
    )["installed"]
    dispatch({"action": "delete_model", "model": "clip-vit-b32"})
    assert not cache.exists()


def test_search_uses_manifest_model_and_image_query(tmp_path, monkeypatch):
    import json

    import numpy as np
    from PIL import Image

    from imgsearch.core import embedder

    monkeypatch.setenv("IMGSEARCH_PROJECT_ROOT", str(tmp_path / "project"))
    folder = tmp_path / "photos"
    folder.mkdir()
    Image.new("RGB", (16, 16), "red").save(folder / "red.png")
    loaded = []

    class FakeEmbedder:
        def __init__(self, spec):
            self.spec = spec

        def load(self):
            loaded.append(self.spec.id)

        def encode_pil(self, images):
            vectors = np.zeros((len(images), self.spec.dim), dtype=np.float32)
            vectors[:, 0] = 1
            return vectors

        def encode_text(self, text):
            return self.encode_pil([None])[0]

        def encode_images(self, paths):
            return self.encode_pil(paths)

    monkeypatch.setattr(embedder, "create_embedder", FakeEmbedder)
    events = []
    result = dispatch(
        {"action": "index", "folder": str(folder), "model": "clip-vit-b32"}, events.append
    )
    assert events[0]["message"] == "Scanning images"
    assert [(e["current"], e["total"]) for e in events if "total" in e] == [(0, 1), (1, 1)]
    assert events[-1]["message"] == "Saving search index"
    assert result["count"] == 1
    assert (
        json.loads((folder / ".imgsearch/manifest.json").read_text())["model_alias"]
        == "clip-vit-b32"
    )
    for query in ({"text": "red"}, {"image": str(folder / "red.png")}):
        result = dispatch(
            {"action": "search", "folder": str(folder), "model": "some-other-model", **query}
        )
        assert result["images"][0]["name"] == "red.png"
        assert result["images"][0]["similarity"] == 1
    assert set(loaded) == {"openai/clip-vit-base-patch32"}


def test_failed_rebuild_preserves_previous_index(tmp_path, monkeypatch):
    import pytest

    monkeypatch.setenv("IMGSEARCH_PROJECT_ROOT", str(tmp_path / "project"))
    folder = tmp_path / "photos"
    index = folder / ".imgsearch"
    index.mkdir(parents=True)
    (index / "original").write_text("keep")
    (folder / "photo.jpg").write_bytes(b"photo")
    with pytest.raises(ValueError, match="Unknown model"):
        dispatch({"action": "index", "folder": str(folder), "model": "invalid", "rebuild": True})
    assert (index / "original").read_text() == "keep"
    assert (folder / "photo.jpg").read_bytes() == b"photo"
    assert not list(folder.glob(".imgsearch-backup-*"))


def test_download_patterns_avoid_other_frameworks_and_duplicate_weights():
    from imgsearch.config import resolve_model
    from imgsearch.desktop import download_patterns

    files = [
        "model.safetensors",
        "pytorch_model.bin",
        "tf_model.h5",
        "flax_model.msgpack",
        "onnx/model.onnx",
    ]
    patterns = download_patterns(resolve_model("clip-vit-b32"), files)
    assert "model.safetensors" in patterns
    assert "pytorch_model.bin" not in patterns
    assert not any("tf_model" in p or "onnx" in p or "flax" in p for p in patterns)
    patterns = download_patterns(resolve_model("clip-vit-b32"), files[1:])
    assert "pytorch_model.bin" in patterns
    assert "*.json" in patterns and "*.txt" in patterns
