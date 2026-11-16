#!/bin/bash
# Compiles MLX's Metal shaders into macos/.build/mlx.metallib.
#
#   bash scripts/build-mlx-shaders.sh
#
# The decision model runs on MLX, whose GPU code is Metal shaders. Xcode would
# compile them as part of a build; `swift build`, which this project uses,
# does not. This does that one step, so the rest of the build stays as it is.
# Needs Xcode with its Metal toolchain (xcodebuild -downloadComponent MetalToolchain).
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$CURIO_PROJECT_ROOT/macos"

output=".build/mlx.metallib"
sources=".build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
[ -d "$sources" ] || swift package resolve
if [ ! -d "$sources" ]; then
  echo "build-mlx-shaders: MLX's shaders were not found in $sources" >&2
  exit 1
fi
# Rebuilt only when the MLX version pinned in Package.resolved changes.
if [ -f "$output" ] && [ "$output" -nt Package.resolved ]; then
  exit 0
fi
if ! xcrun -sdk macosx -f metal >/dev/null 2>&1; then
  echo "build-mlx-shaders: the Metal compiler is missing. Install it with:" >&2
  echo "  xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/mlx-shaders.XXXXXX")"
trap 'rm -rf "$work"' EXIT
while IFS= read -r file; do
  name="${file#"$sources"/}"
  name="${name//\//_}"
  xcrun -sdk macosx metal -x metal -fno-fast-math -Wno-c++17-extensions -Wno-c++20-extensions \
    -mmacosx-version-min=14.0 -I "$sources" -c "$file" -o "$work/${name%.metal}.air"
done < <(find "$sources" -name '*.metal' | sort)
xcrun -sdk macosx metallib "$work"/*.air -o "$output.partial"
mv "$output.partial" "$output"
echo "build-mlx-shaders: wrote macos/$output"
