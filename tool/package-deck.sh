#!/usr/bin/env bash
# Build a Deck-friendly Linux release of the Flutter guide.
#
# Video plays in the Deck's own external mpv (system or Flatpak), launched with
# a system-only LD_LIBRARY_PATH, so no mpv / codec libraries are bundled.
#
# Do NOT ship brew GTK / X11 / xkbcommon / mesa / fontconfig — those pull
# Homebrew *data* paths (/home/linuxbrew/.../share/X11/xkb) and crash on Deck
# with "Failed to create XKB keymap". Use the Deck's system UI stack.
#
# Homebrew sometimes embeds absolute DT_NEEDED (e.g. mujs Cellar). Rewrite
# those to basenames and ensure soname symlinks exist in bundle/lib.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Same Homebrew build env the Deck package has always used.
# ./tool/run.sh must not set this.
export SDTV_BREW_DEPS=1
# shellcheck disable=SC1091
source "${ROOT}/tool/bazzite-flutter-env.sh"

if ! command -v brew >/dev/null 2>&1; then
  echo "error: Homebrew not found" >&2
  exit 1
fi

if ! command -v patchelf >/dev/null 2>&1; then
  echo "Installing patchelf (for RPATH / NEEDED rewrite)…"
  brew install patchelf
fi

# Visible on the guide UI so Deck deploys are easy to verify.
SDTV_BUILD="$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo nogit)"
SDTV_BUILD="${SDTV_BUILD}-$(date -u +%Y%m%d-%H%M)"
export SDTV_BUILD
echo "Building release… (SDTV_BUILD=${SDTV_BUILD})"
cd "${ROOT}/apps/sdtv"
flutter build linux --release --dart-define="SDTV_BUILD=${SDTV_BUILD}"

BUNDLE="${ROOT}/apps/sdtv/build/linux/x64/release/bundle"
LIBDIR="${BUNDLE}/lib"
if [[ ! -d "${LIBDIR}" ]]; then
  echo "error: missing ${LIBDIR}" >&2
  exit 1
fi

# Remove previously staged brew UI/graphics libs so a re-package is clean.
# Keep the Flutter engine .so and libapp.so.
echo "Pruning stale brew UI/graphics libs from bundle/lib (if any)…"
(
  cd "${LIBDIR}"
  # shellcheck disable=SC2086
  rm -f \
    libgtk* libgdk* libglib* libgobject* libgio* libgmodule* \
    libpango* libcairo* libharfbuzz* libfontconfig* libfreetype* \
    libepoxy* libatk* libatspi* libdbus* libfribidi* libthai* libdatrie* \
    libxkbcommon* libX11* libXext* libXrandr* libXi* libXfixes* libXdamage* \
    libXinerama* libXrender* libXau* libXdmcp* \
    libxcb* libwayland* libEGL* libGL* libgbm* libgallium* libdrm* \
    libvulkan* libLLVM* libSPIRV* libsensors* libz3* libpciaccess* \
    libpulse* libpulsecommon* libpipewire* libasound* \
    libffi* libpcre* libmount* libblkid* libexpat* libpng* \
    libedit* libncurses* libelf* libgraphite* 2>/dev/null || true
)

