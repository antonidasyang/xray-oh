#!/usr/bin/env bash
# Builds golib/ into entry/libs/arm64-v8a/libxray.so (packaged into the HAP as is)
# and its C header into entry/src/main/cpp/include/libxray.h.
#
# Requirements (see README.md):
#   - the openharmony Go toolchain (OHOS_GO, default ~/ohos-toolchain/ohos-go-1.27.4):
#     a Go 1.27 with the openharmony port and arm64 TLSDESC. Stock Go cannot build
#     a c-shared library that musl will dlopen.
#   - DevEco Studio's OHOS NDK clang (DEVECO_SDK_HOME / OHOS_NATIVE_HOME).
#   - xray-core checked out next to this repo on its harmonyos branch (golib/go.mod replace).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OHOS_GO="${OHOS_GO:-${HOME}/ohos-toolchain/ohos-go-1.27.4}"
SDK_HOME="${DEVECO_SDK_HOME:-/Applications/DevEco-Studio.app/Contents/sdk}"
OHOS_NATIVE_HOME="${OHOS_NATIVE_HOME:-${SDK_HOME}/default/openharmony/native}"
LLVM_BIN="${OHOS_NATIVE_HOME}/llvm/bin"
OUT_DIR="${ROOT_DIR}/entry/libs/arm64-v8a"
INCLUDE_DIR="${ROOT_DIR}/entry/src/main/cpp/include"
WORK_DIR="${ROOT_DIR}/.build-golib"

if [[ ! -x "${OHOS_GO}/bin/go" ]]; then
  echo "ERROR: openharmony Go toolchain not found at ${OHOS_GO} (set OHOS_GO)" >&2
  exit 1
fi
if ! grep -qx 'openharmony/arm64' <<<"$("${OHOS_GO}/bin/go" tool dist list)"; then
  echo "ERROR: ${OHOS_GO} has no openharmony/arm64 port" >&2
  exit 1
fi
if [[ ! -x "${LLVM_BIN}/aarch64-unknown-linux-ohos-clang" ]]; then
  echo "ERROR: OHOS clang not found under ${LLVM_BIN} (set DEVECO_SDK_HOME or OHOS_NATIVE_HOME)" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}" "${INCLUDE_DIR}" "${WORK_DIR}"
# Only the Xray* C API is exported; everything else stays local to the library.
cat > "${WORK_DIR}/libxray.map" <<'MAP'
{
  global:
    XraySetCallbacks;
    XrayStart;
    XrayStop;
    XrayIsRunning;
    XrayVersion;
    XrayFree;
  local: *;
};
MAP

COMMIT="$(git -C "${ROOT_DIR}/../xray-core" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"

cd "${ROOT_DIR}/golib"
export PATH="${OHOS_GO}/bin:${PATH}"
export GOTOOLCHAIN=local
# global-dynamic: musl refuses initial-exec TLS in a dlopen'ed library.
# No -tags netgo: the openharmony net package needs cgo.
CGO_ENABLED=1 GOOS=openharmony GOARCH=arm64 \
CC="${LLVM_BIN}/aarch64-unknown-linux-ohos-clang" \
CXX="${LLVM_BIN}/aarch64-unknown-linux-ohos-clang++" \
CGO_CFLAGS="-O2 -ftls-model=global-dynamic" \
go build \
  -trimpath -buildvcs=false \
  -buildmode=c-shared \
  -ldflags="-s -w -buildid= -X github.com/xtls/xray-core/core.build=${COMMIT} -linkmode external -extldflags '-Wl,--version-script=${WORK_DIR}/libxray.map -Wl,-soname,libxray.so'" \
  -o "${OUT_DIR}/libxray.so" \
  .

SO="${OUT_DIR}/libxray.so"
mv "${OUT_DIR}/libxray.h" "${INCLUDE_DIR}/libxray.h"
echo "Built ${SO} ($(du -h "${SO}" | cut -f1)), xray-core ${COMMIT}"

# Sanity checks: the openharmony port must have produced descriptor-based TLS.
RELOCS="$("${LLVM_BIN}/llvm-readelf" -r "${SO}")"
if ! grep -q 'R_AARCH64_TLSDESC' <<<"${RELOCS}"; then
  echo "ERROR: no R_AARCH64_TLSDESC relocation in ${SO}; it will not load on HarmonyOS" >&2
  exit 1
fi
if grep -q 'TLS_TPREL\|TLSIE' <<<"${RELOCS}"; then
  echo "WARN: initial-exec TLS relocations remain in ${SO}" >&2
fi
echo "Exported symbols:"
"${LLVM_BIN}/llvm-nm" -D --defined-only "${SO}" | grep ' T ' | sed 's/^/  /'
