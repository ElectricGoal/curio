"""Convert the app's models from PyTorch to Core ML.

The app's engine is Swift and runs Core ML models; this is the one place
Python is still needed, and only at build time. Run it through
scripts/convert-models.sh, which supplies an isolated environment.

For each model this writes models/coreml/<alias>/ containing:

  image.mlpackage   RGB image in 0…1, shape [1, 3, S, S]  → unit-length embedding
  text.mlpackage    token ids, shape [1, 77]              → unit-length embedding
  bpe_merges.txt    the CLIP tokenizer's merge rules
  model.json        what the engine needs to know to use the above
  fixtures.json     inputs with PyTorch's outputs, used by the engine's tests
  files.json        every file a download needs, with its size and SHA-256

To let the app download a model, serve models/coreml/ from any static host and
give the app that address (ImageSearchModelsURL; see scripts/build-dmg.sh).

Weights are float16: on the GPU that reproduced PyTorch's search rankings
exactly in our benchmark, at half the size and well over the speed.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import shutil
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

import coremltools as ct  # noqa: E402
import numpy as np  # noqa: E402
import torch  # noqa: E402

CONTEXT_LENGTH = 77
START_TOKEN, END_TOKEN = 49406, 49407
# Texts chosen to exercise the tokenizer: case, punctuation, digits, accents,
# apostrophes, repeated spaces, emoji, and a prompt longer than the context.
TOKENIZER_CASES = [
    "a quiet beach at sunset",
    "A Photo of a DOG!",
    "red succulent plants at night",
    "it's a cat's toy, isn't it?",
    "2 dogs and 13 cats in 2024",
    "café crème brûlée",
    "hello   world\t\ttabs  and   spaces ",
    "state-of-the-art e-mail: user@example.com",
    "price $9.99 (50% off) #sale",
    "naïve façade — über cool",
    "日本の桜",
    "a 🐶 on the beach",
    "",
    "word " * 120,
]
LISTING = "files.json"
# Not needed to run a model, so left out of downloads and app bundles.
BUILD_ONLY = {LISTING, "fixtures.json"}
EMBEDDING_PROMPTS = ["a quiet beach at sunset", "a red sports car", "a diagram of a neural network"]


class Normalised(torch.nn.Module):
    """Wraps one tower of a model so its output is an L2-normalised embedding.

    The model is held as a submodule (not a bound method) so tracing sees its
    weights as parameters.
    """

    def __init__(self, model: torch.nn.Module, encode):
        super().__init__()
        self.model = model
        self._encode = encode

    def forward(self, value):
        features = self._encode(self.model, value)
        return features / features.norm(dim=-1, keepdim=True)


def load_mobileclip(hub: Path):
    import open_clip
    from huggingface_hub import hf_hub_download
    from timm.utils import reparameterize_model

    repo = "apple/MobileCLIP-S4"
    checkpoint = hf_hub_download(repo, "mobileclip_s4.pt", cache_dir=str(hub))
    config = json.loads(Path(hf_hub_download(repo, "config.json", cache_dir=str(hub))).read_text())
    # The checkpoint's own config must win over open_clip's built-in one, which
    # disables the causal text mask these weights were trained with.
    overrides = {k: config[k] for k in ("embed_dim", "vision_cfg", "text_cfg") if k in config}
    model, _, _ = open_clip.create_model_and_transforms(
        "MobileCLIP2-S4", pretrained=checkpoint,
        image_mean=(0.0, 0.0, 0.0), image_std=(1.0, 1.0, 1.0), **overrides,
    )
    model = reparameterize_model(model.eval())
    tokenizer = open_clip.get_tokenizer("MobileCLIP2-S4")

    def tokenize(text: str) -> list[int]:
        return tokenizer([text])[0].tolist()

    return {
        "name": "MobileCLIP-S4 (Apple)", "dim": 768, "image_size": 256, "pad_token": 0,
        "image": Normalised(model, lambda m, image: m.encode_image(image)),
        "text": Normalised(model, lambda m, tokens: m.encode_text(tokens)),
        "tokenize": tokenize, "license": "apple-amlr (research use only)",
    }


def load_clip(hub: Path):
    from transformers import CLIPModel, CLIPTokenizer

    repo = "openai/clip-vit-base-patch32"
    model = CLIPModel.from_pretrained(repo, cache_dir=str(hub)).eval()
    tokenizer = CLIPTokenizer.from_pretrained(repo, cache_dir=str(hub))
    mean = torch.tensor([0.48145466, 0.4578275, 0.40821073]).view(1, 3, 1, 1)
    std = torch.tensor([0.26862954, 0.26130258, 0.27577711]).view(1, 3, 1, 1)

    def encode_image(clip, image):
        # The normalisation the processor would apply is part of the model here.
        output = clip.vision_model(pixel_values=(image - mean) / std)
        return clip.visual_projection(output.pooler_output)

    def encode_text(clip, tokens):
        output = clip.text_model(input_ids=tokens)
        return clip.text_projection(output.pooler_output)

    def tokenize(text: str) -> list[int]:
        ids = tokenizer(text, truncation=True, max_length=CONTEXT_LENGTH)["input_ids"]
        # Padding with the end token leaves the pooled (first end token) output unchanged.
        return ids + [END_TOKEN] * (CONTEXT_LENGTH - len(ids))

    return {
        "name": "OpenAI CLIP ViT-B/32", "dim": 512, "image_size": 224, "pad_token": END_TOKEN,
        "image": Normalised(model, encode_image), "text": Normalised(model, encode_text),
        "tokenize": tokenize, "license": "MIT",
    }


LOADERS = {"mobileclip-s4": load_mobileclip, "clip-vit-b32": load_clip}


def merges() -> list[str]:
    """The CLIP byte-pair merge rules, in priority order."""
    import open_clip

    path = Path(open_clip.__file__).parent / "bpe_simple_vocab_16e6.txt.gz"
    with gzip.open(path) as handle:
        lines = handle.read().decode("utf-8").split("\n")
    return lines[1 : 49152 - 256 - 2 + 1]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def write_listing(target: Path) -> int:
    """Write files.json for a converted model; returns the bytes it lists."""
    if not (target / "model.json").is_file():
        raise SystemExit(f"{target} holds no converted model; convert it first.")
    files = sorted(
        f for f in target.rglob("*")
        if f.is_file() and f.name not in BUILD_ONLY and not f.name.startswith(".")
    )
    listing = [
        {"path": f.relative_to(target).as_posix(), "size": f.stat().st_size, "sha256": sha256(f)}
        for f in files
    ]
    (target / LISTING).write_text(json.dumps(listing, indent=2))
    return sum(entry["size"] for entry in listing)


def convert(alias: str, hub: Path, out: Path) -> None:
    spec = LOADERS[alias](hub)
    size = spec["image_size"]
    target = out / alias
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)

    torch.manual_seed(0)
    images = torch.rand(2, 3, size, size)
    # A flat colour and a gradient: easy to rebuild exactly in the Swift tests.
    images[0] = torch.tensor([0.8, 0.2, 0.1]).view(3, 1, 1).expand(3, size, size)
    images[1] = torch.linspace(0, 1, size).view(1, 1, size).expand(3, size, size)
    prompts = [torch.tensor([spec["tokenize"](p)], dtype=torch.int32) for p in EMBEDDING_PROMPTS]

    fixtures: dict[str, object] = {"tokenizer": [], "text": [], "image": []}
    with torch.no_grad():
        image_encoder = torch.jit.trace(spec["image"].eval(), images[:1])
        text_encoder = torch.jit.trace(spec["text"].eval(), prompts[0])
        for index in range(images.shape[0]):
            fixtures["image"].append(
                {"name": ["flat", "gradient"][index],
                 "embedding": image_encoder(images[index : index + 1])[0].tolist()})
        for prompt, tokens in zip(EMBEDDING_PROMPTS, prompts, strict=True):
            fixtures["text"].append(
                {"text": prompt, "embedding": text_encoder(tokens)[0].tolist()})
    fixtures["tokenizer"] = [{"text": t, "tokens": spec["tokenize"](t)} for t in TOKENIZER_CASES]

    for name, traced, example in (
        ("image", image_encoder, ct.TensorType(name="image", shape=(1, 3, size, size), dtype=np.float32)),
        ("text", text_encoder, ct.TensorType(name="tokens", shape=(1, CONTEXT_LENGTH), dtype=np.int32)),
    ):
        model = ct.convert(
            traced, inputs=[example], outputs=[ct.TensorType(name="embedding")],
            convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
            minimum_deployment_target=ct.target.macOS14,
        )
        model.author = "Converted for ImageSearch"
        model.license = spec["license"]
        model.save(str(target / f"{name}.mlpackage"))

    (target / "bpe_merges.txt").write_text("\n".join(merges()), encoding="utf-8")
    (target / "fixtures.json").write_text(json.dumps(fixtures))
    (target / "model.json").write_text(json.dumps({
        "format": 1, "alias": alias, "name": spec["name"], "dim": spec["dim"],
        "image_size": size, "context_length": CONTEXT_LENGTH, "pad_token": spec["pad_token"],
        "start_token": START_TOKEN, "end_token": END_TOKEN, "precision": "float16",
        "license": spec["license"],
        "image_model": "image.mlpackage", "text_model": "text.mlpackage",
        "merges": "bpe_merges.txt",
    }, indent=2))
    megabytes = write_listing(target) / 1e6
    print(f"{alias}: {megabytes:.0f} MB in {target}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--hub", type=Path, required=True, help="Hugging Face cache for source weights")
    parser.add_argument("--out", type=Path, required=True, help="models/coreml")
    parser.add_argument(
        "--listing-only", action="store_true",
        help="rewrite files.json for models already converted, without converting again")
    parser.add_argument("aliases", nargs="*", default=list(LOADERS))
    args = parser.parse_args()
    unknown = sorted(set(args.aliases) - set(LOADERS))
    if unknown:
        parser.error(f"unknown model: {', '.join(unknown)} (choose from {', '.join(LOADERS)})")
    for alias in args.aliases or list(LOADERS):
        if args.listing_only:
            megabytes = write_listing(args.out / alias) / 1e6
            print(f"{alias}: listed {megabytes:.0f} MB", flush=True)
        else:
            convert(alias, args.hub, args.out)


if __name__ == "__main__":
    main()
