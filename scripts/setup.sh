#!/bin/bash
# Sets up the Python environment for the command-line tool (imgsearch).
# The macOS app does not need it: scripts/launch.sh builds and runs the app.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$IMGSEARCH_PROJECT_ROOT"
if ! command -v uv >/dev/null; then
  echo 'Install uv first (https://docs.astral.sh/uv/getting-started/installation/), then rerun this script.' >&2
  exit 1
fi
uv python install --managed-python --no-bin
uv sync --locked --managed-python --extra mobileclip
printf '\nEnvironment ready in %s/.venv\n' "$IMGSEARCH_PROJECT_ROOT"
