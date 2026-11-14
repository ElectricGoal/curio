#!/bin/bash
# Verifies the app, its engine and the bundle.
#   bash scripts/check.sh          Swift tests, release build, signature, self-test;
#                                  plus the command-line tool's tests when its
#                                  Python environment is set up (scripts/setup.sh)
#   bash scripts/check.sh --e2e    also drives the app end to end with the real
#                                  default model and checks search discriminates
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$IMGSEARCH_PROJECT_ROOT"
mkdir -p .cache/clang .cache/swift
export CLANG_MODULE_CACHE_PATH="$IMGSEARCH_PROJECT_ROOT/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$IMGSEARCH_PROJECT_ROOT/.cache/swift"

# Model-accuracy tests skip themselves until scripts/convert-models.sh has run;
# the end-to-end test skips itself unless LUMA_E2E=1.
swift test --package-path macos
if [[ "${1:-}" == "--e2e" ]]; then
  LUMA_E2E=1 swift test --package-path macos --filter EndToEndTests
fi
bash scripts/build-app.sh
codesign --verify --deep --strict dist/ImageSearch.app
if ls models/coreml/*/model.json >/dev/null 2>&1; then
  dist/ImageSearch.app/Contents/MacOS/ImageSearch --self-test
else
  echo 'Skipping the app self-test: no models yet (bash scripts/convert-models.sh).'
fi

# The command-line tool is separate from the app and still Python.
if [[ -x .venv/bin/python ]]; then
  .venv/bin/python -m pytest -q
  if [[ "${1:-}" == "--e2e" ]]; then
    IMGSEARCH_REAL_MODEL=1 .venv/bin/python -m pytest -q tests/test_real_model.py
  fi
else
  echo 'Skipping the command-line tool tests: no .venv (bash scripts/setup.sh).'
fi
echo 'App, engine and bundle verified.'
