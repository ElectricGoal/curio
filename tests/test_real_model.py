"""Real-weights check that text search with the shipped model discriminates.

Opt in with ``IMGSEARCH_REAL_MODEL=1`` once the model is downloaded; it loads
real weights, so it is skipped in the normal suite.

Why this exists: a model can load without complaint and still be useless. A
previously bundled model was built with the wrong text-encoder settings, so
every query produced nearly the same embedding and searches returned the same
images no matter what was typed. Only a test against real weights catches that.
"""

from __future__ import annotations

import os
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from imgsearch.config import DEFAULT_MODEL_ALIAS

pytestmark = pytest.mark.skipif(
    os.environ.get("IMGSEARCH_REAL_MODEL") != "1",
    reason="set IMGSEARCH_REAL_MODEL=1 to load real model weights",
)

COLORS = {"red": (220, 30, 30), "green": (30, 170, 60), "blue": (30, 60, 220)}


@pytest.fixture(scope="module")
def embedder():
    from imgsearch.config import resolve_model
    from imgsearch.core.embedder import create_embedder
    from imgsearch.desktop.storage import configure_storage

    configure_storage()  # use the project's own model cache
    instance = create_embedder(resolve_model(DEFAULT_MODEL_ALIAS))
    instance.load()
    return instance


def test_different_queries_get_different_embeddings(embedder) -> None:
    first = embedder.encode_text("a winding road through hills")
    second = embedder.encode_text("red succulent plants at night")
    assert float(first @ second) < 0.9


def test_text_query_finds_the_matching_image(embedder, tmp_path: Path) -> None:
    paths = []
    for name, color in COLORS.items():
        path = tmp_path / f"{name}.png"
        Image.new("RGB", (256, 256), color).save(path)
        paths.append(path)
    images = embedder.encode_images(paths)

    for index, name in enumerate(COLORS):
        query = embedder.encode_text(f"a solid {name} square")
        assert int(np.argmax(images @ query)) == index, f"{name!r} did not rank first"
