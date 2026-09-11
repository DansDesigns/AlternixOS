#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# build_sel4.sh — Alternix seL4 Microkernel Build
# ═══════════════════════════════════════════════════════════════

SEL4_VERSION="HEAD"
SEL4_REPO="https://github.com/seL4/seL4.git"
# BUILD DIR ON TARGET DISK — DO NOT REVERT TO /tmp
# /tmp on the live environment is a RAM-backed tmpfs overlay (default
# ~50% of physical RAM, per live-boot). A full seL4 clone + cmake + ninja
# build easily fills that on low-RAM tablets (e.g. Atom-based devices
# with ~4GB RAM -> ~1.9GB overlay), causing "No space left on device"
# mid-build even though the target disk has plenty of room. Building
# directly on ALTERNIX_MOUNT keeps it on the real disk instead.
SEL4_BUILD_DIR="${ALTERNIX_MOUNT}/tmp/sel4-build"
SEL4_INSTALL_DIR="${ALTERNIX_MOUNT}/opt/sel4"
SEL4_LOG="${ALTERNIX_MOUNT}/tmp/sel4-cmake.log"

build_sel4() {
    section "seL4 Microkernel"

    # SEL4_LOG and SEL4_BUILD_DIR now live under ALTERNIX_MOUNT (target disk,
    # not the live RAM overlay) — make sure the directory exists first.
    mkdir -p "${ALTERNIX_MOUNT}/tmp"

    echo -e "  ${D}Arch:${N}  ${W}${HW_ARCH}${N}"
    echo -e "  ${D}Log:${N}   ${W}${SEL4_LOG}${N}"
    echo ""
    warn "This step takes 15-25 minutes."
    echo ""

    # Run each step — failure is non-fatal, install continues
    _install_build_deps  || { warn "seL4 dep install had issues — continuing anyway."; }
    _clone_sel4          || { warn "seL4 clone failed — skipping seL4."; return 0; }
    _build_sel4          || { warn "seL4 build failed — continuing without seL4."; return 0; }
    _install_sel4

    ok "seL4 built and installed."
}

_install_build_deps() {
    step 1 4 "Installing build dependencies..."
    echo ""

    # Update apt cache first
    info "Updating apt cache..."
    apt-get update 2>>"$SEL4_LOG" || true

    # Install build tools — these should already be in the live ISO
    # but apt-get install is a no-op if already present
    info "Ensuring build tools are present..."
    apt-get install -y --no-install-recommends         git cmake ninja-build gcc g++ make         python3 python3-pip python3-dev         python3-yaml python3-jinja2 python3-ply python3-lxml         libxml2-utils device-tree-compiler         2>>"$SEL4_LOG" || true
    # Not fatal if some packages fail — they may already be installed

    # Verify python3 is now available
    if ! command -v python3 &>/dev/null; then
        err "python3 still not found after apt-get install."
        err "Cannot build seL4 without python3."
        return 1
    fi
    ok "python3 found: $(python3 --version 2>&1)"

    # Python packages seL4 needs
    info "Installing Python packages..."
    pip3 install --break-system-packages         guardonce sel4-deps pyfdt plyplus 2>>"$SEL4_LOG" ||     pip3 install         guardonce sel4-deps pyfdt plyplus 2>>"$SEL4_LOG" || true

    # Log what we have
    echo "=== Python dep check ===" >> "$SEL4_LOG"
    python3 -c "
import sys
for mod in ['yaml','jinja2','guardonce','pyfdt']:
    try:
        m = __import__(mod)
        print(f'  {mod}: OK')
    except ImportError:
        print(f'  {mod}: MISSING')
" 2>&1 | tee -a "$SEL4_LOG" | while IFS= read -r l; do info "$l"; done

    ok "Build deps done."
    echo ""
}

