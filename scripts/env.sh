#!/bin/bash
# Source this file to keep caches, and what model conversion downloads, in this checkout.
# Works when sourced from bash or zsh. (Without the zsh branch the root resolved
# to the parent of the current directory, scattering caches and models there.)
if [ -n "${BASH_SOURCE:-}" ]; then
  _imgsearch_env="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  eval '_imgsearch_env="${(%):-%x}"'
else
  echo "scripts/env.sh: source this file from bash or zsh" >&2
  return 1 2>/dev/null || exit 1
fi
IMGSEARCH_PROJECT_ROOT="$(cd "$(dirname "$_imgsearch_env")/.." && pwd)"
unset _imgsearch_env
if [ ! -f "$IMGSEARCH_PROJECT_ROOT/macos/Package.swift" ]; then
  echo "scripts/env.sh: could not locate the project (got $IMGSEARCH_PROJECT_ROOT)" >&2
  return 1 2>/dev/null || exit 1
fi
export IMGSEARCH_PROJECT_ROOT
export UV_CACHE_DIR="$IMGSEARCH_PROJECT_ROOT/.cache/uv"
export UV_PYTHON_INSTALL_DIR="$IMGSEARCH_PROJECT_ROOT/.runtime/python"
export HF_HOME="$IMGSEARCH_PROJECT_ROOT/models/huggingface"
export HF_HUB_CACHE="$HF_HOME/hub"
export HUGGINGFACE_HUB_CACHE="$HF_HOME/hub"
export TORCH_HOME="$IMGSEARCH_PROJECT_ROOT/models/torch"
export XDG_CACHE_HOME="$IMGSEARCH_PROJECT_ROOT/.cache"
export PYTHONPYCACHEPREFIX="$IMGSEARCH_PROJECT_ROOT/.cache/pycache"
export MPLCONFIGDIR="$IMGSEARCH_PROJECT_ROOT/.cache/matplotlib"
export TMPDIR="$IMGSEARCH_PROJECT_ROOT/.runtime/tmp"
mkdir -p "$TMPDIR"
