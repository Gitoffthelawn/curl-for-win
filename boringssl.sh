#!/usr/bin/env bash

# Copyright (C) Viktor Szakats. See LICENSE.md
# SPDX-License-Identifier: MIT

# FIXME (upstream):
# - x64 mingw-w64 pthread ucrt static linking bug -> requires llvm-mingw
# - as of 4fe29ebc hacks are needed to avoid build issues. grep for the hash
#   to find them.
# - BoringSSL also supports native-Windows threading, but it uses
#   MSVC-specific hacks, thus cannot be enabled for MinGW:
#     https://github.com/google/boringssl/blob/master/crypto/thread_win.c
#   Possible solution:
#     https://github.com/dotnet/runtime/blob/cbca5083d3e69f2bd25e397f8894d94d7763a13a/src/mono/mono/mini/mini-windows-tls-callback.c#L56
# - managed to patch BoringSSL to use native Windows threads and thus be
#   able to drop pthreads. curl crashes (with or without this patch.)
# - as of 4fe29ebc, BoringSSL uses C++, so dependents must be built with
#   static standard C++ library. static libunwind is also needed e.g. when
#   using llvm-mingw. Integrating all of this is non-trivial. When not
#   using llvm-mingw, pthreads is necessary again, but it does not trigger
#   the static pthreads linking bug (undefined reference to `_setjmp') we
#   hit earlier.
# - Building tests takes 3 minutes per target (on AppVeyor CI, at the time
#   of this writing) and consumes 9x the disk space for ${_BLDDIR}, that is
#   32MB -> 283MB (for x64).
#   Disabling them requires elaborate edits in ./CMakeList.txt.
#   This is fixed in AWS-LC fork with a CMake option.
# - A test object named trampoline-x86_64.asm.obj ends up in libcrypto.a.
# - nasm includes the first 18 bytes of the HOME directory in its output.
#   e.g. rdrand-x86_64.asm.obj. This only affects libcrypto.a.
#   This is intentionally written into a `.file` record and --reproducible
#   does not disable it. See nasm/output/outcoff.c/coff_write_symbols()
#   PR: https://github.com/netwide-assembler/nasm/pull/33 [RELEASED in v2.16]
#   binutils strip is able to delete it (llvm-strip is not, as of 14.0.6).
# - Objects built on different OSes result in a few byte differences.
#   e.g. windows.c.obj, a_utf8.c.obj. But not a_octet.c.obj.

# https://boringssl.googlesource.com/boringssl/
# https://bugs.chromium.org/p/boringssl/issues/list

# https://chromium.googlesource.com/chromium/src/third_party/boringssl/+/c9aca35314ba018fef141535ca9d4dd39d9bc688%5E%21/
# https://chromium.googlesource.com/chromium/src/third_party/boringssl/
# https://chromium.googlesource.com/chromium/src/+/refs/heads/main/DEPS
# https://github.com/chromium/chromium/commit/6a77772b9bacdf2490948f452bdbc34d3e871be1
# https://github.com/chromium/chromium/tree/main/third_party/boringssl
# https://raw.githubusercontent.com/chromium/chromium/main/DEPS

# shellcheck disable=SC3040,SC2039
set -o xtrace -o errexit -o nounset; [ -n "${BASH:-}${ZSH_NAME:-}" ] && set -o pipefail

export _NAM _VER _OUT _BAS _DST

_NAM="$(basename "$0" | cut -f 1 -d '.')"
_VER="$1"

