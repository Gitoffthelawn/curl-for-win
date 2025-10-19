#!/usr/bin/env bash

# Copyright (C) Viktor Szakats. See LICENSE.md
# SPDX-License-Identifier: MIT

# Issues (as of 1.34.5):
# - `-DCARES_SYMBOL_HIDING=ON` does not seem to work on macOS with clang for
#   example. The issue seems to be that CARES_EXTERN is set unconditionally
#   to default visibility and -fvisibility=hidden does not override that.
# - Compiler warnings when building for macOS with GCC.
# - `bool` type is undeclared in <notify.h> when building for macOS with GCC.
#   [MERGED via https://github.com/c-ares/c-ares/pull/989 expected in next after 1.34.5 release]
# - Bad cmake configure performance.

# shellcheck disable=SC3040,SC2039
set -o xtrace -o errexit -o nounset; [ -n "${BASH:-}${ZSH_NAME:-}" ] && set -o pipefail

export _NAM _VER _OUT _BAS _DST

_NAM="$(basename "$0" | cut -f 1 -d '.')"
_VER="$1"

(
  cd "${_NAM}" || exit 0

  rm -r -f "${_PKGDIR:?}" "${_BLDDIR:?}"

  options=''

  if [ "${_OS}" = 'mac' ]; then
    if [ "${_CC}" = 'gcc' ]; then
      options+=' -DHAVE__Wpedantic=0 -DHAVE__Wsign_conversion=0 -DHAVE__Wconversion=0'
    fi
    if [ "${_OSVER}" -lt '1011' ]; then
      options+=' -DHAVE_CONNECTX=0'  # connectx() requires 10.11
    fi
  fi

  # shellcheck disable=SC2086
  cmake -B "${_BLDDIR}" ${_CMAKE_GLOBAL} ${options} \
    -DCARES_SYMBOL_HIDING=ON \
    -DCARES_STATIC=ON \
    -DCARES_STATIC_PIC=ON \
    -DCARES_SHARED=OFF \
    -DCARES_BUILD_TESTS=OFF \
    -DCARES_BUILD_CONTAINER_TESTS=OFF \
    -DCARES_BUILD_TOOLS=OFF \
    -DCMAKE_C_FLAGS="${_CFLAGS_GLOBAL_CMAKE} ${_CFLAGS_GLOBAL} ${_CPPFLAGS_GLOBAL} ${_LDFLAGS_GLOBAL}"

  cmake --build "${_BLDDIR}"
  cmake --install "${_BLDDIR}" --prefix "${_PP}"

  # Delete .pc files
  rm -r -f "${_PP}"/lib/pkgconfig

  # Make steps for determinism

  readonly _ref='RELEASE-NOTES.md'

  # shellcheck disable=SC2086
  "${_STRIP_LIB}" ${_STRIPFLAGS_LIB} "${_PP}"/lib/*.a

  touch -c -r "${_ref}" "${_PP}"/include/*.h
  touch -c -r "${_ref}" "${_PP}"/lib/*.a

  # Create package

  _OUT="${_NAM}-${_VER}${_REVSUFFIX}${_PKGSUFFIX}"
  _BAS="${_NAM}-${_VER}${_PKGSUFFIX}"
  _DST="$(pwd)/_pkg"; rm -r -f "${_DST}"

  mkdir -p "${_DST}"/include
  mkdir -p "${_DST}"/lib

  cp -f -p "${_PP}"/include/*.h "${_DST}"/include/
  cp -f -p "${_PP}"/lib/*.a     "${_DST}"/lib/
  cp -f -p README.md            "${_DST}"/
  cp -f -p RELEASE-NOTES.md     "${_DST}"/
  cp -f -p LICENSE.md           "${_DST}"/

  ../_pkg.sh "$(pwd)/${_ref}"
)
