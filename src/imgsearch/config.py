"""Central configuration: model registry, defaults, supported formats."""

from __future__ import annotations

import platform
from dataclasses import dataclass
from typing import Final

INDEX_DIR_NAME: Final = ".imgsearch"
MANIFEST_FILE: Final = "manifest.json"
META_DB_FILE: Final = "meta.db"
FAISS_FILE: Final = "index.faiss"
MANIFEST_VERSION: Final = 1

# File extensions are lowercase with leading dot
SUPPORTED_EXTENSIONS: Final[frozenset[str]] = frozenset(
    {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif", ".tif", ".tiff", ".bmp", ".gif"}
)


@dataclass(frozen=True)
class ModelSpec:
    """Specification for an embedding model."""

    id: str  # HuggingFace repo id
    dim: int  # output embedding dimension
    image_size: int  # square input resolution expected by preprocessor
    family: str  # embedder backend: "mobileclip" | "clip"
    display_name: str


# Registry of supported models. Keys are short aliases used by --model.
#
# Measured on Apple Silicon (peak memory footprint while indexing, batch 8):
#
#   mobileclip-s4   4.3 GB    24 img/s   default: the best search quality here
#   clip-vit-b32    1.7 GB   125 img/s   the light option for 8 GB Macs
#
# Removed, along with the MLX backend they needed: siglip-so400m (both sizes),
# siglip2-base-8bit (failed inside mlx-embeddings) and clip-vit-l14. Indexes
# built with a removed model are reported as needing a rebuild.
MODEL_REGISTRY: Final[dict[str, ModelSpec]] = {
    # Apple MobileCLIP via open_clip on PyTorch MPS. Requires ml-mobileclip.
    "mobileclip-s4": ModelSpec(
        id="apple/MobileCLIP-S4",
        dim=768,
        image_size=256,
        family="mobileclip",
        display_name="MobileCLIP-S4 (Apple)",
    ),
    # OpenAI CLIP via Transformers on PyTorch MPS.
    "clip-vit-b32": ModelSpec(
        id="openai/clip-vit-base-patch32",
        dim=512,
        image_size=224,
        family="clip",
        display_name="OpenAI CLIP ViT-B/32",
    ),
}

DEFAULT_MODEL_ALIAS: Final = "mobileclip-s4"
DEFAULT_BATCH_SIZE: Final = 16
DEFAULT_TOP_K: Final = 10


def resolve_model(alias_or_id: str) -> ModelSpec:
    """Resolve a user-provided model string (alias or full HF id) to a ModelSpec."""
    if alias_or_id in MODEL_REGISTRY:
        return MODEL_REGISTRY[alias_or_id]
    # Allow passing a full HF id for any registered model by id as well
    for spec in MODEL_REGISTRY.values():
        if spec.id == alias_or_id:
            return spec
    raise ValueError(
        f"Unknown model: {alias_or_id!r}. Available aliases: {', '.join(MODEL_REGISTRY)}"
    )


class PlatformError(RuntimeError):
    """Raised when the current platform cannot run imgsearch."""


def check_platform() -> None:
    """Verify we are on macOS arm64. Raises PlatformError otherwise."""
    system = platform.system()
    machine = platform.machine()
    if system != "Darwin":
        raise PlatformError(
            f"imgsearch requires macOS (Darwin), got {system}. "
            "GPU acceleration (Metal) is only available on Apple Silicon."
        )
    if machine not in {"arm64", "aarch64"}:
        raise PlatformError(
            f"imgsearch requires Apple Silicon (arm64), got {machine}. "
            "Intel Macs are not supported."
        )
