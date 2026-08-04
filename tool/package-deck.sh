#!/usr/bin/env bash
# Build a Deck-friendly Linux release: brew libmpv + media codecs only.
#
# Do NOT ship brew GTK / X11 / xkbcommon / mesa / fontconfig — those pull
# Homebrew *data* paths (/home/linuxbrew/.../share/X11/xkb) and crash on Deck
# with "Failed to create XKB keymap". Use the Deck's system UI stack.
#
# Homebrew sometimes embeds absolute DT_NEEDED (e.g. mujs Cellar). Rewrite
# those to basenames and ensure soname symlinks exist in bundle/lib.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/tool/bazzite-flutter-env.sh"

if ! command -v brew >/dev/null 2>&1; then
  echo "error: Homebrew not found (need: brew install mpv)" >&2
  exit 1
fi

MPV_PREFIX="$(brew --prefix mpv 2>/dev/null || true)"
if [[ -z "${MPV_PREFIX}" || ! -f "${MPV_PREFIX}/lib/libmpv.so.2" ]]; then
  echo "error: mpv not installed. Run: brew install mpv" >&2
  exit 1
fi

if ! command -v patchelf >/dev/null 2>&1; then
  echo "Installing patchelf (for RPATH / NEEDED rewrite)…"
  brew install patchelf
fi

echo "Building release…"
cd "${ROOT}/apps/sdtv"
flutter build linux --release

BUNDLE="${ROOT}/apps/sdtv/build/linux/x64/release/bundle"
LIBDIR="${BUNDLE}/lib"
if [[ ! -d "${LIBDIR}" ]]; then
  echo "error: missing ${LIBDIR}" >&2
  exit 1
fi

# Remove previously staged brew UI/graphics libs so a re-package is clean.
# Keep Flutter/media_kit plugin .so and libapp.so.
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

echo "Staging Homebrew *media* libraries into bundle/lib (not GTK/X11/mesa)…"

declare -A SEEN=()
QUEUE=()

enqueue() {
  local p="$1"
  [[ -z "${p}" || ! -e "${p}" ]] && return
  local real base
  real="$(readlink -f "${p}")"
  [[ -f "${real}" ]] || return
  base="$(basename "${real}")"
  if is_host_only_lib "${base}" || is_host_only_lib "$(basename "${p}")"; then
    return
  fi
  [[ -n "${SEEN[$real]:-}" ]] && return
  SEEN[$real]=1
  QUEUE+=("${real}")
}

# Seed ONLY libmpv + known media deps. Do not walk sdtv's GTK deps.
enqueue "${MPV_PREFIX}/lib/libmpv.so.2"
for extra in \
  "$(brew --prefix mujs 2>/dev/null)/lib/libmujs.so" \
  "$(brew --prefix libbluray 2>/dev/null)/lib/libbluray.so" \
  "$(brew --prefix uchardet 2>/dev/null)/lib/libuchardet.so" \
  "$(brew --prefix jpeg-turbo 2>/dev/null)/lib/libjpeg.so" \
  "$(brew --prefix libass 2>/dev/null)/lib/libass.so" \
  "$(brew --prefix ffmpeg 2>/dev/null)/lib/libavcodec.so" \
  "$(brew --prefix libplacebo 2>/dev/null)/lib/libplacebo.so" \
  "$(brew --prefix libxpresent 2>/dev/null)/lib/libXpresent.so" \
  "$(brew --prefix bzip2 2>/dev/null)/lib/libbz2.so"
do
  [[ -n "${extra}" && -e "${extra}" ]] && enqueue "${extra}"
done

# media_kit plugins may need libmpv only; still walk their brew deps if any
for f in "${LIBDIR}"/libmedia_kit*.so; do
  [[ -f "${f}" ]] || continue
  while read -r dep; do
    enqueue "${dep}"
  done < <(collect_brew_deps "${f}")
done

