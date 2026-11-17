"""Liquid d1 (LFM3-VL, "set" attention) in plain PyTorch, for export to Core AI.

A line-for-line mirror of the app's Swift/MLX network
(macos/Sources/CurioKit/Engine/Decision/D1Network.swift), so the two runtimes
compute the same thing: vision tower -> projector -> LFM3 language model ->
yes/no scores at each question's last token.

Weights come from the MLX checkpoint the app downloads (e.g. d1-2B-MLX-4bit).
Its 4-bit affine-packed matrices are unpacked to float16 here; Core AI then
re-quantizes them with coreai-opt, so both runtimes start from the same values.

The graph is traced for one fixed geometry: a picture of `rows x columns`
patches and a prompt row of fixed length (see export.py). Everything that
depends only on that geometry (rotary angles, where the picture sits in the
row) is a constant of the graph; masks, token ids and patches are inputs.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from safetensors.numpy import load_file
from torch import Tensor, nn


# ---------------------------------------------------------------- weights


def _unpack_affine(weight: np.ndarray, scales: np.ndarray, biases: np.ndarray, bits: int, group: int) -> np.ndarray:
    """MLX affine quantization back to floats: each uint32 holds 32/bits values,
    lowest bits first, along the input dimension; value = q * scale + bias per group."""
    per_word = 32 // bits
    mask = (1 << bits) - 1
    shifts = (np.arange(per_word, dtype=np.uint32) * bits)
    q = (weight[..., None] >> shifts) & mask  # (..., words, per_word)
    q = q.reshape(*weight.shape[:-1], weight.shape[-1] * per_word).astype(np.float32)
    s = np.repeat(scales.astype(np.float32), group, axis=-1)
    b = np.repeat(biases.astype(np.float32), group, axis=-1)
    return q * s + b


def load_mlx_checkpoint(directory: Path) -> tuple[dict, dict[str, Tensor]]:
    """`config.json` and every tensor of `model.safetensors`, unpacked to float16."""
    config = json.loads((directory / "config.json").read_text())
    quant = config.get("quantization") or {}
    bits, group = quant.get("bits", 4), quant.get("group_size", 64)
    raw = load_file(str(directory / "model.safetensors"))
    tensors: dict[str, Tensor] = {}
    for name, value in raw.items():
        if name.endswith((".scales", ".biases")):
            continue
        base = name[: -len(".weight")] if name.endswith(".weight") else None
        if base is not None and f"{base}.scales" in raw:
            value = _unpack_affine(value, raw[f"{base}.scales"], raw[f"{base}.biases"], bits, group)
        tensors[name] = torch.from_numpy(np.asarray(value, dtype=np.float32)).to(torch.float16)
    return config, tensors


# ---------------------------------------------------------------- pieces

#: When set, norms and attention are Core AI composite ops (coreai_torch.composite_ops),
#: as Apple's macOS export path builds them; rotary positions stay plain ops (d1 rotates
#: part of each head, paired across halves, which the RoPE composite does not express).
COMPOSITE = False


def rms_norm(size: int, eps: float) -> nn.Module:
    if COMPOSITE:
        import coreai_torch.composite_ops as ops

        return ops.RMSNorm(size, eps=eps).half()
    return RMSNorm(size, eps)


def attend(q: Tensor, k: Tensor, v: Tensor, scale: float, mask: Tensor | None = None,
           causal_window: int | None = None) -> Tensor:
    """Attention with fewer key/value heads than query heads (B, H, L, D). `causal_window`:
    each token reads the `causal_window` tokens ending at itself (no mask needed)."""
    if COMPOSITE:
        import coreai_torch.composite_ops as ops

        sdpa = ops.SDPA(scale=scale, is_causal=causal_window is not None, window_size=causal_window or 0)
        # The composite reads a mask as booleans (True: may attend); ours arrive additive (0 or -inf).
        return sdpa(q, k, v, attn_mask=None if mask is None else mask == 0)
    repeat = q.shape[1] // k.shape[1]
    k, v = k.repeat_interleave(repeat, dim=1), v.repeat_interleave(repeat, dim=1)
    return F.scaled_dot_product_attention(q, k, v, attn_mask=mask, scale=scale)


class RMSNorm(nn.Module):
    def __init__(self, size: int, eps: float):
        super().__init__()
        self.weight = nn.Parameter(torch.ones(size, dtype=torch.float16))
        self.eps = eps

    def forward(self, x: Tensor) -> Tensor:
        # Statistics in float32, as fast RMSNorm kernels do.
        x32 = x.float()
        return (x32 * torch.rsqrt(x32.pow(2).mean(-1, keepdim=True) + self.eps)).to(x.dtype) * self.weight


def linear(i: int, o: int, bias: bool = False) -> nn.Linear:
    return nn.Linear(i, o, bias=bias, dtype=torch.float16)


class FeedForward(nn.Module):
    """w2(silu(w1 x) * w3 x)."""

    def __init__(self, size: int, hidden: int):
        super().__init__()
        self.w1, self.w3, self.w2 = linear(size, hidden), linear(size, hidden), linear(hidden, size)

    def forward(self, x: Tensor) -> Tensor:
        up = self.w3(x)
        return self.w2(F.silu(self.w1(x)) * up)


def rotate(x: Tensor, cos: Tensor, sin: Tensor) -> Tensor:
    a, b = x.chunk(2, dim=-1)
    return x * cos + torch.cat([-b, a], dim=-1) * sin


# ---------------------------------------------------------------- vision


class VisionAttention(nn.Module):
    def __init__(self, cfg: dict):
        super().__init__()
        d, h, kv = cfg["hidden_size"], cfg["num_attention_heads"], cfg["num_key_value_heads"]
        self.heads, self.kv, self.size = h, kv, d // h
        self.q_proj, self.k_proj = linear(d, h * self.size), linear(d, kv * self.size)
        self.v_proj, self.out_proj = linear(d, kv * self.size), linear(h * self.size, d)
        self.q_layernorm, self.k_layernorm = rms_norm(self.size, cfg["norm_eps"]), rms_norm(self.size, cfg["norm_eps"])

    def forward(self, x: Tensor, cos: Tensor, sin: Tensor) -> Tensor:
        n = x.shape[0]
        q = self.q_layernorm(self.q_proj(x).view(n, self.heads, self.size))
        k = self.k_layernorm(self.k_proj(x).view(n, self.kv, self.size))
        v = self.v_proj(x).view(n, self.kv, self.size)
        q = rotate(q.float(), cos, sin).to(x.dtype).transpose(0, 1)[None]
        k = rotate(k.float(), cos, sin).to(x.dtype).transpose(0, 1)[None]
        v = v.transpose(0, 1)[None]
        out = attend(q, k, v, scale=1 / math.sqrt(self.size))
        return self.out_proj(out[0].transpose(0, 1).reshape(n, -1))


class VisionConvolution(nn.Module):
    """A gated depthwise 3x3 convolution over the patch grid (patches arrive in block order)."""

    def __init__(self, cfg: dict):
        super().__init__()
        d = cfg["hidden_size"]
        self.in_proj, self.out_proj = linear(d, 3 * d), linear(d, d)
        self.kernel = cfg["conv_kernel_size"]
        self.spatial_conv = nn.Conv2d(d, d, self.kernel, padding=self.kernel // 2, groups=d, bias=False,
                                      dtype=torch.float16)
        self.merge = cfg["spatial_merge_size"]

    def forward(self, x: Tensor, rows: int, columns: int) -> Tensor:
        b, c, g = self.in_proj(x).chunk(3, dim=-1)
        m = self.merge
        grid = (b * g).reshape(rows // m, columns // m, m, m, -1).permute(0, 2, 1, 3, 4)
        grid = grid.reshape(1, rows, columns, -1).permute(0, 3, 1, 2)  # NCHW
        conv = self.spatial_conv(grid).permute(0, 2, 3, 1)  # back to NHWC
        back = conv.reshape(rows // m, m, columns // m, m, -1).permute(0, 2, 1, 3, 4).reshape(rows * columns, -1)
        return self.out_proj(c * back)


class VisionLayer(nn.Module):
    def __init__(self, cfg: dict, kind: str):
        super().__init__()
        d, eps = cfg["hidden_size"], cfg["norm_eps"]
        self.kind = kind
        self.operator_norm, self.ffn_norm = rms_norm(d, eps), rms_norm(d, eps)
        if kind == "conv":
            self.conv = VisionConvolution(cfg)
        else:
            self.self_attn = VisionAttention(cfg)
        self.feed_forward = FeedForward(d, cfg["intermediate_size"])


class VisionTower(nn.Module):
    def __init__(self, cfg: dict):
        super().__init__()
        d = cfg["hidden_size"]
        patch_in = cfg.get("temporal_patch_size", 1) * cfg["in_channels"] * cfg["patch_size"] ** 2
        self.patchifier = linear(patch_in, d)  # no bias in the checkpoint
        self.embedding_norm = rms_norm(d, cfg["norm_eps"])
        self.layers = nn.ModuleList(VisionLayer(cfg, kind) for kind in cfg["layer_types"])

    def forward(self, patches: Tensor, rows: int, columns: int, cos: Tensor, sin: Tensor) -> Tensor:
        x = self.embedding_norm(self.patchifier(patches))
        for layer in self.layers:
            h = layer.operator_norm(x)
            x = x + (layer.conv(h, rows, columns) if layer.kind == "conv" else layer.self_attn(h, cos, sin))
            x = x + layer.feed_forward(layer.ffn_norm(x))
        return x


def vision_angles(cfg: dict, rows: int, columns: int) -> tuple[Tensor, Tensor]:
    """Rotation angles per patch from its row and column, in block order (as gridAngles in Swift)."""
    merge, size = cfg["spatial_merge_size"], cfg["hidden_size"] // cfg["num_attention_heads"]
    spatial = size // 2
    theta = cfg["rope_parameters"]["rope_theta"]
    freqs = np.array([theta ** (-i / spatial) for i in range(0, spatial, 2)], dtype=np.float32)
    angles = []
    for br in range(rows // merge):
        for bc in range(columns // merge):
            for ir in range(merge):
                for ic in range(merge):
                    r, c = br * merge + ir, bc * merge + ic
                    own = np.concatenate([r * freqs, c * freqs])
                    angles.append(np.concatenate([own, own]))
    a = torch.tensor(np.array(angles, dtype=np.float32)).view(rows * columns, 1, 2 * spatial)
    return torch.cos(a), torch.sin(a)


class Projector(nn.Module):
    def __init__(self, cfg: dict, vision: dict, text: dict):
        super().__init__()
        merged = vision["hidden_size"] * vision["spatial_merge_size"] ** 2
        self.layer_norm = nn.LayerNorm(vision["hidden_size"], eps=cfg["projector_layer_norm_eps"], dtype=torch.float16)
        self.linear_1 = linear(merged, cfg["projector_hidden_size"], bias=cfg.get("projector_bias", True))
        self.linear_2 = linear(cfg["projector_hidden_size"], text["hidden_size"], bias=cfg.get("projector_bias", True))
        self.merged = merged

    def forward(self, x: Tensor) -> Tensor:
        blocks = self.layer_norm(x).reshape(-1, self.merged)
        h = self.linear_1(blocks)
        return self.linear_2(h * (1 + torch.erf(h / math.sqrt(2))) / 2)


# ---------------------------------------------------------------- language


class ShortConvolution(nn.Module):
    def __init__(self, cfg: dict):
        super().__init__()
        d, self.width = cfg["hidden_size"], cfg["conv_L_cache"]
        self.in_proj, self.out_proj = linear(d, 3 * d), linear(d, d)
        self.conv = nn.Conv1d(d, d, self.width, groups=d, bias=False, dtype=torch.float16)

    def forward(self, x: Tensor) -> Tensor:  # x: (1, L, D)
        b, c, g = self.in_proj(x).chunk(3, dim=-1)
        gated = F.pad((b * g).transpose(1, 2), (self.width - 1, 0))  # causal: past tokens only
        return self.out_proj(c * self.conv(gated).transpose(1, 2))


class TextAttention(nn.Module):
    def __init__(self, cfg: dict):
        super().__init__()
        d, h, kv, size = cfg["hidden_size"], cfg["num_attention_heads"], cfg["num_key_value_heads"], cfg["head_dim"]
        self.heads, self.kv, self.size = h, kv, size
        self.q_proj, self.k_proj, self.v_proj = linear(d, h * size), linear(d, kv * size), linear(d, kv * size)
        self.gate_proj, self.o_proj = linear(d, h), linear(h * size, d)
        self.q_norm, self.k_norm = rms_norm(size, cfg["norm_eps"]), rms_norm(size, cfg["norm_eps"])

    def forward(self, x: Tensor, cos: Tensor, sin: Tensor, mask: Tensor | None,
                window: int | None = None) -> Tensor:
        n = x.shape[1]
        q = self.q_norm(self.q_proj(x).view(1, n, self.heads, self.size)).transpose(1, 2)
        k = self.k_norm(self.k_proj(x).view(1, n, self.kv, self.size)).transpose(1, 2)
        v = self.v_proj(x).view(1, n, self.kv, self.size).transpose(1, 2)
        q, k = rotate(q, cos, sin), rotate(k, cos, sin)
        out = attend(q, k, v, scale=1 / math.sqrt(self.size), mask=mask, causal_window=window)
        gate = torch.sigmoid(self.gate_proj(x)).transpose(1, 2)[..., None]  # (1, H, L, 1)
        return self.o_proj((out * gate).transpose(1, 2).reshape(1, n, -1))


class TextLayer(nn.Module):
    def __init__(self, cfg: dict, kind: str):
        super().__init__()
        d, eps = cfg["hidden_size"], cfg["norm_eps"]
        self.kind = kind
        self.operator_norm, self.ffn_norm = rms_norm(d, eps), rms_norm(d, eps)
        self.sandwich = cfg.get("use_sandwich_norm", False)
        if self.sandwich:
            self.post_operator_norm, self.post_ffn_norm = rms_norm(d, eps), rms_norm(d, eps)
        if kind == "conv":
            self.conv = ShortConvolution(cfg)
        else:
            self.self_attn = TextAttention(cfg)
        self.feed_forward = FeedForward(d, cfg["intermediate_size"])


def text_angles(cfg: dict, kind: str, length: int) -> tuple[Tensor, Tensor]:
    """Rotation per position for one attention kind; only `partial_rotary_factor` of each head turns."""
    size = cfg["head_dim"]
    rope = cfg["rope_parameters"][kind]
    turning = int(size * (rope.get("partial_rotary_factor") or 1)) // 2
    freqs = np.array([rope["rope_theta"] ** (-i * 2 / size) if i < turning else 0 for i in range(size // 2)],
                     dtype=np.float32)
    half = np.arange(length, dtype=np.float32)[:, None] * freqs
    a = torch.tensor(np.concatenate([half, half], axis=-1))
    return torch.cos(a).to(torch.float16), torch.sin(a).to(torch.float16)


class LanguageModel(nn.Module):
    def __init__(self, cfg: dict):
        super().__init__()
        d = cfg["hidden_size"]
        self.embed_tokens = nn.Embedding(cfg["vocab_size"], d, dtype=torch.float16)
        self.layers = nn.ModuleList(TextLayer(cfg, kind) for kind in cfg["layer_types"])
        self.embedding_norm = rms_norm(d, cfg["norm_eps"])


# ---------------------------------------------------------------- whole


class D1(nn.Module):
    """Patches + one packed prompt row -> scores of the yes/no tokens at each question's slot.

    Inputs (fixed shapes for one geometry):
      patches      (P, patch_in) float16, P = rows * columns, in block order
      ids          (L,) int32, with the image token wherever a piece of the picture goes
      full_mask    (1, 1, L, L) float16 additive: 0 where a token may read, -inf elsewhere
      sliding_mask (1, 1, L, L) float16 additive
      slots        (S,) int32: the last token of each question
      tokens       (K,) int32: the answer tokens to score (yes tokens then no tokens)
    Output: scores (S, K) float32.
    """

    def __init__(self, config: dict, rows: int, columns: int, image_start: int, length: int):
        super().__init__()
        self.vision_cfg, self.text_cfg = config["vision_config"], config["text_config"]
        self.vision_tower = VisionTower(self.vision_cfg)
        self.multi_modal_projector = Projector(config, self.vision_cfg, self.text_cfg)
        self.language_model = nn.Module()
        self.language_model.model = LanguageModel(self.text_cfg)
        self.rows, self.columns, self.image_start, self.length = rows, columns, image_start, length
        cos, sin = vision_angles(self.vision_cfg, rows, columns)
        self.register_buffer("vision_cos", cos, persistent=False)
        self.register_buffer("vision_sin", sin, persistent=False)
        for kind in ("full_attention", "sliding_attention"):
            if kind in self.text_cfg["rope_parameters"]:
                c, s = text_angles(self.text_cfg, kind, length)
                self.register_buffer(f"{kind}_cos", c, persistent=False)
                self.register_buffer(f"{kind}_sin", s, persistent=False)

    def load_mlx(self, tensors: dict[str, Tensor]) -> None:
        state = {}
        for name, value in tensors.items():
            if name.endswith("spatial_conv.weight"):  # MLX (O, kH, kW, I) -> PyTorch (O, I, kH, kW)
                value = value.permute(0, 3, 1, 2)
            elif name.endswith(".conv.conv.weight"):  # MLX (O, k, I) -> PyTorch (O, I, k)
                value = value.permute(0, 2, 1)
            state[name] = value.contiguous()
        missing, unexpected = self.load_state_dict(state, strict=False)
        missing = [m for m in missing if not m.endswith(("_cos", "_sin"))]
        if missing or unexpected:
            raise ValueError(f"weights do not match: missing {missing[:5]}, unexpected {unexpected[:5]}")

    def forward(self, patches: Tensor, ids: Tensor, full_mask: Tensor, sliding_mask: Tensor | None, slots: Tensor,
                tokens: Tensor) -> Tensor:
        vision = self.vision_tower(patches, self.rows, self.columns, self.vision_cos, self.vision_sin)
        features = self.multi_modal_projector(vision)
        lm = self.language_model.model
        start, count = self.image_start, features.shape[0]
        embeds = lm.embed_tokens(ids)
        h = torch.cat([embeds[:start], features.to(embeds.dtype), embeds[start + count:]], dim=0)[None]
        for layer in lm.layers:
            o = layer.operator_norm(h)
            if layer.kind == "conv":
                o = layer.conv(o)
            else:
                cos, sin = getattr(self, f"{layer.kind}_cos"), getattr(self, f"{layer.kind}_sin")
                if layer.kind == "full_attention":
                    o = layer.self_attn(o, cos, sin, full_mask)
                elif COMPOSITE:  # the composite builds the causal window itself
                    o = layer.self_attn(o, cos, sin, None, window=self.text_cfg["sliding_window"])
                else:
                    o = layer.self_attn(o, cos, sin, sliding_mask)
            if layer.sandwich:
                o = layer.post_operator_norm(o)
            h = h + o
            f = layer.feed_forward(layer.ffn_norm(h))
            if layer.sandwich:
                f = layer.post_ffn_norm(f)
            h = h + f
        h = lm.embedding_norm(h)[0]
        rows = h[slots]
        table = lm.embed_tokens(tokens)  # the head is the embedding table (tied)
        return (rows @ table.T).float()
