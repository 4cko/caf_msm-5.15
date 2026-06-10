#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

mkdir -p out

make -j1 ARCH=arm64 O=out gki_defconfig
make -j"$(nproc)" ARCH=arm64 O=out CC=clang LLVM=1 Image modules dtbs