_clone_sel4() {
    step 2 4 "Cloning seL4..."
    echo ""

    rm -rf "$SEL4_BUILD_DIR"
    mkdir -p "$SEL4_BUILD_DIR"

    spin_start "Cloning seL4..."

    echo "=== git clone ===" >> "$SEL4_LOG"

    local cloned=0
    # Try HEAD first (supports newer cmake), then versioned tags
    for attempt in "HEAD" "12.1.0" "12.0.0"; do
        if [[ "$attempt" == "HEAD" ]]; then
            git clone --depth=1 "$SEL4_REPO" "${SEL4_BUILD_DIR}/seL4" \
                >>"$SEL4_LOG" 2>&1 && { SEL4_VERSION="HEAD"; cloned=1; break; }
        else
            git clone --depth=1 --branch "$attempt" "$SEL4_REPO" "${SEL4_BUILD_DIR}/seL4" \
                >>"$SEL4_LOG" 2>&1 && { SEL4_VERSION="$attempt"; cloned=1; break; }
        fi
        rm -rf "${SEL4_BUILD_DIR}/seL4"
    done

    spin_stop

    if [[ $cloned -eq 0 ]]; then
        echo "All clone attempts failed" >> "$SEL4_LOG"
        return 1
    fi

    ok "seL4 cloned (${SEL4_VERSION})."
    echo ""
}

_build_sel4() {
    step 3 4 "Building seL4..."
    echo ""

    local build_dir="${SEL4_BUILD_DIR}/build"
    mkdir -p "$build_dir"

    # Map arch
    local sel4_arch sel4_platform
    case "$HW_ARCH" in
        x86_64)  sel4_arch="x86_64"; sel4_platform="pc99" ;;
        aarch64) sel4_arch="aarch64"; sel4_platform="rpi4" ;;
        armv7*)  sel4_arch="arm";    sel4_platform="rpi3" ;;
        *)  warn "Unsupported arch ${HW_ARCH}"; return 1 ;;
    esac

    local cflags
    cflags=$(get_compile_flags)

    echo "=== cmake ===" >> "$SEL4_LOG"
    echo "arch=$sel4_arch platform=$sel4_platform flags=$cflags" >> "$SEL4_LOG"

    info "Running cmake... (streaming to ${SEL4_LOG})"
    info "Errors will appear below:"
    echo ""

    # Run cmake and show ALL output — no filtering
    (
        cd "$build_dir"
        cmake \
            -G Ninja \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_FLAGS="${cflags}" \
            -DKernelArch="${sel4_arch}" \
            -DKernelPlatform="${sel4_platform}" \
            -DKernelVerificationBuild=OFF \
            -DKernelPrinting=ON \
            -Wno-dev \
            "${SEL4_BUILD_DIR}/seL4" 2>&1
    ) | tee -a "$SEL4_LOG"

    echo "" >> "$SEL4_LOG"

    if [[ ! -f "${build_dir}/build.ninja" ]]; then
        echo "FAILED: build.ninja not created" >> "$SEL4_LOG"
        err "seL4 cmake failed — see ${SEL4_LOG}"
        return 1
    fi

    ok "cmake done. Building with ninja..."
    echo ""

    echo "=== ninja ===" >> "$SEL4_LOG"

    (
        cd "$build_dir"
        ninja 2>&1
    ) | tee -a "$SEL4_LOG" | while IFS= read -r line; do
        [[ "$line" == "["* ]] && echo -e "  ${D}${line}${N}"
    done

    # Check ninja result from log
    if cat "$SEL4_LOG" | grep -q "FAILED\|Error\|error:"; then
        err "seL4 ninja build failed — see ${SEL4_LOG}"
        return 1
    fi

    ok "seL4 compiled."
    echo ""
}

_install_sel4() {
    step 4 4 "Installing seL4..."
    echo ""

    mkdir -p "$SEL4_INSTALL_DIR"

    local kernel_img
    kernel_img=$(find "${SEL4_BUILD_DIR}/build" -name "kernel.elf" 2>/dev/null | head -1)
    [[ -z "$kernel_img" ]] && \
        kernel_img=$(find "${SEL4_BUILD_DIR}/build" -name "kernel" 2>/dev/null | head -1)

    if [[ -n "$kernel_img" ]]; then
        cp "$kernel_img" "${SEL4_INSTALL_DIR}/kernel.elf"
        ok "Kernel → /opt/sel4/kernel.elf"
    else
        warn "kernel.elf not found in build output."
    fi

    [[ -d "${SEL4_BUILD_DIR}/seL4/libsel4/include" ]] && \
        cp -r "${SEL4_BUILD_DIR}/seL4/libsel4/include" "${SEL4_INSTALL_DIR}/include"

    cat > "${SEL4_INSTALL_DIR}/VERSION" << EOF
seL4 ${SEL4_VERSION}
Built by Alternix installer
Arch: ${HW_ARCH}
Flags: $(get_compile_flags)
EOF

    rm -rf "$SEL4_BUILD_DIR"
    ok "seL4 installed to /opt/sel4/"
}
