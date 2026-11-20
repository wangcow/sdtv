#!/usr/bin/env bash
# Source this before flutter run/build on Bazzite (immutable host + Homebrew).
# Usage:  source tool/bazzite-flutter-env.sh
#
# One-time brew packages:
#   brew install cmake ninja llvm gtk+3 xorgproto mpv
#
# IMPORTANT: Do NOT put Homebrew's lib/ on LD_LIBRARY_PATH when running the app.
# That forces brew's Mesa/EGL over the system NVIDIA drivers and the window
# never appears (libEGL: "driver (null)", "failed to create dri2 screen").
# PKG_CONFIG_PATH is enough for *building* against brew GTK headers.
#
# Flutter SDK, first hit wins (override with FLUTTER_ROOT):
#   ~/.sdk/flutter
#   ~/sdk/flutter
#   ~/sdk/flutter

export PATH="/home/linuxbrew/.linuxbrew/opt/llvm/bin:/home/linuxbrew/.linuxbrew/bin:${PATH}"

_sdtv_prepend_flutter() {
  local root="$1"
  if [[ -n "${root}" && -x "${root}/bin/flutter" ]]; then
    export PATH="${root}/bin:${PATH}"
    return 0
  fi
  return 1
}

if ! _sdtv_prepend_flutter "${FLUTTER_ROOT:-}"; then
  for _sdtv_flutter_candidate in \
    "${HOME}/.sdk/flutter" \
    "${HOME}/sdk/flutter" \
    "${HOME}/sdk/flutter"
  do
    if _sdtv_prepend_flutter "${_sdtv_flutter_candidate}"; then
      break
    fi
  done
  unset _sdtv_flutter_candidate
fi
unset -f _sdtv_prepend_flutter

# Deck packaging sets SDTV_BREW_DEPS=1 so the release links Homebrew mpv,
# then package-deck.sh copies those media libs into the bundle.
# A normal ./tool/run.sh must NOT do that. Homebrew's prefix also contains
# Mesa and glib. CMake then links the media_kit plugins to that EGL, Fedora's
# Iris/NVIDIA driver is hidden, and Flutter aborts with
# "No provider of glGetShaderiv found".
if [[ "${SDTV_BREW_DEPS:-}" == "1" ]] && command -v brew >/dev/null 2>&1; then
  BREW="$(brew --prefix)"
  XORGPROTO="$(brew --prefix xorgproto 2>/dev/null || true)"
  LIBFFI="$(brew --prefix libffi 2>/dev/null || true)"
  MPV="$(brew --prefix mpv 2>/dev/null || true)"
  export PKG_CONFIG_PATH="${BREW}/lib/pkgconfig:${BREW}/share/pkgconfig${XORGPROTO:+:${XORGPROTO}/share/pkgconfig}${LIBFFI:+:${LIBFFI}/lib/pkgconfig}${MPV:+:${MPV}/lib/pkgconfig}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
  export CMAKE_PREFIX_PATH="${BREW}${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}"
else
  unset CMAKE_PREFIX_PATH || true
  if [[ -n "${PKG_CONFIG_PATH:-}" ]]; then
    _sdtv_pkg=""
    IFS=':' read -ra _sdtv_pkg_parts <<< "${PKG_CONFIG_PATH}"
    for _sdtv_pkg_part in "${_sdtv_pkg_parts[@]}"; do
      [[ "${_sdtv_pkg_part}" == *linuxbrew* ]] && continue
      _sdtv_pkg="${_sdtv_pkg:+${_sdtv_pkg}:}${_sdtv_pkg_part}"
    done
    if [[ -n "${_sdtv_pkg}" ]]; then
      export PKG_CONFIG_PATH="${_sdtv_pkg}"
    else
      unset PKG_CONFIG_PATH || true
    fi
    unset _sdtv_pkg _sdtv_pkg_parts _sdtv_pkg_part
  fi
fi

export CC="${CC:-clang}"
export CXX="${CXX:-clang++}"

# Prefer system OpenGL/EGL (NVIDIA on this machine). Clear a poisoned path.
unset LD_LIBRARY_PATH

# Wayland is fine on Bazzite; if the window is still invisible, try:
#   export GDK_BACKEND=x11

if command -v pkg-config >/dev/null 2>&1; then
  if ! pkg-config --exists gtk+-3.0 2>/dev/null; then
    echo "warning: gtk+-3.0 not found via pkg-config; brew install gtk+3 xorgproto" >&2
  fi
fi
