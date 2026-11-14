"""Embedding backends.

Each backend turns images and text into L2-normalized float32 vectors that can
be compared with a dot product. Two are available, both on PyTorch with the
Apple GPU (MPS): MobileCLIP via open_clip, and OpenAI CLIP via Transformers.

Model frameworks are imported lazily so unit tests that mock the embedder stay
fast and `imgsearch --help` does not load a model.
"""

from __future__ import annotations

import json
from collections.abc import Sequence
from pathlib import Path
from typing import Any, Protocol

import numpy as np
from PIL import Image

from imgsearch.config import ModelSpec
from imgsearch.core.preprocess import load_rgb


class EmbedderProtocol(Protocol):
    """Interface used by the Index facade. Allows test doubles."""

    spec: ModelSpec

    def encode_images(self, paths: Sequence[Path]) -> np.ndarray: ...
    def encode_pil(self, images: Sequence[Image.Image]) -> np.ndarray: ...
    def encode_text(self, text: str) -> np.ndarray: ...


def _l2_normalize(x: np.ndarray) -> np.ndarray:
    """Row-wise L2 normalization. Safe on zero rows."""
    if x.ndim == 1:
        norm = float(np.linalg.norm(x))
        return x if norm == 0.0 else (x / norm).astype(np.float32, copy=False)
    norms = np.linalg.norm(x, axis=1, keepdims=True)
    norms = np.where(norms == 0.0, 1.0, norms)
    return (x / norms).astype(np.float32, copy=False)


# Sections of a model repository's config.json that define the network itself.
_MODEL_CONFIG_SECTIONS = ("embed_dim", "vision_cfg", "text_cfg")
_SELF_CHECK_PROMPTS = ("a winding road through green hills", "a bowl of ripe strawberries")
# Healthy CLIP text encoders put unrelated prompts well below this; a broken
# one that ignores its input scores ~0.999.
_SELF_CHECK_MAX_SIMILARITY = 0.9


def _config_overrides(repo_config: dict[str, Any]) -> dict[str, Any]:
    """Model settings from a checkpoint's own config, to override open_clip's.

    open_clip is asked for a built-in architecture by name, and its config for
    that name is not guaranteed to match a given checkpoint. For
    apple/MobileCLIP-S4 the built-in "MobileCLIP2-S4" config sets
    ``no_causal_mask: true`` while the weights were trained with the causal
    mask (``false`` in the repo). Loading succeeds either way — every tensor
    has the same shape — but without the mask the text encoder collapses and
    every query gets practically the same embedding.
    """
    return {key: repo_config[key] for key in _MODEL_CONFIG_SECTIONS if key in repo_config}


