#!/usr/bin/env bash
# Run the sdtv Flutter app from any cwd inside the repo.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tool/bazzite-flutter-env.sh"

# Clear a forced backend left over from debugging sessions unless the user
# explicitly wants one via SDTV_GDK_BACKEND.
if [[ -n "${SDTV_GDK_BACKEND:-}" ]]; then
  export GDK_BACKEND="${SDTV_GDK_BACKEND}"
else
  unset GDK_BACKEND || true
fi

cd "${ROOT}/apps/sdtv"

# Clean stale native build if requested: SDTV_CLEAN=1 ./tool/run.sh
if [[ "${SDTV_CLEAN:-}" == "1" ]]; then
  echo "Cleaning build/linux …"
  rm -rf build/linux
fi

echo "Starting sdtv"
echo "  GDK_BACKEND=${GDK_BACKEND:-<default>}"
echo "  gamepad=${SDTV_ENABLE_GAMEPAD:-0}  (set SDTV_ENABLE_GAMEPAD=1 to enable)"
echo "  Window title: sdtv — check primary monitor / taskbar"
echo "  Keys: arrows · Enter · Esc   Pad: D-pad/stick · A · B"
echo ""

exec flutter run -d linux "$@"
