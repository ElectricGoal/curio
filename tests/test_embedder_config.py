"""Embedder backends: which exist, and MobileCLIP's configuration safeguards."""

from __future__ import annotations

import numpy as np
import pytest

from imgsearch.config import MODEL_REGISTRY, ModelSpec, resolve_model
from imgsearch.core.embedder import MobileCLIPEmbedder, _config_overrides


def test_repo_config_overrides_the_network_sections_only() -> None:
    repo_config = {
        "embed_dim": 768,
        "vision_cfg": {"timm_model_name": "fastvit_mci4", "image_size": 256},
        "text_cfg": {"context_length": 77, "layers": 12, "no_causal_mask": False},
        "custom_text": True,  # consumed by open_clip's factory, not a constructor argument
    }

    overrides = _config_overrides(repo_config)

    assert set(overrides) == {"embed_dim", "vision_cfg", "text_cfg"}
    assert overrides["text_cfg"]["no_causal_mask"] is False


def test_partial_repo_config_is_tolerated() -> None:
    assert _config_overrides({"text_cfg": {"layers": 12}}) == {"text_cfg": {"layers": 12}}
    assert _config_overrides({}) == {}


def _embedder_answering(vectors: dict[str, np.ndarray]) -> MobileCLIPEmbedder:
    embedder = MobileCLIPEmbedder(resolve_model("mobileclip-s4"))
    embedder.encode_text = lambda text: vectors[text]  # type: ignore[method-assign]
    return embedder


def test_self_check_rejects_a_text_encoder_that_ignores_its_input() -> None:
    from imgsearch.core.embedder import _SELF_CHECK_PROMPTS

    same = np.array([1.0, 0.0], dtype=np.float32)
    broken = _embedder_answering(dict.fromkeys(_SELF_CHECK_PROMPTS, same))

    with pytest.raises(RuntimeError, match="not responding to queries"):
        broken._verify_text_encoder()


def test_self_check_accepts_a_discriminating_text_encoder() -> None:
    from imgsearch.core.embedder import _SELF_CHECK_PROMPTS

    healthy = _embedder_answering(
        {
            _SELF_CHECK_PROMPTS[0]: np.array([1.0, 0.0], dtype=np.float32),
            _SELF_CHECK_PROMPTS[1]: np.array([0.6, 0.8], dtype=np.float32),
        }
    )

    healthy._verify_text_encoder()  # does not raise


def test_every_registered_model_has_a_backend() -> None:
    from imgsearch.core.embedder import CLIPEmbedder, create_embedder

    backends = {alias: type(create_embedder(spec)) for alias, spec in MODEL_REGISTRY.items()}

    assert backends == {"mobileclip-s4": MobileCLIPEmbedder, "clip-vit-b32": CLIPEmbedder}


def test_unknown_backend_is_rejected_instead_of_guessed() -> None:
    from imgsearch.core.embedder import create_embedder

    spec = ModelSpec(id="x/y", dim=8, image_size=16, family="siglip", display_name="Gone")
    with pytest.raises(ValueError, match="No embedder backend for model family 'siglip'"):
        create_embedder(spec)


def test_the_removed_mlx_backend_is_not_importable() -> None:
    import imgsearch.core.embedder as embedder

    assert not hasattr(embedder, "MLXEmbedder")