is_brew_lib() {
  case "$1" in
    /home/linuxbrew/*|/home/*/linuxbrew/*|/var/home/*/linuxbrew/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Libraries that must come from the Deck/host (UI, input, GPU, session audio).
# Matching is on the real basename (after readlink).
is_host_only_lib() {
  local base="$1"
  case "${base}" in
    # GTK / GLib stack (Flutter uses system GTK)
    libgtk-*|libgdk-*|libgdk_pixbuf-*|libglib-*|libgobject-*|libgio-*|libgmodule-*|\
    libpango-*|libpangocairo-*|libpangoft2-*|libcairo*|libharfbuzz*|\
    libfontconfig*|libfreetype*|libepoxy*|libatk-*|libatspi*|libdbus-*|\
    libfribidi*|libthai*|libdatrie*|libgraphite*)
      return 0 ;;
    # X11 / Wayland / xkb — need *system* share/X11/xkb data.
    # Exception: libXpresent is a tiny X extension often missing on Deck; allow
    # bundling it (no data files). Same for libXv / libXss if pulled by mpv only.
    libxkbcommon*|libX11*|libXext*|libXrandr*|libXi*|libXfixes*|libXdamage*|\
    libXinerama*|libXrender*|libXau*|libXdmcp*|libxcb*|libwayland*)
      return 0 ;;
    # GPU / mesa / vulkan — never ship brew mesa to Deck
    libEGL*|libGL*|libgbm*|libgallium*|libdrm*|libvulkan*|libLLVM*|libSPIRV*|\
    libsensors*|libz3*|libpciaccess*)
      return 0 ;;
    # Session audio servers (Deck PipeWire/Pulse)
    libpulse*|libpipewire*|libasound*)
      return 0 ;;
    # Generic system libs — prefer host. Do NOT host-only libbz2: brew archive
    # often needs libbz2.so.1.0 which SteamOS may not provide under that soname.
    libffi*|libpcre*|libmount*|libblkid*|libexpat*|libpng*|\
    libedit*|libncurses*|libelf*|libz.so*|libz-*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# Collect absolute paths of brew .so files needed by a binary/library.
collect_brew_deps() {
  local bin="$1"
  local brew_lib
  brew_lib="$(brew --prefix)/lib"
  LD_LIBRARY_PATH="${brew_lib}:${LD_LIBRARY_PATH:-}" ldd "${bin}" 2>/dev/null | while read -r line; do
    local path=""
    if [[ "${line}" =~ =\>\ not\ found ]]; then
      echo "warning: not found: ${line}" >&2
      continue
    fi
    if [[ "${line}" =~ =\>\ (/[^ ]+) ]]; then
      path="${BASH_REMATCH[1]}"
    elif [[ "${line}" =~ ^[[:space:]]*(/home/[^ ]+\.so[^ ]*) ]]; then
      path="${BASH_REMATCH[1]}"
    fi
    [[ -z "${path}" ]] && continue
    if is_brew_lib "${path}" && [[ -e "${path}" ]]; then
      local base
      base="$(basename "$(readlink -f "${path}")")"
      if is_host_only_lib "${base}" || is_host_only_lib "$(basename "${path}")"; then
        continue
      fi
      echo "${path}"
    fi
  done
}

ensure_soname_links() {
  local dest="$1"
  local base
  base="$(basename "${dest}")"
  [[ -f "${dest}" && ! -L "${dest}" ]] || return 0

  local soname=""
  soname="$(patchelf --print-soname "${dest}" 2>/dev/null || true)"
  if [[ -n "${soname}" && "${soname}" != "${base}" ]]; then
    ln -sfn "${base}" "${LIBDIR}/${soname}"
  fi

  if [[ "${base}" =~ ^(lib.+\.so)(\.[0-9]+)(\.[0-9]+.*)?$ ]]; then
    local major="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    local bare="${BASH_REMATCH[1]}"
    [[ -e "${LIBDIR}/${major}" ]] || ln -sfn "${base}" "${LIBDIR}/${major}"
    [[ -e "${LIBDIR}/${bare}" ]] || ln -sfn "${major}" "${LIBDIR}/${bare}"
  fi
}

copy_one() {
  local src="$1"
  local real base dest
  real="$(readlink -f "${src}")"
  [[ -f "${real}" ]] || return 0
  base="$(basename "${real}")"

  if is_host_only_lib "${base}" || is_host_only_lib "$(basename "${src}")"; then
    echo "  skip (host): ${base}"
    return 0
  fi

  dest="${LIBDIR}/${base}"

  if [[ ! -e "${dest}" ]]; then
    cp -L "${real}" "${dest}"
    chmod u+w "${dest}" 2>/dev/null || true
    echo "  + ${base}"
  fi

  ensure_soname_links "${dest}"

  local src_base
  src_base="$(basename "${src}")"
  if [[ "${src_base}" != "${base}" && ! -e "${LIBDIR}/${src_base}" ]]; then
    ln -sfn "${base}" "${LIBDIR}/${src_base}"
  fi
}