class MobileCLIPEmbedder:
    """Production embedder backed by Apple MobileCLIP via open_clip + PyTorch MPS.

    Apple's MobileCLIP HF repos (e.g. apple/MobileCLIP-S4) ship a raw PyTorch
    checkpoint (*.pt), not an open_clip config bundle. The ml-mobileclip package
    registers the custom fastvit_mci* architectures with open_clip at import
    time, after which open_clip.create_model_and_transforms can build the model
    from its architecture name ("MobileCLIP2-S4") and load the checkpoint.
    """

    # Map HF repo id → (open_clip architecture name, checkpoint filename).
    # MobileCLIP-S4 uses the MobileCLIP2-S4 architecture config (identical
    # fastvit_mci4 encoder); only the training data/procedure differs.
    _MODEL_MAP: dict[str, tuple[str, str]] = {
        "apple/MobileCLIP-S4": ("MobileCLIP2-S4", "mobileclip_s4.pt"),
        "apple/MobileCLIP2-S4": ("MobileCLIP2-S4", "mobileclip2_s4.pt"),
    }
    _CONFIG_FILENAME = "config.json"

    def __init__(self, spec: ModelSpec) -> None:
        self.spec = spec
        self._model: Any = None
        self._preprocess: Any = None
        self._tokenizer: Any = None
        self._device: Any = None
        # Eagerly import torch here so its bundled OpenMP runtime loads *before*
        # faiss-cpu's bundled OpenMP (imported lazily by VectorStore). Loading
        # faiss first causes a silent SIGSEGV the first time we touch a torch
        # tensor on macOS arm64. Running the import here — in the constructor
        # called by commands/*.py — guarantees the correct ordering regardless
        # of when Index() lazily imports faiss.
        try:
            import torch  # type: ignore[import-not-found]  # noqa: F401
        except ImportError as exc:
            raise RuntimeError(
                "MobileCLIP requires torch, open-clip-torch, and ml-mobileclip. "
                "Install with: uv sync --extra mobileclip"
            ) from exc

    def load(self) -> None:
        """Download (if needed) and load model. Idempotent."""
        if self._model is not None:
            return
        try:
            import mobileclip  # type: ignore[import-not-found]  # noqa: F401  (registers architectures)
            import open_clip  # type: ignore[import-not-found]
            import torch  # type: ignore[import-not-found]
            from huggingface_hub import hf_hub_download  # type: ignore[import-not-found]
            from mobileclip.modules.common.mobileone import (  # type: ignore[import-not-found]
                reparameterize_model,
            )
        except ImportError as exc:
            raise RuntimeError(
                "MobileCLIP requires torch, open-clip-torch, and ml-mobileclip. "
                "Install with: uv sync --extra mobileclip"
            ) from exc

        entry = self._MODEL_MAP.get(self.spec.id)
        if entry is None:
            raise RuntimeError(
                f"No MobileCLIP load recipe for HF repo {self.spec.id!r}. "
                f"Known repos: {', '.join(self._MODEL_MAP)}"
            )
        arch_name, ckpt_filename = entry

        ckpt_path = hf_hub_download(repo_id=self.spec.id, filename=ckpt_filename)
        # The repository ships the exact configuration its weights were trained
        # with. It must win over open_clip's built-in config for `arch_name`,
        # which differs in ways that matter (see `_config_overrides`).
        config_path = hf_hub_download(repo_id=self.spec.id, filename=self._CONFIG_FILENAME)
        overrides = _config_overrides(json.loads(Path(config_path).read_text()))

        # Apple's README passes these kwargs; they disable open_clip's default
        # ImageNet normalization because the MobileCLIP preprocessing pipeline
        # already handles scaling.
        model_kwargs = {"image_mean": (0.0, 0.0, 0.0), "image_std": (1.0, 1.0, 1.0)}
        model, _, preprocess = open_clip.create_model_and_transforms(
            arch_name, pretrained=ckpt_path, **model_kwargs, **overrides
        )
        model.eval()
        # Fuse reparameterizable branches (MobileOne / FastViT) for inference speed.
        model = reparameterize_model(model)

        self._device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
        model.to(self._device)
        self._model = model
        self._preprocess = preprocess
        self._tokenizer = open_clip.get_tokenizer(arch_name)
        try:
            self._verify_text_encoder()
        except Exception:
            self._model = None  # never serve searches from a model that failed its check
            raise

    def _verify_text_encoder(self) -> None:
        """Fail loudly if the text encoder ignores its input.

        A mis-configured text tower still loads and still returns unit vectors,
        but maps every query to nearly the same one — search then "works" while
        returning the same images for anything typed. Two unrelated prompts
        must land clearly apart.
        """
        first, second = (self.encode_text(prompt) for prompt in _SELF_CHECK_PROMPTS)
        similarity = float(first @ second)
        if similarity > _SELF_CHECK_MAX_SIMILARITY:
            raise RuntimeError(
                f"{self.spec.display_name} loaded, but its text encoder is not responding to "
                f"queries (unrelated prompts are {similarity:.3f} similar). Text search would "
                "return meaningless results; the installed open-clip-torch version may be "
                "incompatible with this model."
            )

    def encode_images(self, paths: Sequence[Path]) -> np.ndarray:
        """Encode image files from disk. Returns (N, dim) L2-normalized float32."""
        if not paths:
            return np.zeros((0, self.spec.dim), dtype=np.float32)
        self.load()
        images = [load_rgb(p) for p in paths]
        return self.encode_pil(images)

    def encode_pil(self, images: Sequence[Any]) -> np.ndarray:
        """Encode pre-loaded PIL images. Returns (N, dim) L2-normalized float32."""
        if not images:
            return np.zeros((0, self.spec.dim), dtype=np.float32)
        self.load()
        import torch  # type: ignore[import-not-found]

        tensors = torch.stack([self._preprocess(img) for img in images]).to(self._device)
        with torch.no_grad():
            feats = self._model.encode_image(tensors)
            feats = feats / feats.norm(dim=-1, keepdim=True)
        arr = feats.cpu().float().numpy()
        if arr.ndim != 2 or arr.shape[1] != self.spec.dim:
            raise RuntimeError(
                f"Unexpected image feature shape {arr.shape}, expected (*, {self.spec.dim})"
            )
        return arr.astype(np.float32, copy=False)

    def encode_text(self, text: str) -> np.ndarray:
        """Encode a single text query. Returns (dim,) L2-normalized float32."""
        if not text or not text.strip():
            raise ValueError("text query must be non-empty")
        self.load()
        import torch  # type: ignore[import-not-found]

        tokens = self._tokenizer([text]).to(self._device)
        with torch.no_grad():
            feats = self._model.encode_text(tokens)
            feats = feats / feats.norm(dim=-1, keepdim=True)
        arr = feats.cpu().float().numpy()
        if arr.ndim == 2:
            arr = arr[0]
        if arr.shape[0] != self.spec.dim:
            raise RuntimeError(
                f"Unexpected text feature shape {arr.shape}, expected ({self.spec.dim},)"
            )
        return arr.astype(np.float32, copy=False)


