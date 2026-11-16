#!/bin/bash
# Writes reference outputs for the decision model next to the installed copy
# (models/mlx/d1-2b/fixtures.json), for the Swift tests to compare against.
#
#   bash scripts/d1-reference.sh
#
# Uses mlx-vlm, the Python implementation the Swift code was written from, in a
# throwaway environment that uv creates. Downloads the checkpoint (about 2.2 GB)
# into models/huggingface/ if it is not there yet. The app never runs this.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$CURIO_PROJECT_ROOT"
alias_name="${1:-d1-2b}"
repo="${D1_REPO:-LiquidAI/d1-2B-MLX-8bit}"
mkdir -p "models/mlx/$alias_name"
uv run --no-project --python 3.12 --with "mlx-vlm==0.7.11" --with "pillow" \
  python scripts/d1_reference.py --repo "$repo" --out "models/mlx/$alias_name"
