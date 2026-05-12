#!/bin/bash
# =============================================================
#  Pixel 3 (blueline) Kernel Builder
#  Kernel  : AOSP 4.9.x (android-msm-crosshatch-4.9-android12)
#  Features: KernelSU Next + SusFS + OverlayFS
# =============================================================
set -e

# ──────────────────────────────────────────────
# CONFIG — chỉnh nếu cần
# ──────────────────────────────────────────────
KERNEL_BRANCH="android-msm-crosshatch-4.9-android12"
KERNEL_REPO="https://android.googlesource.com/kernel/msm"
KSU_BRANCH="next"
SUSFS_BRANCH="kernel-4.9"

BASE_DIR="$(pwd)"
KERNEL_DIR="${BASE_DIR}/msm-kernel"
CLANG_DIR="${BASE_DIR}/toolchain/clang"
GCC64_DIR="${BASE_DIR}/toolchain/gcc-arm64"
GCC32_DIR="${BASE_DIR}/toolchain/gcc-arm"
SUSFS_DIR="${BASE_DIR}/susfs4ksu"
OUT_DIR="${KERNEL_DIR}/out"
AK3_DIR="${BASE_DIR}/AnyKernel3"

DEFCONFIG="b1c1_defconfig"
JOBS=$(nproc --all)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# ──────────────────────────────────────────────
# STEP 0 — Cài dependencies (Arch Linux)
# ──────────────────────────────────────────────
install_deps() {
    step "Cài dependencies"
    sudo pacman -Syu --noconfirm --needed \
        base-devel git bc python flex bison \
        openssl libelf cpio rsync wget unzip \
        xmlto docbook-xsl kmod
    log "Dependencies OK"
}

# ──────────────────────────────────────────────
# STEP 1 — Clone kernel source
# ──────────────────────────────────────────────
clone_kernel() {
    step "Clone kernel source (${KERNEL_BRANCH})"
    if [ -d "${KERNEL_DIR}/.git" ]; then
        warn "Kernel source đã có, bỏ qua clone"
    else
        git clone "${KERNEL_REPO}" \
            -b "${KERNEL_BRANCH}" \
            --depth=1 \
            "${KERNEL_DIR}"
        log "Kernel cloned"
    fi
}

# ──────────────────────────────────────────────
# STEP 2 — Clone toolchain
# ──────────────────────────────────────────────
clone_toolchain() {
    step "Clone Toolchain (Clang + GCC)"
    mkdir -p "${BASE_DIR}/toolchain"

    if [ ! -d "${CLANG_DIR}" ]; then
        git clone https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
            -b master --depth=1 "${BASE_DIR}/toolchain/clang-repo"
        # Lấy clang version phù hợp
        CLANG_VER=$(ls "${BASE_DIR}/toolchain/clang-repo" | grep "clang-r" | sort -V | tail -1)
        ln -sf "${BASE_DIR}/toolchain/clang-repo/${CLANG_VER}" "${CLANG_DIR}"
        log "Clang: ${CLANG_VER}"
    else
        warn "Clang đã có"
    fi

    if [ ! -d "${GCC64_DIR}" ]; then
        git clone https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9 \
            --depth=1 "${GCC64_DIR}"
        log "GCC arm64 cloned"
    else
        warn "GCC arm64 đã có"
    fi

    if [ ! -d "${GCC32_DIR}" ]; then
        git clone https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/arm/arm-linux-androideabi-4.9 \
            --depth=1 "${GCC32_DIR}"
        log "GCC arm32 cloned"
    else
        warn "GCC arm32 đã có"
    fi
}

# ──────────────────────────────────────────────
# STEP 3 — Tích hợp KernelSU Next
# ──────────────────────────────────────────────
patch_ksu() {
    step "Tích hợp KernelSU Next"
    cd "${KERNEL_DIR}"

    if grep -q "KernelSU" "${KERNEL_DIR}/drivers/Makefile" 2>/dev/null; then
        warn "KSU Next đã được patch, bỏ qua"
        return
    fi

    curl -LSs "https://raw.githubusercontent.com/rifsxd/KernelSU-Next/${KSU_BRANCH}/kernel/setup.sh" | bash -s "${KSU_BRANCH}"
    log "KernelSU Next patched"
}

# ──────────────────────────────────────────────
# STEP 4 — Tích hợp SusFS
# ──────────────────────────────────────────────
patch_susfs() {
    step "Tích hợp SusFS"

    if [ ! -d "${SUSFS_DIR}" ]; then
        git clone https://gitlab.com/simonpunk/susfs4ksu \
            -b "${SUSFS_BRANCH}" --depth=1 "${SUSFS_DIR}"
    fi

    cd "${KERNEL_DIR}"

    if grep -q "susfs" "${KERNEL_DIR}/fs/Makefile" 2>/dev/null; then
        warn "SusFS đã patch, bỏ qua"
        return
    fi

    PATCH_FILE="${SUSFS_DIR}/kernel_patches/50_add_susfs_in_kernel-4.9.patch"
    if [ ! -f "${PATCH_FILE}" ]; then
        err "Không tìm thấy SusFS patch file: ${PATCH_FILE}"
    fi

    # Apply patch, cho phép fuzz
    patch -p1 --fuzz=3 < "${PATCH_FILE}" || {
        warn "Có reject file! Kiểm tra *.rej trong kernel dir"
        find . -name "*.rej" -exec echo "  Reject: {}" \;
        warn "Cần resolve thủ công các file trên rồi chạy lại"
        exit 1
    }

    log "SusFS patched"
}

