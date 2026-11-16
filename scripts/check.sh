#!/bin/bash
# Verifies the app, its engine and the bundle.
#   bash scripts/check.sh          Swift tests, release build, signature, self-test
#   bash scripts/check.sh --e2e    also drives the app end to end with the real
#                                  default model and checks search discriminates
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$CURIO_PROJECT_ROOT"
mkdir -p .cache/clang .cache/swift
export CLANG_MODULE_CACHE_PATH="$CURIO_PROJECT_ROOT/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CURIO_PROJECT_ROOT/.cache/swift"

# Model-accuracy tests skip themselves until scripts/convert-models.sh has run
# (and, for the decision model, until it is installed and scripts/d1-reference.sh
# has run); the end-to-end tests skip themselves unless CURIO_E2E=1.
bash scripts/build-mlx-shaders.sh
swift test --package-path macos
if [[ "${1:-}" == "--e2e" ]]; then
  CURIO_E2E=1 swift test --package-path macos --filter EndToEndTests
fi
bash scripts/build-app.sh
codesign --verify --deep --strict dist/Curio.app
if ls models/coreml/*/model.json >/dev/null 2>&1; then
  dist/Curio.app/Contents/MacOS/Curio --self-test
else
  echo 'Skipping the app self-test: no models yet (bash scripts/convert-models.sh).'
fi
echo 'App, engine and bundle verified.'