i=0
while [[ ${i} -lt ${#QUEUE[@]} ]]; do
  lib="${QUEUE[$i]}"
  i=$((i + 1))
  copy_one "${lib}"
  while read -r dep; do
    enqueue "${dep}"
  done < <(collect_brew_deps "${lib}")
done

(
  cd "${LIBDIR}"
  REAL="$(ls libmpv.so.*.* 2>/dev/null | head -1 || true)"
  if [[ -z "${REAL}" ]]; then
    REAL="$(ls libmpv.so.* 2>/dev/null | grep -v '\.2$' | head -1 || true)"
  fi
  if [[ -n "${REAL}" ]]; then
    ln -sfn "${REAL}" libmpv.so.2
    ln -sfn libmpv.so.2 libmpv.so
  fi
  if [[ -f libmujs.so ]] || ls libmujs.so* >/dev/null 2>&1; then
    MUJS_REAL="$(ls -1 libmujs.so* 2>/dev/null | grep -v '^libmujs\.so$' | head -1 || true)"
    if [[ -n "${MUJS_REAL}" ]]; then
      ln -sfn "${MUJS_REAL}" libmujs.so
    fi
  fi
)

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

echo "Setting RPATH=\$ORIGIN on bundled media libs and binary…"
for so in "${LIBDIR}"/*.so "${LIBDIR}"/*.so.*; do
  [[ -f "${so}" && ! -L "${so}" ]] || continue
  # Flutter plugin / app libs can keep default; still set $ORIGIN for consistency
  patchelf --set-rpath '$ORIGIN' "${so}" 2>/dev/null || true
done
if [[ -f "${BUNDLE}/sdtv" ]]; then
  patchelf --set-rpath '$ORIGIN/lib' "${BUNDLE}/sdtv" 2>/dev/null || true
fi

# Wrapper: media libs first, but force *system* XKB/fontconfig data paths.
# Never leave LD_LIBRARY_PATH empty of system fallbacks for dlopen of GPU drivers.
cat > "${BUNDLE}/run-sdtv.sh" <<'EOF'
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"

# Prefer *system* libmpv when present (Steam Deck / SteamOS VAAPI).
# Homebrew libmpv is often built *without* VAAPI → software decode → stutter / ~7fps.
# DT_RUNPATH is $ORIGIN/lib; with RUNPATH, LD_LIBRARY_PATH is searched first.
SYS_LIB=""
if [ -e /usr/lib64/libmpv.so.2 ] || [ -e /usr/lib64/libmpv.so ]; then
  SYS_LIB="/usr/lib64"
elif [ -e /usr/lib/libmpv.so.2 ] || [ -e /usr/lib/libmpv.so ]; then
  SYS_LIB="/usr/lib"
fi

if [ -n "$SYS_LIB" ] && [ "${SDTV_FORCE_BUNDLED_MPV:-0}" != "1" ]; then
  # System mpv + mesa first; bundled codecs/ffmpeg still available after.
  export LD_LIBRARY_PATH="${SYS_LIB}:/usr/lib64:/usr/lib:${DIR}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export SDTV_MPV_SOURCE=system
else
  export LD_LIBRARY_PATH="${DIR}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export SDTV_MPV_SOURCE=bundled
fi

# Point fontconfig/xkb at Deck OS (never Homebrew data prefixes).
if [ -d /usr/share/X11/xkb ]; then
  export XKB_CONFIG_ROOT=/usr/share/X11/xkb
fi
if [ -f /etc/fonts/fonts.conf ]; then
  export FONTCONFIG_FILE=/etc/fonts/fonts.conf
fi
if [ -d /usr/share/glib-2.0/schemas ]; then
  export GSETTINGS_SCHEMA_DIR=/usr/share/glib-2.0/schemas
fi

# Optional overrides (create yourself; not in the tarball), e.g.:
#   echo 'SDTV_FORCE_MOCK=1' > sdtv.env
#   echo 'SDTV_FORCE_BUNDLED_MPV=1' >> sdtv.env   # debug only
if [ -f "${DIR}/sdtv.env" ]; then
  # shellcheck disable=SC1091
  set -a
  . "${DIR}/sdtv.env"
  set +a
fi

exec "${DIR}/sdtv" "$@"
EOF
chmod +x "${BUNDLE}/run-sdtv.sh" "${BUNDLE}/sdtv"

echo "Making bundle user-writable (for re-deploy)…"
chmod -R u+rwX "${BUNDLE}"
find "${BUNDLE}" -type f \( -name '*.so' -o -name '*.so.*' -o -name 'sdtv' -o -name 'run-sdtv.sh' \) \
  -exec chmod u+rwx {} +

echo ""
echo "=== libmpv / mujs in bundle ==="
ls -la "${LIBDIR}"/libmpv* "${LIBDIR}"/libmujs* 2>/dev/null || true

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

echo ""
echo "=== smoke: ldd libmpv with bundle lib first ==="
smoke_out="$(LD_LIBRARY_PATH="${LIBDIR}" ldd "${LIBDIR}/libmpv.so.2" 2>&1 || true)"
if echo "${smoke_out}" | grep -E 'not found|linuxbrew'; then
  echo "NOTE: unresolved under bundle-only (host libs OK on Deck):" >&2
  echo "${smoke_out}" | grep -E 'not found|linuxbrew' || true
else
  echo "OK: no 'not found' / brew paths for libmpv under LD_LIBRARY_PATH=bundle/lib"
fi
echo "${smoke_out}" | grep -i mujs || true

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
