#!/bin/bash
# Converts the app's models from PyTorch to Core ML into models/coreml/.
#
#   bash scripts/convert-models.sh                 # every model
#   bash scripts/convert-models.sh clip-vit-b32    # just one
#
# This is the only step that uses Python, and only on the machine that builds
# the app: the conversion tools run in a throwaway environment that uv creates,
# separate from the project's own. Source weights are downloaded from Hugging
# Face on first use (about 1.8 GB for MobileCLIP-S4, 600 MB for CLIP ViT-B/32).
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$IMGSEARCH_PROJECT_ROOT"
# Versions known to work together: coremltools 9.0 is tested against torch 2.7.
uv run --no-project --python 3.11 \
  --with "coremltools==9.0" --with "torch==2.7.0" --with "torchvision==0.22.0" \
  --with "open_clip_torch>=4.2,<5" --with "transformers>=4.50,<5" --with "timm>=1.0.20" \
  --with "numpy<2.3" \
  python scripts/convert_models.py --hub models/huggingface/hub --out models/coreml "$@"