class CLIPEmbedder:
    """CLIP via Transformers on Apple Metal, with project-local HF weights."""

    def __init__(self, spec: ModelSpec) -> None:
        import torch

        self.spec = spec
        self._torch = torch
        self._device = "mps" if torch.backends.mps.is_available() else "cpu"
        self._model = None
        self._processor = None

    def load(self) -> None:
        if self._model is not None:
            return
        from transformers import CLIPModel, CLIPProcessor

        self._processor = CLIPProcessor.from_pretrained(self.spec.id)
        self._model = CLIPModel.from_pretrained(self.spec.id).eval().to(self._device)

    def encode_images(self, paths: Sequence[Path]) -> np.ndarray:
        return self.encode_pil([load_rgb(p) for p in paths])

    def encode_pil(self, images: Sequence[Any]) -> np.ndarray:
        if not images:
            return np.zeros((0, self.spec.dim), dtype=np.float32)
        self.load()
        inputs = self._processor(images=list(images), return_tensors="pt").to(self._device)
        with self._torch.inference_mode():
            output = self._model.vision_model(pixel_values=inputs["pixel_values"])
            features = self._model.visual_projection(output.pooler_output)
        return _l2_normalize(features.cpu().float().numpy())

    def encode_text(self, text: str) -> np.ndarray:
        if not text.strip():
            raise ValueError("text query must be non-empty")
        self.load()
        inputs = self._processor(
            text=[text], padding=True, truncation=True, return_tensors="pt"
        ).to(self._device)
        with self._torch.inference_mode():
            output = self._model.text_model(**inputs)
            features = self._model.text_projection(output.pooler_output)
        return _l2_normalize(features.cpu().float().numpy()[0])


def create_embedder(spec: ModelSpec) -> MobileCLIPEmbedder | CLIPEmbedder:
    """Factory: return the embedder backend for the given ModelSpec."""
    if spec.family == "mobileclip":
        return MobileCLIPEmbedder(spec)
    if spec.family == "clip":
        return CLIPEmbedder(spec)
    raise ValueError(
        f"No embedder backend for model family {spec.family!r} ({spec.display_name}). "
        "Available backends: mobileclip, clip."
    )
