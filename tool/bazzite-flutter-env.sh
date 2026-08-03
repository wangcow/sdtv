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

export PATH="${HOME}/sdk/flutter/bin:/home/linuxbrew/.linuxbrew/opt/llvm/bin:/home/linuxbrew/.linuxbrew/bin:${PATH}"

if command -v brew >/dev/null 2>&1; then
  BREW="$(brew --prefix)"
  XORGPROTO="$(brew --prefix xorgproto 2>/dev/null || true)"
  LIBFFI="$(brew --prefix libffi 2>/dev/null || true)"
  MPV="$(brew --prefix mpv 2>/dev/null || true)"
  export PKG_CONFIG_PATH="${BREW}/lib/pkgconfig:${BREW}/share/pkgconfig${XORGPROTO:+:${XORGPROTO}/share/pkgconfig}${LIBFFI:+:${LIBFFI}/lib/pkgconfig}${MPV:+:${MPV}/lib/pkgconfig}${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
  export CMAKE_PREFIX_PATH="${BREW}${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}"
  # Runtime: prefer system GL/EGL, but allow brew libmpv resolution.
  # Do not set LD_LIBRARY_PATH globally (breaks NVIDIA); rpath from the
  # flutter/media_kit build should find brew mpv when linked.
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
