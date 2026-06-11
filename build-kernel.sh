#!/usr/bin/env bash
set -euo pipefail

# MikuKernel Build Script
# Supports both ARM64 (64-bit) and ARM32 (32-bit) builds

# Configuration
BUILD_DIR="${BUILD_DIR:-.}"
OUT_DIR="${OUT_DIR:-${BUILD_DIR}/out}"
DIST_DIR="${DIST_DIR:-${OUT_DIR}/dist}"
JOBS="${JOBS:-$(nproc)}"
ARCH="${ARCH:-arm64}"
VARIANT="${VARIANT:-gki}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

usage() {
    cat << EOF_USAGE
MikuKernel Build Script

Usage: $0 [OPTIONS]

OPTIONS:
    -a, --arch ARCH         Build architecture: arm64 or arm (default: arm64)
    -v, --variant VARIANT   Kernel variant (default: gki)
    -j, --jobs JOBS         Number of parallel jobs (default: $(nproc))
    -o, --out-dir DIR       Output directory (default: out)
    -d, --dist-dir DIR      Distribution directory (default: out/dist)
    -c, --config-only       Only generate .config without building
    -C, --clean             Clean build directory before building
    -b, --both              Build both arm64 and arm (32-bit)
    -h, --help             Show this help message

EXAMPLES:
    # Build arm64 (64-bit) kernel
    $0 --arch arm64

    # Build arm32 (32-bit) kernel
    $0 --arch arm

    # Build both arm64 and arm
    $0 --both

    # Clean build with 16 jobs
    $0 --clean --jobs 16

EOF_USAGE
    exit 0
}

# Parse arguments
BUILD_BOTH=false
CONFIG_ONLY=false
CLEAN_BUILD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -a|--arch)
            ARCH="$2"
            shift 2
            ;;
        -v|--variant)
            VARIANT="$2"
            shift 2
            ;;
        -j|--jobs)
            JOBS="$2"
            shift 2
            ;;
        -o|--out-dir)
            OUT_DIR="$2"
            DIST_DIR="${OUT_DIR}/dist"
            shift 2
            ;;
        -d|--dist-dir)
            DIST_DIR="$2"
            shift 2
            ;;
        -c|--config-only)
            CONFIG_ONLY=true
            shift
            ;;
        -C|--clean)
            CLEAN_BUILD=true
            shift
            ;;
        -b|--both)
            BUILD_BOTH=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Generate random kernel label
if [ -x "./scripts/generate_kernel_label.sh" ]; then
    KERNEL_LABEL=$(bash ./scripts/generate_kernel_label.sh)
else
    RANDOM_HEX=$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    RANDOM_HEX=${RANDOM_HEX:0:7}
    KERNEL_LABEL="g${RANDOM_HEX}"
fi
log_info "Generated kernel label: $KERNEL_LABEL"

# Set builder identity from current terminal environment
BUILD_USER="${KBUILD_BUILD_USER:-$(id -un)}"
BUILD_HOST="${KBUILD_BUILD_HOST:-$(hostname -f 2>/dev/null || hostname)}"
export KBUILD_BUILD_USER="$BUILD_USER"
export KBUILD_BUILD_HOST="$BUILD_HOST"
log_info "Build user set to: $BUILD_USER@$BUILD_HOST"

# Validate architecture
validate_arch() {
    case "$1" in
        arm64|arm)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

if [ "$BUILD_BOTH" = true ]; then
    log_info "Building both ARM64 and ARM (32-bit)"
else
    if ! validate_arch "$ARCH"; then
        log_error "Unsupported architecture: $ARCH. Use 'arm64' or 'arm'"
        exit 1
    fi
    log_info "Building for $ARCH architecture"
fi

# Clean build directory if requested
if [ "$CLEAN_BUILD" = true ]; then
    log_info "Cleaning build directory: $OUT_DIR"
    rm -rf "$OUT_DIR"
fi

# Create output directories
mkdir -p "$OUT_DIR" "$DIST_DIR"

