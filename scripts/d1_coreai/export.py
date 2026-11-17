"""Export the d1 decision model to Core AI (.aimodel), checked against MLX.

  uv run (in Apple's coreai-models checkout) python export.py \\
      --checkpoint models/mlx/d1-2b-4bit --inputs <dump>/inputs.json --out <dir> [--compression 4bit|none]

`inputs.json` is what the app builds for one picture and question, with MLX's
scores for it (CURIO_D1_DUMP, see D1CoreAITests). The graph is traced for that
picture grid and row length; masks, ids, patches, slots and tokens stay inputs.

Steps follow Apple's macOS export path (coreai_models.export.macos): optional
int4 weight-only quantization with coreai-opt (per-block 32, as Apple's "4bit"
preset), torch.export, Core AI decompositions, TorchConverter, save_asset.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import numpy as np
import torch

from d1_torch import D1, load_mlx_checkpoint

NEG = float("-inf")


def build_inputs(dump: dict) -> dict[str, torch.Tensor]:
    """The app's inputs as tensors: float16 patches, int32 ids, additive float16 masks."""
    length = len(dump["ids"])

    def additive(mask: list[bool]) -> torch.Tensor:
        allowed = torch.tensor(mask, dtype=torch.bool).view(1, 1, length, length)
        return torch.zeros(allowed.shape, dtype=torch.float16).masked_fill(~allowed, NEG)

    patches = torch.tensor(dump["patches"], dtype=torch.float32).view(-1, dump["patchValues"]).half()
    return {
        "patches": patches,
        "ids": torch.tensor(dump["ids"], dtype=torch.int32),
        "full_mask": additive(dump["fullMask"]),
        "sliding_mask": additive(dump["slidingMask"]),
        "slots": torch.tensor(dump["slots"], dtype=torch.int32),
        "tokens": torch.tensor(dump["yesTokens"] + dump["noTokens"], dtype=torch.int32),
    }


def yes_probability(scores: np.ndarray, dump: dict) -> float:
    yes = scores[: len(dump["yesTokens"])].max()
    no = scores[len(dump["yesTokens"]) :].max()
    return float(1 / (1 + np.exp((no - yes) / dump["temperature"])))


def compare(label: str, scores: torch.Tensor, dump: dict) -> None:
    got = scores.float().cpu().numpy()[0]
    want = np.array(dump["scores"][0], dtype=np.float32)
    print(f"{label}: scores {np.round(got, 3).tolist()}  (MLX {np.round(want, 3).tolist()})  "
          f"max diff {np.abs(got - want).max():.3f}  P(yes) {yes_probability(got, dump):.4f} "
          f"(MLX {yes_probability(want, dump):.4f})")


def quantize(model: D1, inputs: dict, compression: str) -> torch.nn.Module:
    if compression == "none":
        return model
    from coreai_opt.base_model_compressor import ExportBackend
    from coreai_opt.quantization import Quantizer, QuantizerConfig

    # Apple's macOS "4bit" preset: int4, symmetric with clipping, per-block of 32
    # along the input axis. Here on linear layers and the embedding table, which is
    # what the MLX checkpoint packs; norms and the small depthwise convolutions stay float16.
    int4 = {"weight": {"dtype": "int4", "qscheme": "symmetric_with_clipping",
                       "granularity": {"type": "per_block", "block_size": 32, "axis": 1}}}
    weight_only = {"op_state_spec": int4, "op_input_spec": None, "op_output_spec": None}
    config = QuantizerConfig.from_dict({"quantization_config": {
        "execution_mode": "eager",
        "global_config": None,
        "module_type_configs": {
            "torch.nn.modules.linear.Linear": weight_only,
            "torch.nn.modules.sparse.Embedding": weight_only,
        },
    }})
    quantizer = Quantizer(model, config)
    prepared = quantizer.prepare(example_inputs=tuple(inputs.values()))
    finalized = quantizer.finalize(prepared, backend=ExportBackend.CoreAI)
    finalized.eval()
    return finalized


def export(model: torch.nn.Module, inputs: dict, path: Path) -> None:
    import coreai_torch
    from coreai_models.export.mlir_ops import register_custom_torch_lowering, remove_functionalization

    with torch.no_grad():
        program = torch.export.export(model, args=tuple(inputs.values()))
    program = program.run_decompositions(coreai_torch.get_decomp_table())
    remove_functionalization(program)
    converter = coreai_torch.TorchConverter(mode=coreai_torch.TorchConverter.Mode.RELEASE)
    converter.add_exported_program(program, input_names=list(inputs), output_names=["scores"],
                                   entrypoint_name="main")
    register_custom_torch_lowering(converter)
    path.parent.mkdir(parents=True, exist_ok=True)
    converter.to_coreai().save_asset(path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--compression", choices=["4bit", "none"], default="4bit")
    args = parser.parse_args()

    dump = json.loads(args.inputs.read_text())
    config, tensors = load_mlx_checkpoint(args.checkpoint)
    model = D1(config, rows=dump["rows"], columns=dump["columns"], image_start=dump["imageStart"],
               length=len(dump["ids"]))
    model.load_mlx(tensors)
    model.eval()
    inputs = build_inputs(dump)

    # The mirror must agree with MLX before anything is exported.
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    with torch.no_grad():
        compare(f"PyTorch float16 ({device})", model.to(device)(**{k: v.to(device) for k, v in inputs.items()}), dump)
    model.to("cpu")

    started = time.time()
    model = quantize(model, inputs, args.compression)
    if args.compression != "none":
        with torch.no_grad():
            compare(f"PyTorch {args.compression} (cpu)", model(**inputs), dump)
    path = args.out / f"d1-{args.compression}.aimodel"
    export(model, inputs, path)
    print(f"wrote {path} in {time.time() - started:.0f}s")
    (args.out / "geometry.json").write_text(json.dumps({
        "rows": dump["rows"], "columns": dump["columns"], "length": len(dump["ids"]),
        "imageStart": dump["imageStart"], "compression": args.compression}))


if __name__ == "__main__":
    main()
