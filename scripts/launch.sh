#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/env.sh"
bash "$IMGSEARCH_PROJECT_ROOT/scripts/build-app.sh"
open "$IMGSEARCH_PROJECT_ROOT/dist/ImageSearch.app"
