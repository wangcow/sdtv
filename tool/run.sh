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

echo "Starting sdtv (login · demo mock · Connect = real Xtream)"
echo "  GDK_BACKEND=${GDK_BACKEND:-<default>}"
echo "  gamepad=${SDTV_ENABLE_GAMEPAD:-on}  (SDTV_ENABLE_GAMEPAD=0 to disable)"
echo "  SDTV_FORCE_MOCK=${SDTV_FORCE_MOCK:-0}  (1 = Connect uses mock catalog)"
echo "  Demo = offline fixtures · Connect = your provider"
echo "  Keys: arrows · Enter · Esc   Pad: D-pad/stick · A · B"
echo ""

exec flutter run -d linux "$@"
