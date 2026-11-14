"""Shared pytest fixtures: synthetic images and a fake embedder."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from imgsearch.config import ModelSpec
from imgsearch.core.embedder import EmbedderProtocol


@pytest.fixture
def tmp_image_dir(tmp_path: Path) -> Path:
    """Create a folder with a few tiny colored PNGs."""
    colors = {
        "red.png": (255, 0, 0),
        "green.png": (0, 255, 0),
        "blue.png": (0, 0, 255),
    }
    for name, color in colors.items():
        img = Image.new("RGB", (32, 32), color)
        img.save(tmp_path / name)
    (tmp_path / "sub").mkdir()
    Image.new("RGB", (32, 32), (128, 128, 128)).save(tmp_path / "sub" / "gray.png")
    return tmp_path


@pytest.fixture
def fake_spec() -> ModelSpec:
    return ModelSpec(
        id="test/fake-model",
        dim=8,
        image_size=16,
        family="test",
        display_name="Fake Model",
    )


class FakeEmbedder:
    """Deterministic pseudo-embedder used in tests.

    Maps a filename or string to a stable 8-dim unit vector so that equality
    of identifier implies cosine similarity of 1.
    """

    def __init__(self, spec: ModelSpec) -> None:
        self.spec = spec

    def _vec_for_token(self, token: str) -> np.ndarray:
        rng = np.random.default_rng(abs(hash(token)) % (2**32))
        v = rng.standard_normal(self.spec.dim).astype(np.float32)
        v /= np.linalg.norm(v)
        return v

    def load(self) -> None:  # pragma: no cover - noop
        pass

    def encode_images(self, paths) -> np.ndarray:
        return np.stack([self._vec_for_token(Path(p).stem) for p in paths])

    def encode_pil(self, images) -> np.ndarray:
        # Derive a stable token from the image content size as a proxy for identity.
        return np.stack([self._vec_for_token(str(img.size)) for img in images])

    def encode_text(self, text: str) -> np.ndarray:
        return self._vec_for_token(text.strip().lower())


@pytest.fixture
def fake_embedder(fake_spec: ModelSpec) -> EmbedderProtocol:
    return FakeEmbedder(fake_spec)  # type: ignore[return-value]


# Alias of a second model that exists only inside the `color_engine` fixture.
ALT_MODEL = "alt-model"

NAMED_COLORS: dict[str, tuple[int, int, int]] = {
    "red": (255, 0, 0),
    "green": (0, 255, 0),
    "blue": (0, 0, 255),
}


class ColorEmbedder:
    """Stand-in model for desktop engine tests.

    Embeds an image as its top-left pixel colour and a text query as a named
    colour, so "red" retrieves red images and identical colours are duplicates.
    """

    created: list[str] = []
    loaded: list[str] = []
    before_encode = None  # optional hook: called with the batch size

    def __init__(self, spec: ModelSpec) -> None:
        self.spec = spec
        type(self).created.append(spec.id)

    def load(self) -> None:
        type(self).loaded.append(self.spec.id)

    def _vector(self, color: tuple[int, int, int]) -> np.ndarray:
        vector = np.zeros(self.spec.dim, dtype=np.float32)
        vector[:3] = np.asarray(color, dtype=np.float32) + 1.0
        return vector / np.linalg.norm(vector)

    def encode_pil(self, images) -> np.ndarray:
        hook = type(self).before_encode
        if hook is not None:
            hook(len(images))
        return np.stack([self._vector(img.convert("RGB").getpixel((0, 0))) for img in images])

    def encode_images(self, paths) -> np.ndarray:
        return self.encode_pil([Image.open(p) for p in paths])

    def encode_text(self, text: str) -> np.ndarray:
        return self._vector(NAMED_COLORS.get(text.strip().lower(), (127, 127, 127)))


@pytest.fixture
def color_engine(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> type[ColorEmbedder]:
    """Route the desktop engine to a throwaway project root and the fake model."""
    from imgsearch import config
    from imgsearch.core import embedder

    monkeypatch.setenv("IMGSEARCH_PROJECT_ROOT", str(tmp_path / "project"))
    monkeypatch.setattr(embedder, "create_embedder", ColorEmbedder)
    # The app ships one model; tests need a second to exercise switching.
    monkeypatch.setitem(
        config.MODEL_REGISTRY,
        ALT_MODEL,
        ModelSpec(
            id="test/alt-model", dim=64, image_size=32, family="test", display_name="Alt Model"
        ),
    )
    monkeypatch.setattr(ColorEmbedder, "created", [])
    monkeypatch.setattr(ColorEmbedder, "loaded", [])
    monkeypatch.setattr(ColorEmbedder, "before_encode", None)
    return ColorEmbedder


@pytest.fixture
def photo_folder(tmp_path: Path) -> Path:
    """Six tiny photos: two reds (duplicates), two greens, two blues."""
    folder = tmp_path / "photos"
    folder.mkdir()
    for index, (name, color) in enumerate(NAMED_COLORS.items()):
        Image.new("RGB", (16, 16), color).save(folder / f"{name}.png")
        # Different size on disk so the copies are similar but not byte-identical.
        Image.new("RGB", (24 + index, 24), color).save(folder / f"{name}-copy.png")
    return folder
