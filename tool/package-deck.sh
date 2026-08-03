#!/usr/bin/env bash
# Build a self-contained Linux release for Steam Deck (bundles brew libmpv + deps).
#
# Homebrew sometimes embeds *absolute* DT_NEEDED paths (e.g. mujs Cellar path).
# Those ignore LD_LIBRARY_PATH/RPATH on the Deck — we rewrite them to basenames
# and ensure soname symlinks exist next to each staged library.
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

is_brew_lib() {
  case "$1" in
    /home/linuxbrew/*|/home/*/linuxbrew/*|/var/home/*/linuxbrew/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Collect absolute paths of brew .so files needed by a binary/library.
# Handles both "lib => /path" and bare absolute NEEDED entries (mujs).
collect_brew_deps() {
  local bin="$1"
  # Prefer a full brew library search path so transitive deps resolve.
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
      echo "${path}"
    fi
  done
}

# Ensure soname + common short names point at the staged file.
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

  # Also create unversioned / mid-version names when missing
  # e.g. libfoo.so.4.0.0 -> libfoo.so.4, libfoo.so
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
  dest="${LIBDIR}/${base}"

  if [[ ! -e "${dest}" ]]; then
    cp -L "${real}" "${dest}"
    chmod u+w "${dest}" 2>/dev/null || true
    echo "  + ${base}"
  fi

  # Always ensure soname links (even if file already existed)
  ensure_soname_links "${dest}"

  # If the *source* path had a different basename (symlink name / absolute NEEDED),
  # also stage that name so relative lookups work before patchelf rewrite.
  local src_base
  src_base="$(basename "${src}")"
  if [[ "${src_base}" != "${base}" && ! -e "${LIBDIR}/${src_base}" ]]; then
    ln -sfn "${base}" "${LIBDIR}/${src_base}"
  fi
}

# Rewrite absolute DT_NEEDED entries to basenames so Deck doesn't look in Cellar.
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
      # Ensure the short name exists in the bundle if we have the file.
      if [[ ! -e "${LIBDIR}/${short}" ]]; then
        # Try brew path first
        if [[ -e "${need}" ]]; then
          copy_one "${need}"
        fi
      fi
    fi
  done < <(patchelf --print-needed "${elf}" 2>/dev/null || true)
}

echo "Staging Homebrew libraries into bundle/lib …"

declare -A SEEN=()
QUEUE=()

enqueue() {
  local p="$1"
  [[ -z "${p}" || ! -e "${p}" ]] && return
  local real
  real="$(readlink -f "${p}")"
  [[ -f "${real}" ]] || return
  [[ -n "${SEEN[$real]:-}" ]] && return
  SEEN[$real]=1
  QUEUE+=("${real}")
  # Keep original path too for basename linking (mujs absolute NEEDED)
  if [[ "${p}" != "${real}" ]]; then
    # stored as real; copy_one handles basename of callers
    :
  fi
}

enqueue "${MPV_PREFIX}/lib/libmpv.so.2"
# Explicit seeds for known absolute-NEEDED / often-missed deps
for extra in \
  "$(brew --prefix mujs 2>/dev/null)/lib/libmujs.so" \
  "$(brew --prefix libbluray 2>/dev/null)/lib/libbluray.so" \
  "$(brew --prefix uchardet 2>/dev/null)/lib/libuchardet.so" \
  "$(brew --prefix jpeg-turbo 2>/dev/null)/lib/libjpeg.so" \
  "$(brew --prefix libxpresent 2>/dev/null)/lib/libXpresent.so"
do
  [[ -n "${extra}" && -e "${extra}" ]] && enqueue "${extra}"
done

for f in "${LIBDIR}"/libmedia_kit*.so "${LIBDIR}"/libapp.so "${BUNDLE}/sdtv"; do
  [[ -f "${f}" ]] || continue
  while read -r dep; do
    enqueue "${dep}"
  done < <(collect_brew_deps "${f}")
done