(
  cd "${_NAM}" || exit 0

  [ "${CW_DEV_INCREMENTAL:-}" != '1' ] && rm -r -f "${_PKGDIR:?}" "${_BLDDIR:?}"

  CFLAGS="-ffile-prefix-map=$(pwd)="
  LIBS='-lpthread'  # for tests
  options=''

  [ "${_CPU}" = 'r64' ] && exit 1  # No support as of 2023-10

  if true; then
    # to avoid (as of 4fe29ebc, root cause undiscovered):
    #   ld.lld: error: undefined symbol: fiat_p256_adx_mul
    #   >>> referenced by libcrypto.a(bcm.o):(fiat_p256_mul)
    #   ld.lld: error: undefined symbol: fiat_p256_adx_sqr
    #   >>> referenced by libcrypto.a(bcm.o):(fiat_p256_square)
    options+=' -DOPENSSL_NO_ASM=ON'
  else
    if [ "${_OS}" = 'win' ] && [ "${_CPU}" != 'a64' ]; then
      # nasm is used for Windows x64 and x86
      options+=' -DCMAKE_ASM_NASM_FLAGS=--reproducible'
    fi
  fi

  # Workaround for Windows x64 llvm 16 breakage as of 85081c6b:
  # In file included from ./boringssl/crypto/curve25519/curve25519_64_adx.c:17:
  # ./boringssl/crypto/curve25519/../../third_party/fiat/curve25519_64_adx.h:40:11: error: call to undeclared function '_umul128'; ISO C99 and later do not support implicit function declarations [-Wimplicit-function-declaration]
  #   *out1 = _umul128(arg1, arg2, &t);
  #           ^
  if [ "${_OS}" = 'win' ] && [ "${_CPU}" = 'x64' ] && [ "${_CC}" = 'llvm' ]; then
    options+=' -DOPENSSL_SMALL=ON'
  else
    options+=' -DOPENSSL_SMALL=OFF'  # ON reduces curl binary sizes by ~300 KB
  fi

  if [ "${CW_DEV_INCREMENTAL:-}" != '1' ] || [ ! -d "${_BLDDIR}" ]; then
    # Patch the build to omit debug info. This results in 50% smaller footprint
    # for each ${_BLDDIR}. As of llvm 14.0.6, llvm-strip does an imperfect job
    # when deleting -ggdb debug info and ends up having ~100 bytes of metadata
    # different (e.g. in windows.c.obj, a_utf8.c.obj, but not a_octet.c.obj)
    # across build host platforms. Fixed either by patching out this flag here,
    # or by running binutils strip on the result. binutils strip do not support
    # ARM64, so patch it out in that case.
    # Enable it for all targets for consistency.
    sed -i.bak 's/ -ggdb//g' ./CMakeLists.txt

    # shellcheck disable=SC2086
    cmake -B "${_BLDDIR}" ${_CMAKE_GLOBAL} ${_CMAKE_CXX_GLOBAL} ${options} \
      '-DBUILD_SHARED_LIBS=OFF' \
      "-DCMAKE_C_FLAGS=${_CFLAGS_GLOBAL_CMAKE} ${_CFLAGS_GLOBAL} ${_CPPFLAGS_GLOBAL} ${CFLAGS} ${_LDFLAGS_GLOBAL} ${LIBS}" \
      "-DCMAKE_CXX_FLAGS=${_CFLAGS_GLOBAL_CMAKE} ${_CFLAGS_GLOBAL} ${_CPPFLAGS_GLOBAL} ${CFLAGS} ${_LDFLAGS_GLOBAL} ${LIBS} ${_CXXFLAGS_GLOBAL} ${_LDFLAGS_CXX_GLOBAL}"
  fi

  make --directory="${_BLDDIR}" --jobs="${_JOBS}" install "DESTDIR=$(pwd)/${_PKGDIR}"  # VERBOSE=1

  # List files created
  find "${_PP}"

  # Make steps for determinism

  readonly _ref='README.md'

  # FIXME: llvm-strip (as of 14.0.6) has a few bugs:
  #        - produces different output across build hosts after stripping libs
  #          compiled with -ggdb.
  #        - fails to strip the `.file` record from NASM objects.
  #          (fixed by --reproducible with nasm v2.16)
  #        - fails to clear timestamps in NASM objects.
  #          (fixed by --reproducible with nasm v2.15.05)
  #        Work around them by running it through binutils strip. This works for
  #        x64 and x86, but not for ARM64.
  #
  # Most combinations/orders running binutils/llvm strip over the output results
  # in different output, and except pure llvm-strip, all seem to be
  # deterministic. We chose to run binutils first and llvm second. This way
  # llvm creates the result we publish.
  #
  # <strip sequence>                                <bytes>
  # libcrypto-noggdb.a                              2858080
  # libcrypto-noggdb-llvm.a                         2482620
  # libcrypto-noggdb-llvm-binutils.a                2488078
  # libcrypto-noggdb-llvm-binutils-llvm.a           2479904
  # libcrypto-noggdb-llvm-binutils-llvm-binutils.a  2488078
  # libcrypto-noggdb-binutils.a                     2465310
  # libcrypto-noggdb-binutils-llvm.a                2479888
  # libcrypto-noggdb-binutils-llvm-binutils.a       2488078
  # libcrypto-ggdb.a                                9642542
  # libcrypto-ggdb-llvm.a                           2482606
  # libcrypto-ggdb-llvm-binutils.a                  2488066
  # libcrypto-ggdb-llvm-binutils-llvm.a             2479890
  # libcrypto-ggdb-llvm-binutils-llvm-binutils.a    2488066
  # libcrypto-ggdb-binutils.a                       2465298
  # libcrypto-ggdb-binutils-llvm.a                  2479874
  # libcrypto-ggdb-binutils-llvm-binutils.a         2488066

  # shellcheck disable=SC2086
  "${_STRIP_LIB}" ${_STRIPFLAGS_LIB} "${_PP}"/lib/libssl.a

  if [ -n "${_STRIP_BINUTILS}" ]; then
    # FIXME: llvm-strip corrupts nasm objects as of LLVM v16.0.0
    # shellcheck disable=SC2086
  # "${_STRIP_LIB}" ${_STRIPFLAGS_LIB} "${_PP}"/lib/libcrypto.a

    # FIXME: Use binutils strip instead, directly on objects, to avoid
    #        binutils strip v2.40 error `invalid operation` when run on
    #        the whole lib:
    ../_clean-lib.sh --strip "${_STRIP_BINUTILS}" "${_PP}"/lib/libcrypto.a
  else
    # shellcheck disable=SC2086
    "${_STRIP_LIB}" ${_STRIPFLAGS_LIB} "${_PP}"/lib/libcrypto.a
  fi

  touch -c -r "${_ref}" "${_PP}"/include/openssl/*.h
  touch -c -r "${_ref}" "${_PP}"/lib/*.a

  # Create package

  _OUT="${_NAM}-${_VER}${_REVSUFFIX}${_PKGSUFFIX}"
  _BAS="${_NAM}-${_VER}${_PKGSUFFIX}"
  _DST="$(pwd)/_pkg"; rm -r -f "${_DST}"

  mkdir -p "${_DST}/include/openssl"
  mkdir -p "${_DST}/lib"

  cp -f -p "${_PP}"/include/openssl/*.h "${_DST}/include/openssl/"
  cp -f -p "${_PP}"/lib/*.a             "${_DST}/lib"
  cp -f -p LICENSE                      "${_DST}/LICENSE.txt"
  cp -f -p README.md                    "${_DST}/"

  ../_pkg.sh "$(pwd)/${_ref}"
)