# Determine default defconfig target
determine_defconfig_target() {
    local arch=$1
    local requested="${VARIANT}_defconfig"
    if [ -f "arch/${arch}/configs/${requested}" ]; then
        echo "$requested"
    else
        echo "defconfig"
    fi
}

build_kernel() {
    local arch=$1
    local build_out="${OUT_DIR}/${arch}"
    local dist_out="${DIST_DIR}/${arch}"
    local defconfig_target

    log_info "Building kernel for $arch (variant: $VARIANT)"

    mkdir -p "$build_out" "$dist_out"

    export ARCH="$arch"
    export VARIANT="$VARIANT"
    export LOCALVERSION="-${KERNEL_LABEL}"

    defconfig_target=$(determine_defconfig_target "$arch")
    log_info "Using defconfig target: $defconfig_target"

    log_info "Generating .config for $arch"
    make -C . O="$build_out" ARCH="$arch" "$defconfig_target" -j1 || {
        log_error "Failed to generate .config for $arch"
        return 1
    }

    if [ "$CONFIG_ONLY" = true ]; then
        log_info "Configuration generated only (--config-only flag set)"
        return 0
    fi

    log_info "Building kernel for $arch with $JOBS jobs"
    make -C . O="$build_out" ARCH="$arch" -j "$JOBS" all || {
        log_error "Failed to build kernel for $arch"
        return 1
    }

    log_info "Installing modules for $arch"
    make -C . O="$build_out" ARCH="$arch" INSTALL_MOD_PATH="$build_out/modules" -j "$JOBS" modules_install || {
        log_error "Failed to install modules for $arch"
        return 1
    }

    log_info "Copying kernel artifacts to $dist_out"
    if [ "$arch" = "arm64" ]; then
        if [ -f "$build_out/arch/arm64/boot/Image" ]; then
            cp "$build_out/arch/arm64/boot/Image" "$dist_out/Image-arm64-${KERNEL_LABEL}"
        fi
        if [ -f "$build_out/arch/arm64/boot/Image.gz" ]; then
            cp "$build_out/arch/arm64/boot/Image.gz" "$dist_out/Image-arm64-${KERNEL_LABEL}.gz"
        fi
    else
        if [ -f "$build_out/arch/arm/boot/zImage" ]; then
            cp "$build_out/arch/arm/boot/zImage" "$dist_out/zImage-arm-${KERNEL_LABEL}"
        fi
        if [ -f "$build_out/arch/arm/boot/Image" ]; then
            cp "$build_out/arch/arm/boot/Image" "$dist_out/Image-arm-${KERNEL_LABEL}"
        fi
    fi

    if [ -f "$build_out/System.map" ]; then
        cp "$build_out/System.map" "$dist_out/System.map-${arch}-${KERNEL_LABEL}"
    fi

    if [ -f "$build_out/.config" ]; then
        cp "$build_out/.config" "$dist_out/.config-${arch}-${KERNEL_LABEL}"
    fi

    if [ -f "$build_out/modules/.modules_install_ok" ]; then
        cp "$build_out/modules/.modules_install_ok" "$dist_out/modules_install_${arch}.ok" 2>/dev/null || true
    fi

    log_info "Successfully built kernel for $arch"
}

built_arches=()
if [ "$BUILD_BOTH" = true ]; then
    build_kernel "arm64" || exit 1
    built_arches+=("arm64")
    build_kernel "arm" || exit 1
    built_arches+=("arm")
else
    build_kernel "$ARCH" || exit 1
    built_arches+=("$ARCH")
fi

cat > "${DIST_DIR}/BUILD_INFO.txt" << EOF
MikuKernel Build Information
===========================
Build Date: $(date -u)
Kernel Label: $KERNEL_LABEL
Build User: $BUILD_USER
Build Host: $BUILD_HOST
Architectures: ${built_arches[*]}
Variant: $VARIANT
Build Jobs: $JOBS
EOF

log_info "Build completed successfully!"
log_info "Build artifacts available in: $DIST_DIR"
log_info "Kernel Label: $KERNEL_LABEL"

echo ""
find "$DIST_DIR" -maxdepth 2 -type f | sort

