#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
bash "$CURIO_PROJECT_ROOT/scripts/build-app.sh"
open "$CURIO_PROJECT_ROOT/dist/Curio.app"
