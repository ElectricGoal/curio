# Core AI beside MLX: Liquid d1-2B (4-bit)

An experiment on branch `feat/coreai-d1`: the decision model that answers careful filter steps, run by Apple's Core AI (macOS 27) next to the MLX runtime the app ships, on the same pictures and question.

Measured 2026-11-17 on an Apple M2 Pro with 16 GB, macOS 27.2, Xcode 27.2, release builds. Raw numbers: [`benchmark-results/d1-coreai-vs-mlx.json`](benchmark-results/d1-coreai-vs-mlx.json).

## Results

30 square photos (each read as a 24 × 24 patch grid, 144 image tokens), one question per pass ("a photo of mountains", a 177-token row), one runtime per process.

| | MLX (shipping) | Core AI |
|---|---|---|
| **Time per image** (median of 30) | **0.184 s** | 0.250 s (36% slower) |
| Spread (min–max) | 0.182–0.197 s | 0.249–0.257 s |
| Load, model cached | 0.50–0.86 s | 0.67 s |
| Load, first ever | — | 2.9 s (compiles the model for this GPU, then cached) |
| First answer after load | 0.23–0.28 s | 0.27 s (2.4 s on the very first run) |
| **GPU memory in use** (driver counter, increase during the run) | **+2,253 MB** | **+1,585 MB** (−30%) |
| Process footprint, peak | 2,244 MB | 309 MB, plus 1,040 MB of model file mapped read-only |
| Model on disk | 1.35 GB | 1.0 GB |
| Same yes/no as MLX at 0.5 | — | 28 of 30 (P(yes) differs by 0.046 on average, 0.21 at most) |

**Speed:** MLX is faster per image, by about 65 ms. The Core AI graph is a straightforward PyTorch export with no hand-tuning (no fused QKV projection, stock attention on padded fixed shapes), so some of the gap may close with Apple's authoring guidance; it is not closed here.

**Memory:** Core AI uses about 0.7 GB less. MLX copies its weights into its own GPU buffers and keeps a 512 MB buffer cache, all of which counts as the app's memory. Core AI maps the model file and lets the GPU read the weights from it: those pages are clean, so macOS can drop and re-read them under pressure instead of swapping, and they do not count toward the app's footprint (292 MB, of which 31 MB are GPU buffers). The fair comparison is the GPU driver's own "in use" counter, which counts both: +2.25 GB against +1.59 GB.

**Answers:** close but not identical. Both are 4-bit, but quantized differently: the MLX checkpoint is Liquid's affine quantization in groups of 64; the Core AI model re-quantizes the same weights with coreai-opt (symmetric, blocks of 32, Apple's macOS "4bit" preset). Quantizing twice moves some answers: two of 30 pictures land on the other side of 0.5. Exporting from the original bfloat16 weights would avoid the double quantization.

## 8-bit (the app's default decision model)

The same benchmark with Liquid's 8-bit MLX checkpoint (`d1-2b`) and the same weights re-quantized to int8 for Core AI (blocks of 32, the 4-bit preset's layout with int8; Apple has no 8-bit weight preset).

| | MLX 8-bit (shipping default) | Core AI int8 |
|---|---|---|
| **Time per image** (median of 30) | **0.186–0.188 s** | 0.293 s (57% slower) |
| Load, model cached | 1.15 s | 1.04 s |
| Load, first ever | — | 8.8 s (compiling for this GPU, then cached) |
| **GPU memory in use** (driver counter, increase) | +3,344 to +3,440 MB | **+2,857 MB** (about −0.5 GB, −15%) |
| Process footprint, peak | 3,108 MB | 311 MB, plus 1.9 GB of model file mapped read-only |
| Model on disk | 2.22 GB | 1.9 GB |
| Same yes/no as MLX at 0.5 | — | **30 of 30** (P(yes) differs by 0.002 on average, 0.011 at most) |

At 8 bits re-quantizing costs almost nothing: every answer agrees with MLX. But the speed gap widens. MLX takes the same time at 8 bits as at 4 (0.186 s against 0.184 s); Core AI slows from 0.250 s to 0.293 s, as if it were limited by reading weights, where MLX is not. The memory saving shrinks to about half a gigabyte.

## Is the Core AI implementation correct?

Checked against the verification gates in Apple's Core AI skills (`coreai-skills`: working-with-coreai, model-authoring), on the same inputs the app builds:

| Gate | 4-bit | 8-bit | Expected |
|---|---|---|---|
| Re-authored PyTorch (float16) vs source (MLX) | 71.3 dB, max diff 0.006 | 68.6 dB, max diff 0.008 | > 70 dB |
| Compiled Core AI vs PyTorch, same quantized weights | 75.7 dB, max diff 0.003 | 66.0 dB, max diff 0.011 | ≥ 40 dB |

