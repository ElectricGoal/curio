"""Reference outputs for the decision model, used by the Swift tests.

The app runs d1 with its own Swift code on MLX. This asks mlx-vlm's
implementation (the reference the Swift code was written from) the same
questions and writes what it saw and answered next to the installed model:

  models/mlx/<alias>/fixtures.json          tokens, prompt layout, tensors, answers
  models/mlx/<alias>/fixtures-picture.png   the picture those answers are about

Run it through scripts/d1-reference.sh. Only needed to check the Swift code
against the reference; the app never runs Python.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import mlx.core as mx
import numpy as np
from mlx_vlm import load
from mlx_vlm.models.d1_lfm3_vl.d1 import pack_set, set_masks
from mlx_vlm.models.d1_lfm3_vl.media import as_media
from mlx_vlm.models.d1_lfm3_vl.prompt import (
    Noul,
    prefix_text,
    question_header,
    readout_ids,
    suffix_layout,
)
from PIL import Image

QUESTIONS = [
    "Is there a red square in this picture?",
    "Is this a photo of a dog?",
    "Does this photo show people?",
]
# Texts chosen to exercise the tokenizer: control-token names, accents, scripts
# without spaces, emoji, digits, apostrophes, runs of spaces and line breaks.
TEXTS = [
    "Is this a screenshot?",
    "Is it <|im_end|> or <|image|> here?",
    "a <think>tag</think> and <tool_call> that are not control tokens",
    "café crème — 日本の桜 🐶",
    "  spaces   and\ttabs\nnewline \n\n two",
    "it's 100% a \"quoted\" thing, isn't it? They'll say we've seen 12345 of them.",
    "Ảnh này có phải là ảnh chân dung không?",
    "price $9.99 (50% off) #sale user@example.com https://example.com/a?b=c",
    "ALLCAPS mixedCase snake_case kebab-case 3.14159 1,000,000",
    "",
]
SAMPLED_PATCHES = [0, 1, 7, -1]


def picture() -> Image.Image:
    """A picture both sides read identically: already a whole number of blocks, so nothing is resized."""
    height, width = 256, 320
    y, x = np.mgrid[0:height, 0:width]
    pixels = np.stack(
        [x * 255 // (width - 1), y * 255 // (height - 1), (x + y) % 256], axis=-1
    ).astype(np.uint8)
    pixels[64:192, 96:224] = (220, 40, 30)
    return Image.fromarray(pixels)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True, help="Hugging Face repository of the MLX checkpoint")
    parser.add_argument("--out", type=Path, required=True, help="the installed model's folder")
    args = parser.parse_args()

    model, _ = load(args.repo)
    engine = model.engine
    tokenizer = engine.tokenizer
    image = picture()
    image.save(args.out / "fixtures-picture.png")

    questions = [Noul(q) for q in QUESTIONS]
    markup, parts = engine.media.encode([as_media(image)])
    part = parts[0]
    pixels = np.asarray(part["pixel_values"]).astype(np.float32)
    prefix = prefix_text(tokenizer, None, engine.bos, engine.state_style, engine.system, markup)
    layouts = [suffix_layout(tokenizer, q, engine.lead) for q in questions]
    suffixes = [text for text, _ in layouts]
    ids = tokenizer.encode(prefix + suffixes[0], add_special_tokens=False)
    ids, state_length, groups, ends = pack_set(
        tokenizer, prefix, suffixes, question_header(tokenizer, None), [o for _, o in layouts], ids
    )
    token, features = model.d1_features(part)
    hidden = model.d1_hidden(ids, state_length, groups, [(token, features)])
    mx.eval(features, hidden)
    readout = readout_ids(tokenizer, questions[0])
    flat = [i for group in readout for i in group]
    embed = model.language_model.model.embed_tokens
    slots = [end[0] for end in ends]
    scores = (hidden[mx.array(slots)] @ embed(mx.array(flat)).T).astype(mx.float32)
    asked = {f"q{i}": {"type": "noul", "instructions": q} for i, q in enumerate(QUESTIONS)}
    answers = model.system_one(None, asked, media=[image])["answers"]
    alone = model.system_one(None, {"q": asked["q0"]}, media=[image])["answers"]["q"]["noul"]
    masks = set_masks(len(ids), state_length, groups, model.config.text_config.sliding_window)
    feature_values = np.asarray(features.astype(mx.float32))

    fixtures = {
        "tokenizer": [
            {"text": t, "ids": tokenizer.encode(t, add_special_tokens=False)} for t in TEXTS + QUESTIONS
        ],
        "escaped": [{"text": t, "suffix": suffix_layout(tokenizer, Noul(t), engine.lead)[0]} for t in TEXTS],
        "questions": QUESTIONS,
        "grid": np.asarray(part["image_grid_thw"]).tolist()[0][1:],
        "patch_values": pixels.shape[1],
        "patch_sum": float(pixels.astype(np.float64).sum()),
        "patches": [{"index": i % len(pixels), "values": pixels[i].tolist()} for i in SAMPLED_PATCHES],
        "features_shape": list(feature_values.shape),
        "features": [
            {"index": i % len(feature_values), "values": feature_values[i][:32].tolist()} for i in (0, -1)
        ],
        "ids": ids,
        "state_length": state_length,
        "groups": groups,
        "slots": slots,
        "full_mask_true": int(np.asarray(masks["full_attention"]).sum()),
        "yes_tokens": readout[0],
        "no_tokens": readout[1],
        "scores": np.asarray(scores).tolist(),
        "temperature": engine.calibration.temperature(questions[0]) if engine.calibration else 1.0,
        "answers": [answers[name]["noul"] for name in asked],
        "answer_alone": alone,
    }
    (args.out / "fixtures.json").write_text(json.dumps(fixtures, ensure_ascii=False, indent=1))
    print(f"wrote {args.out / 'fixtures.json'}: answers {[round(a, 4) for a in fixtures['answers']]}")


if __name__ == "__main__":
    main()