rewrite_absolute_needed() {
  local elf="$1"
  [[ -f "${elf}" && ! -L "${elf}" ]] || return 0
  local need
  while IFS= read -r need; do
    [[ -z "${need}" ]] && continue
    if [[ "${need}" == /* ]]; then
      local short
      short="$(basename "${need}")"
      echo "  rewrite NEEDED: $(basename "${elf}"): ${need} -> ${short}"
      patchelf --replace-needed "${need}" "${short}" "${elf}"
      if [[ ! -e "${LIBDIR}/${short}" && -e "${need}" ]]; then
        copy_one "${need}"
      fi
    fi
  done < <(patchelf --print-needed "${elf}" 2>/dev/null || true)
}

# Tracks libraries already copied by the dependency pass below.
declare -A SEEN=()

echo "Rewriting absolute DT_NEEDED paths → basenames…"
for so in "${LIBDIR}"/*.so "${LIBDIR}"/*.so.*; do
  [[ -f "${so}" && ! -L "${so}" ]] || continue
  rewrite_absolute_needed "${so}"
done
if [[ -f "${BUNDLE}/sdtv" ]]; then
  rewrite_absolute_needed "${BUNDLE}/sdtv"
fi

for so in "${LIBDIR}"/*.so "${LIBDIR}"/*.so.*; do
  [[ -f "${so}" && ! -L "${so}" ]] || continue
  while read -r dep; do
    if [[ -n "${dep}" ]]; then
      real="$(readlink -f "${dep}")"
      if [[ -z "${SEEN[$real]:-}" ]]; then
        SEEN[$real]=1
        copy_one "${dep}"
      fi
    fi
  done < <(collect_brew_deps "${so}")
done

for so in "${LIBDIR}"/*.so "${LIBDIR}"/*.so.*; do
  [[ -f "${so}" && ! -L "${so}" ]] || continue
  ensure_soname_links "${so}"
done

# Never ship brew libva*. The Deck's system libva + radeonsi does hw decode.
echo "Removing bundled libva (force system VA-API stack)…"
(
  cd "${LIBDIR}"
  rm -f libva.so libva.so.* libva-*.so libva-*.so.* 2>/dev/null || true
)

# RUNPATH: system first (GTK/drm/mesa), then $ORIGIN for anything bundled.
SYS_RPATH='/usr/lib64:/usr/lib'
echo "Setting RUNPATH=${SYS_RPATH}:\$ORIGIN on bundled libs / binary…"
for so in "${LIBDIR}"/*.so "${LIBDIR}"/*.so.*; do
  [[ -f "${so}" && ! -L "${so}" ]] || continue
  patchelf --set-rpath "${SYS_RPATH}:\$ORIGIN" "${so}" 2>/dev/null || true
done
if [[ -f "${BUNDLE}/sdtv" ]]; then
  patchelf --set-rpath "${SYS_RPATH}:\$ORIGIN/lib" "${BUNDLE}/sdtv" 2>/dev/null || true
fi

# Wrapper: system libs first, *system* XKB/fontconfig data paths.
# Never leave LD_LIBRARY_PATH empty of system fallbacks for dlopen of GPU drivers.
cat > "${BUNDLE}/run-sdtv.sh" <<'EOF'
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Library search ---
# System first (GTK/drm/mesa), then the bundle.
export LD_LIBRARY_PATH="/usr/lib64:/usr/lib:${DIR}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Critical: system VAAPI drivers (Steam Deck AMD = radeonsi). sdtv passes these
# to a *system* mpv. A Flatpak mpv gets neither: its sandbox has its own /usr
# and drivers, and these host paths would break VA-API there.
if [ -d /usr/lib64/dri ]; then
  export LIBVA_DRIVERS_PATH="/usr/lib64/dri${LIBVA_DRIVERS_PATH:+:$LIBVA_DRIVERS_PATH}"
elif [ -d /usr/lib/dri ]; then
  export LIBVA_DRIVERS_PATH="/usr/lib/dri${LIBVA_DRIVERS_PATH:+:$LIBVA_DRIVERS_PATH}"
fi
if [ -z "${LIBVA_DRIVER_NAME:-}" ]; then
  if [ -e /usr/lib64/dri/radeonsi_drv_video.so ] || [ -e /usr/lib/dri/radeonsi_drv_video.so ]; then
    export LIBVA_DRIVER_NAME=radeonsi
  fi
fi

# Stream start diagnostics (health checks + mpv log, URLs reduced to host).
export SDTV_PLAY_LOG="${SDTV_PLAY_LOG:-${DIR}/.sdtv-play.log}"

# Fontconfig / XKB = Deck OS
if [ -d /usr/share/X11/xkb ]; then
  export XKB_CONFIG_ROOT=/usr/share/X11/xkb
fi
if [ -f /etc/fonts/fonts.conf ]; then
  export FONTCONFIG_FILE=/etc/fonts/fonts.conf
fi
if [ -d /usr/share/glib-2.0/schemas ]; then
  export GSETTINGS_SCHEMA_DIR=/usr/share/glib-2.0/schemas
fi

# Optional overrides (you create this file):
#   SDTV_FORCE_MOCK=1
#   SDTV_MPV_PATH=/usr/bin/mpv
#   SDTV_MPV_PATH=flatpak:io.mpv.Mpv
if [ -f "${DIR}/sdtv.env" ]; then
  # shellcheck disable=SC1091
  set -a
  . "${DIR}/sdtv.env"
  set +a
fi

# Phase A: resolve external mpv for channel handoff (Discover = Flatpak).
# Steam Game Mode often has a short PATH; pin an absolute path / flatpak id.
if [ -z "${SDTV_MPV_PATH:-}" ]; then
  for c in \
    /usr/bin/mpv \
    /usr/local/bin/mpv \
    /bin/mpv \
    "${HOME}/.local/bin/mpv" \
    /var/lib/flatpak/exports/bin/io.mpv.Mpv \
    "${HOME}/.local/share/flatpak/exports/bin/io.mpv.Mpv" \
    /var/lib/flatpak/exports/bin/org.mpv.Mpv \
    "${HOME}/.local/share/flatpak/exports/bin/org.mpv.Mpv"
  do
    if [ -e "$c" ]; then
      case "$c" in
        *io.mpv.Mpv) export SDTV_MPV_PATH=flatpak:io.mpv.Mpv ;;
        *org.mpv.Mpv) export SDTV_MPV_PATH=flatpak:org.mpv.Mpv ;;
        *) export SDTV_MPV_PATH="$c" ;;
      esac
      break
    fi
  done
fi
if [ -z "${SDTV_MPV_PATH:-}" ] && command -v mpv >/dev/null 2>&1; then
  export SDTV_MPV_PATH="$(command -v mpv)"
fi
if [ -z "${SDTV_MPV_PATH:-}" ] && command -v flatpak >/dev/null 2>&1; then
  if flatpak info io.mpv.Mpv >/dev/null 2>&1; then
    export SDTV_MPV_PATH=flatpak:io.mpv.Mpv
  elif flatpak info org.mpv.Mpv >/dev/null 2>&1; then
    export SDTV_MPV_PATH=flatpak:org.mpv.Mpv
  fi
fi

# Tiny debug breadcrumb (safe to ignore / share when debugging decode)
{
  echo "SDTV_MPV_PATH=${SDTV_MPV_PATH:-not found}"
  echo "LIBVA_DRIVER_NAME=${LIBVA_DRIVER_NAME:-}"
  echo "LIBVA_DRIVERS_PATH=${LIBVA_DRIVERS_PATH:-}"
  echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
  echo "--- external mpv probes ---"
  ls -la /usr/bin/mpv /usr/local/bin/mpv \
    /var/lib/flatpak/exports/bin/io.mpv.Mpv \
    "${HOME}/.local/share/flatpak/exports/bin/io.mpv.Mpv" 2>/dev/null || true
  command -v mpv 2>/dev/null || echo "command -v mpv: none"
  command -v flatpak >/dev/null 2>&1 && flatpak info io.mpv.Mpv 2>&1 | head -5 || true
  echo "--- libva (should prefer system) ---"
  ls -la /usr/lib64/libva.so* /usr/lib/libva.so* 2>/dev/null || true
  ls -la "${DIR}/lib"/libva.so* 2>/dev/null || echo "bundled libva removed (good)"
  echo "--- radeonsi ---"
  ls -la /usr/lib64/dri/radeonsi_drv_video.so /usr/lib/dri/radeonsi_drv_video.so 2>/dev/null || echo "no radeonsi vaapi"
  if command -v vainfo >/dev/null 2>&1; then
    echo "--- vainfo ---"
    vainfo 2>&1 | head -40
  fi
} > "${DIR}/.sdtv-runtime.txt" 2>/dev/null || true

exec "${DIR}/sdtv" "$@"
EOF
chmod +x "${BUNDLE}/run-sdtv.sh" "${BUNDLE}/sdtv"
# App icon, e.g. for the Steam shortcut (Properties → icon).
install -m644 "${ROOT}/branding/org.wangcow.SDTV-256.png" "${BUNDLE}/sdtv.png"

echo "Making bundle user-writable (for re-deploy)…"
chmod -R u+rwX "${BUNDLE}"
find "${BUNDLE}" -type f \( -name '*.so' -o -name '*.so.*' -o -name 'sdtv' -o -name 'run-sdtv.sh' \) \
  -exec chmod u+rwx {} +

echo ""
echo "=== bundle/lib ==="
ls -1 "${LIBDIR}"

echo ""
echo "=== must NOT be bundled (host UI/GPU) ==="
bad=0
for pat in libgtk libxkbcommon libfontconfig libgallium libLLVM libEGL; do
  if ls "${LIBDIR}"/${pat}* >/dev/null 2>&1; then
    echo "UNEXPECTED: ${pat}* still in bundle:"
    ls "${LIBDIR}"/${pat}* 2>/dev/null || true
    bad=1
  fi
done
if [[ "${bad}" -eq 0 ]]; then
  echo "OK: no brew GTK/xkb/fontconfig/mesa in bundle"
fi

echo ""
echo "=== absolute NEEDED remaining? ==="
abs_left=0
for so in "${LIBDIR}"/*.so "${LIBDIR}"/*.so.* "${BUNDLE}/sdtv"; do
  [[ -f "${so}" && ! -L "${so}" ]] || continue
  while IFS= read -r n; do
    if [[ "${n}" == /* ]]; then
      echo "ABSOLUTE in $(basename "${so}"): ${n}"
      abs_left=1
    fi
  done < <(patchelf --print-needed "${so}" 2>/dev/null || true)
done
if [[ "${abs_left}" -eq 0 ]]; then
  echo "OK: no absolute DT_NEEDED paths"
fi

DIST="${ROOT}/dist"
mkdir -p "${DIST}"
TARBALL="${DIST}/sdtv-deck.tar.gz"
echo ""
echo "Creating ${TARBALL} …"
tar -C "${BUNDLE}" -czf "${TARBALL}" .
ls -lh "${TARBALL}"

echo ""
echo "=========================================="
echo "Bundle ready: ${BUNDLE}"
echo "Tarball:      ${TARBALL}"
echo ""
echo "On Deck — wipe old install, then:"
echo "  rm -rf ~/sdtv && mkdir -p ~/sdtv"
echo "  # from build machine:"
echo "  scp ${TARBALL} deck@DECK_IP:~/sdtv-deck.tar.gz"
echo "  # on Deck:"
echo "  tar -xzf ~/sdtv-deck.tar.gz -C ~/sdtv"
echo "  chmod +x ~/sdtv/run-sdtv.sh ~/sdtv/sdtv"
echo "  cd ~/sdtv && ./run-sdtv.sh"
echo "=========================================="