# ──────────────────────────────────────────────
# STEP 5 — Cấu hình kernel
# ──────────────────────────────────────────────
configure_kernel() {
    step "Cấu hình kernel"
    cd "${KERNEL_DIR}"

    export PATH="${CLANG_DIR}/bin:${GCC64_DIR}/bin:${GCC32_DIR}/bin:${PATH}"

    MAKE_ARGS=(
        O="${OUT_DIR}"
        ARCH=arm64
        CC=clang
        CLANG_TRIPLE="aarch64-linux-gnu-"
        CROSS_COMPILE="aarch64-linux-android-"
        CROSS_COMPILE_ARM32="arm-linux-androideabi-"
        -j"${JOBS}"
    )

    make "${MAKE_ARGS[@]}" "${DEFCONFIG}"

    # Enable OverlayFS
    ./scripts/config --file "${OUT_DIR}/.config" \
        -e CONFIG_OVERLAY_FS \
        -e CONFIG_OVERLAY_FS_REDIRECT_DIR \
        -e CONFIG_OVERLAY_FS_INDEX

    # Enable KSU
    ./scripts/config --file "${OUT_DIR}/.config" \
        -e CONFIG_KSU \
        -e CONFIG_KSU_SUSFS

    make "${MAKE_ARGS[@]}" olddefconfig
    log "Config OK — OverlayFS + KSU + SusFS enabled"
}

# ──────────────────────────────────────────────
# STEP 6 — Build
# ──────────────────────────────────────────────
build_kernel() {
    step "Build kernel (jobs: ${JOBS})"
    cd "${KERNEL_DIR}"

    export PATH="${CLANG_DIR}/bin:${GCC64_DIR}/bin:${GCC32_DIR}/bin:${PATH}"

    MAKE_ARGS=(
        O="${OUT_DIR}"
        ARCH=arm64
        CC=clang
        CLANG_TRIPLE="aarch64-linux-gnu-"
        CROSS_COMPILE="aarch64-linux-android-"
        CROSS_COMPILE_ARM32="arm-linux-androideabi-"
        -j"${JOBS}"
    )

    START=$(date +%s)
    make "${MAKE_ARGS[@]}" 2>&1 | tee "${BASE_DIR}/build.log"

    IMG="${OUT_DIR}/arch/arm64/boot/Image.lz4-dtb"
    if [ ! -f "${IMG}" ]; then
        err "Build FAILED — xem build.log để debug"
    fi

    END=$(date +%s)
    ELAPSED=$(( END - START ))
    log "Build xong trong ${ELAPSED}s — $(ls -lh ${IMG} | awk '{print $5}')"
}

# ──────────────────────────────────────────────
# STEP 7 — Đóng gói AnyKernel3
# ──────────────────────────────────────────────
package_kernel() {
    step "Đóng gói AnyKernel3"

    if [ ! -d "${AK3_DIR}/.git" ]; then
        git clone https://github.com/osm0sis/AnyKernel3 "${AK3_DIR}" --depth=1
    fi

    IMG="${OUT_DIR}/arch/arm64/boot/Image.lz4-dtb"
    cp "${IMG}" "${AK3_DIR}/"

    # Tự động sửa anykernel.sh
    sed -i \
        -e 's/^kernel.string=.*/kernel.string=KSU-Next + SusFS | Pixel 3 (blueline)/' \
        -e 's/^device.name1=.*/device.name1=blueline/' \
        -e '/^device.name[2-9]/d' \
        "${AK3_DIR}/anykernel.sh"

    ZIP_NAME="pixel3_ksu-next_$(date +%Y%m%d_%H%M).zip"
    cd "${AK3_DIR}"
    zip -r9 "${BASE_DIR}/${ZIP_NAME}" . -x ".git/*" "README.md"

    log "Package: ${BASE_DIR}/${ZIP_NAME}"
}

# ──────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────
echo -e "${CYAN}"
echo "╔═══════════════════════════════════════╗"
echo "║   Pixel 3 Kernel Builder              ║"
echo "║   KSU Next + SusFS + OverlayFS        ║"
echo "╚═══════════════════════════════════════╝"
echo -e "${NC}"

case "${1:-all}" in
    deps)      install_deps ;;
    clone)     clone_kernel; clone_toolchain ;;
    patch)     patch_ksu; patch_susfs ;;
    config)    configure_kernel ;;
    build)     build_kernel ;;
    package)   package_kernel ;;
    all)
        install_deps
        clone_kernel
        clone_toolchain
        patch_ksu
        patch_susfs
        configure_kernel
        build_kernel
        package_kernel
        ;;
    *)
        echo "Usage: $0 [deps|clone|patch|config|build|package|all]"
        exit 1
        ;;
esac

echo -e "\n${GREEN}✓ Done!${NC}"
