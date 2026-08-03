#!/usr/bin/env bash
# Deploy sdtv to a Steam Deck over SSH — stay in Game Mode on the Deck.
#
# One-time Deck setup (Desktop Mode once):
#   1. Enable SSH: Settings → System → "Enable Developer Mode" / SSH, or:
#        passwd          # set a password for user deck if needed
#        sudo systemctl enable --now sshd
#   2. On Bazzite, copy your key (no password prompts later):
#        ssh-copy-id deck@DECK_IP
#   3. Add Non-Steam game once: ~/sdtv/run-sdtv.sh
#      Controller: Gamepad template.
#
# Everyday (from Bazzite — Deck can stay in Game Mode):
#   ./tool/deploy-deck.sh deck@192.168.1.180
#   # then on Deck: re-launch the Non-Steam "sdtv" entry
#
# Flags:
#   --no-package   Use existing dist/sdtv-deck.tar.gz (skip rebuild)
#   --package-only Build tarball, do not upload
#   --host USER@IP Override target (default: $SDTV_DECK_HOST or first arg)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARBALL="${ROOT}/dist/sdtv-deck.tar.gz"
REMOTE_DIR='~/sdtv'
REMOTE_TAR='~/sdtv-deck.tar.gz'

DO_PACKAGE=1
DO_UPLOAD=1
HOST="${SDTV_DECK_HOST:-}"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --no-package) DO_PACKAGE=0; shift ;;
    --package-only) DO_UPLOAD=0; shift ;;
    --host) HOST="${2:-}"; shift 2 ;;
    -*)
      echo "unknown flag: $1" >&2
      usage 1
      ;;
    *)
      if [[ -z "${HOST}" ]]; then
        HOST="$1"
      else
        echo "unexpected arg: $1" >&2
        usage 1
      fi
      shift
      ;;
  esac
done

if [[ "${DO_UPLOAD}" -eq 1 && -z "${HOST}" ]]; then
  echo "error: pass deck host, e.g.  ./tool/deploy-deck.sh deck@192.168.1.180" >&2
  echo "       or:  export SDTV_DECK_HOST=deck@192.168.1.180" >&2
  exit 1
fi

if [[ "${DO_PACKAGE}" -eq 1 ]]; then
  echo "==> Packaging…"
  bash "${ROOT}/tool/package-deck.sh"
else
  if [[ ! -f "${TARBALL}" ]]; then
    echo "error: missing ${TARBALL} (run without --no-package first)" >&2
    exit 1
  fi
  echo "==> Using existing ${TARBALL}"
fi

ls -lh "${TARBALL}"

if [[ "${DO_UPLOAD}" -eq 0 ]]; then
  echo "Package only — done."
  exit 0
fi

echo "==> Upload → ${HOST}:${REMOTE_TAR}"
scp "${TARBALL}" "${HOST}:${REMOTE_TAR}"

echo "==> Extract → ${HOST}:${REMOTE_DIR}"
# shellcheck disable=SC2029
ssh "${HOST}" "set -e
  mkdir -p ${REMOTE_DIR}
  # Wipe lib only is not enough (stale wrappers); replace tree cleanly.
  # Keep parent dir so Steam Non-Steam shortcut path stays stable.
  find ${REMOTE_DIR} -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  tar -xzf ${REMOTE_TAR} -C ${REMOTE_DIR}
  chmod +x ${REMOTE_DIR}/run-sdtv.sh ${REMOTE_DIR}/sdtv
  # Smoke: critical libs present
  test -f ${REMOTE_DIR}/lib/libmpv.so.2 -o -L ${REMOTE_DIR}/lib/libmpv.so.2
  test -f ${REMOTE_DIR}/lib/libmujs.so -o -L ${REMOTE_DIR}/lib/libmujs.so
  ls -la ${REMOTE_DIR}/run-sdtv.sh ${REMOTE_DIR}/lib/libmpv* ${REMOTE_DIR}/lib/libmujs* 2>/dev/null | head -20
  echo OK: ${REMOTE_DIR} updated
"

echo ""
echo "=========================================="
echo "Deployed to ${HOST}:${REMOTE_DIR}"
echo ""
echo "On the Deck (Game Mode):"
echo "  • Close sdtv if it is still running (STEAM → Exit game)"
echo "  • Launch your Non-Steam 'sdtv' shortcut again"
echo ""
echo "Tip: export SDTV_DECK_HOST=${HOST}"
echo "     so next time:  ./tool/deploy-deck.sh --no-package   # or full rebuild"
echo "=========================================="