# BFS: copy each lib and enqueue *its* brew deps
i=0
while [[ ${i} -lt ${#QUEUE[@]} ]]; do
  lib="${QUEUE[$i]}"
  i=$((i + 1))
  copy_one "${lib}"
  while read -r dep; do
    enqueue "${dep}"
  done < <(collect_brew_deps "${lib}")
done

# Ensure short libmpv names exist
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
  # mujs often has no SONAME — guarantee plain name
  if [[ -f libmujs.so ]] || ls libmujs.so* >/dev/null 2>&1; then
    MUJS_REAL="$(ls -1 libmujs.so* 2>/dev/null | grep -v '^libmujs\.so$' | head -1 || true)"
    if [[ -z "${MUJS_REAL}" && -f libmujs.so && ! -L libmujs.so ]]; then
      : # already the real file named libmujs.so
    elif [[ -n "${MUJS_REAL}" ]]; then
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

# Second pass: any newly enqueued deps from rewrites
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

# Re-ensure soname links for everything (new copies)
for so in "${LIBDIR}"/*.so "${LIBDIR}"/*.so.*; do
  [[ -f "${so}" && ! -L "${so}" ]] || continue
  ensure_soname_links "${so}"
done

echo "Setting RPATH=\$ORIGIN on bundled libs and binary…"
for so in "${LIBDIR}"/*.so "${LIBDIR}"/*.so.*; do
  [[ -f "${so}" && ! -L "${so}" ]] || continue
  patchelf --set-rpath '$ORIGIN' "${so}" 2>/dev/null || true
done
if [[ -f "${BUNDLE}/sdtv" ]]; then
  patchelf --set-rpath '$ORIGIN/lib' "${BUNDLE}/sdtv" 2>/dev/null || true
fi

# Wrapper: force bundled libs first (Deck has no brew Cellar)
cat > "${BUNDLE}/run-sdtv.sh" <<'EOF'
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
# Bundled libs first — never search build-machine Homebrew paths
export LD_LIBRARY_PATH="${DIR}/lib"
exec "${DIR}/sdtv" "$@"
EOF
chmod +x "${BUNDLE}/run-sdtv.sh" "${BUNDLE}/sdtv"

# Homebrew libs often ship mode 555; make everything user-writable so scp/rsync
# can overwrite a previous install on the Deck without "Permission denied".
echo "Making bundle user-writable (for re-deploy)…"
chmod -R u+rwX "${BUNDLE}"
# Symlinks don't need modes; real .so + binary stay executable
find "${BUNDLE}" -type f \( -name '*.so' -o -name '*.so.*' -o -name 'sdtv' -o -name 'run-sdtv.sh' \) \
  -exec chmod u+rwx {} +

echo ""
echo "=== libmpv / mujs / bluray sonames in bundle ==="
ls -la "${LIBDIR}"/libmpv* "${LIBDIR}"/libmujs* \
  "${LIBDIR}"/libbluray* "${LIBDIR}"/libuchardet* \
  "${LIBDIR}"/libjpeg* "${LIBDIR}"/libXpresent* 2>/dev/null || true

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
echo "=== smoke: ldd with only bundle lib (mpv) ==="
# Unset brew RPATH influence by using only LD_LIBRARY_PATH
smoke_out="$(LD_LIBRARY_PATH="${LIBDIR}" ldd "${LIBDIR}/libmpv.so.2" 2>&1 || true)"
if echo "${smoke_out}" | grep -E 'not found|linuxbrew'; then
  echo "WARNING: still missing or still pointing at brew paths:" >&2
  echo "${smoke_out}" | grep -E 'not found|linuxbrew' || true
else
  echo "OK: no 'not found' / brew paths for libmpv under LD_LIBRARY_PATH=bundle/lib"
fi

echo ""
echo "=== smoke: mujs resolution ==="
if echo "${smoke_out}" | grep -q 'libmujs'; then
  echo "${smoke_out}" | grep 'libmujs'
else
  # After rewrite it should show as libmujs.so => .../bundle/lib/libmujs.so
  LD_LIBRARY_PATH="${LIBDIR}" ldd "${LIBDIR}/libmpv.so.2" 2>&1 | grep -i mujs || echo "(no mujs line — check NEEDED)"
  patchelf --print-needed "${LIBDIR}/libmpv.so.2" | grep -i mujs || true
fi

# Single-file tarball: atomic transfer avoids partial scp + permission fights
DIST="${ROOT}/dist"
mkdir -p "${DIST}"
TARBALL="${DIST}/sdtv-deck.tar.gz"
echo ""
echo "Creating ${TARBALL} …"
# Archive contents of bundle as top-level (sdtv, lib/, data/, run-sdtv.sh) — not a nested bundle/
tar -C "${BUNDLE}" -czf "${TARBALL}" .
ls -lh "${TARBALL}"

echo ""
echo "=========================================="
echo "Bundle ready: ${BUNDLE}"
echo "Tarball:      ${TARBALL}"
echo ""
echo "Deploy to Deck (recommended — wipe old install first):"
echo ""
echo "  # On Deck (ssh or Konsole):"
echo "  rm -rf ~/sdtv"
echo "  mkdir -p ~/sdtv"
echo ""
echo "  # On build machine:"
echo "  scp ${TARBALL} deck@DECK_IP:~/sdtv-deck.tar.gz"
echo ""
echo "  # On Deck:"
echo "  tar -xzf ~/sdtv-deck.tar.gz -C ~/sdtv"
echo "  chmod +x ~/sdtv/run-sdtv.sh ~/sdtv/sdtv"
echo "  cd ~/sdtv && ./run-sdtv.sh"
echo ""
echo "Do NOT scp -r over an old install — read-only libs cause Permission denied"
echo "and leave a half-updated tree (missing libmpv, stale absolute paths)."
echo "Always use ./run-sdtv.sh, not ./sdtv directly."
echo "=========================================="