The compiled model computes what the PyTorch model does; the 8-bit mirror's 68.6 dB is MLX's own float16 rounding (the largest gap is 0.008 on scores of 2–12), not a modelling error. Differences in answers against MLX come from re-quantizing, not from the export.

**Compute unit.** Loaded with default options, Core AI first tries the Neural Engine, which cannot take block-quantized weights ("groups / block / batch quantization not supported on ANEC"), then runs on the GPU. Asking for the GPU explicitly (`SpecializationOptions(preferredComputeUnitKind: .gpu)`, now the loader's default) gives the same speed — 0.251 s against 0.253 s at 4 bits, 0.297 s against 0.293 s at 8 — so the results above stand.

**Not done: Apple's composite ops.** Apple's macOS export path swaps RMSNorm, rotary positions and attention for Core AI composite ops (`coreai_torch.composite_ops` RMSNorm, RoPE, SDPA with a sliding `window_size`) and externalizes them. This export writes them as plain PyTorch ops, with sliding attention as a full mask: correct, but more operations per layer, and a likely part of the speed gap. That is the first thing to try before concluding Core AI is slower.

## Verdict

Not worth switching yet. MLX answers 1.36× faster at 4 bits and 1.57× faster at 8 bits, handles any picture shape and up to 16 questions per pass, and runs on macOS 14. Core AI saves about 0.7 GB of GPU memory, which matters on 8 GB Macs, but needs macOS 27, a fixed picture grid and row length per exported graph (or one graph per shape), and loses a little accuracy through re-quantization. Worth revisiting: use Core AI's composite ops (RMSNorm, RoPE, windowed SDPA) as Apple's export path does, export from the bfloat16 checkpoint, apply Apple's other GPU authoring patterns (fused QKV), and export a few picture shapes as separate functions.

## How it was built

- `scripts/d1_coreai/d1_torch.py` — the network in plain PyTorch, a line-for-line mirror of the app's `D1Network.swift`, loading the MLX checkpoint's weights (4-bit unpacked to float16). Checked against MLX on the same inputs: scores within 0.006, P(yes) identical (0.9681).
- `scripts/d1_coreai/export.py` — int4 weight quantization with coreai-opt, `torch.export`, Core AI decompositions, `TorchConverter`, `.aimodel`; follows Apple's `coreai-models` macOS export path.
- `CoreAIDecisionModel` (`macos/Sources/CurioKit/Engine/Decision/CoreAIDecisionModel.swift`) — a `DecisionModel` on Core AI, macOS 27 only, sharing the app's picture layout, prompt, masks and calibration with the MLX model; only the network runtime differs. Not wired into the app.
- `D1CoreAITests` — opt-in: writes the app's inputs for the export (`CURIO_D1_DUMP`), and benchmarks one runtime per process (`CURIO_D1_BENCH`).

## Reproducing

```bash
# 1. The MLX 4-bit checkpoint in models/mlx/d1-2b-4bit (the app's catalog files), and MLX shaders
bash scripts/build-mlx-shaders.sh
# 2. Apple's toolchain: git clone https://github.com/apple/coreai-models && (cd coreai-models && uv sync)
# 3. The app's inputs for one square picture, with MLX's scores
CURIO_D1_DUMP=/tmp/d1dump CURIO_D1_IMAGE=photo.jpg swift test --package-path macos --filter D1CoreAITests/testDumpInputsForTheCoreAIExport
# 4. Export (checks the PyTorch mirror against MLX first)
cd scripts/d1_coreai && <coreai-models>/.venv/bin/python export.py \
  --checkpoint ../../models/mlx/d1-2b-4bit --inputs /tmp/d1dump/inputs.json --out ../../models/coreai/d1-2b-4bit  # 8-bit: --compression 8bit, checkpoint d1-2b, CURIO_D1_ALIAS=d1-2b
# 5. Benchmark, one runtime per process (CURIO_D1_COLD=1 clears Core AI's compiled-model cache first)
for backend in mlx coreai; do
  CURIO_D1_BACKEND=$backend CURIO_D1_BENCH=<folder of square pictures> CURIO_D1_RESULT=results.jsonl \
  CURIO_D1_AIMODEL=$PWD/models/coreai/d1-2b-4bit/d1-4bit.aimodel \
  swift test -c release -Xswiftc -enable-testing --package-path macos --filter D1CoreAITests/testBenchmarkOneRuntime
done
```

GPU memory was read from the driver while each run went (`ioreg -r -c IOAccelerator`, "In use system memory"), against a baseline taken just before; footprint breakdowns with `footprint -p <pid>`.
