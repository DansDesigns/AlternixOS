#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# install_tier.sh — Alternix Tier Package Installation
# Installs hardware-tier-appropriate packages into target
# ═══════════════════════════════════════════════════════════════

install_tier_packages() {
    section "Tier Packages"

    echo -e "  Installing ${W}Tier ${HW_TIER}${N} packages..."
    echo ""

    case $HW_TIER in
        1) _install_tier1 ;;
        2) _install_tier2 ;;
        3) _install_tier3 ;;
    esac
}

_chroot() {
    chroot "$ALTERNIX_MOUNT" /bin/bash -c "$*"
}

# ── Tier 1: Full stack (8 GB+) ────────────────────────────────────
_install_tier1() {
    info "Tier 1 — Full stack. Installing all Alternix components."
    echo ""

    local pkgs=(
        # Display
        "xorg"
        "xserver-xorg"
        "xinit"
        # Desktop env deps
        "python3"
        "python3-pip"
        "python3-venv"
        "python3-dev"
        "qt5-default"
        "python3-pyqt5"
        # Audio
        "pipewire"
        "pipewire-pulse"
        "wireplumber"
        "alsa-utils"
        # LLM / AI
        "git"
        "curl"
        "build-essential"
        "cmake"
        # Voice / STT / TTS deps
        "portaudio19-dev"
        "ffmpeg"
        "libavcodec-dev"
        "libavformat-dev"
        # System tools
        "htop"
        "neofetch"
        "lshw"
        "pciutils"
        "usbutils"
        "acpid"
        # Power management (no systemd)
        "pm-utils"
        "acpi"
        # Bluetooth
        "bluez"
        "blueman"
        # Fonts
        "fonts-noto"
        "fonts-liberation"
    )

    _do_install "${pkgs[@]}"
    _install_ollama
    ok "Tier 1 complete."
}

# ── Tier 2: Standard (4–8 GB) ─────────────────────────────────────
_install_tier2() {
    info "Tier 2 — Standard. Installing core Alternix components."
    echo ""

    local pkgs=(
        # Display
        "xorg"
        "xserver-xorg"
        "xinit"
        # Desktop deps
        "python3"
        "python3-pip"
        "python3-dev"
        "qt5-default"
        "python3-pyqt5"
        # Audio
        "pulseaudio"
        "alsa-utils"
        # LLM
        "git"
        "curl"
        "build-essential"
        # Voice deps
        "portaudio19-dev"
        "ffmpeg"
        # System tools
        "htop"
        "lshw"
        "pciutils"
        "acpid"
        "pm-utils"
        "acpi"
        # Fonts
        "fonts-noto"
        "fonts-liberation"
    )

    _do_install "${pkgs[@]}"
    _install_ollama
    ok "Tier 2 complete."
}

# ── Tier 3: Low-power (<4 GB) ─────────────────────────────────────
_install_tier3() {
    info "Tier 3 — Low-power. Installing minimal Alternix stack."
    info "Heavy compute will be forwarded to mesh nodes."
    echo ""

    local pkgs=(
        # Display
        "xorg"
        "xserver-xorg"
        "xinit"
        # Desktop deps (lightweight)
        "python3"
        "python3-pip"
        # Audio (minimal)
        "alsa-utils"
        # Mesh networking
        "git"
        "curl"
        "openssh-client"
        "openssh-server"
        # System tools
        "htop"
        "acpid"
        "pm-utils"
        # Fonts (minimal)
        "fonts-liberation"
    )

    _do_install "${pkgs[@]}"
    # No local Ollama on Tier 3 — uses mesh
    ok "Tier 3 complete."
}

_do_install() {
    local pkgs=("$@")

    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends ${pkgs[*]} 2>&1" | \
        while IFS= read -r line; do
            [[ "$line" == *"Unpacking"* || "$line" == *"Setting up"* ]] && \
                echo -e "  ${D}${line}${N}"
        done
}

_install_ollama() {
    info "Installing Ollama..."
    echo ""

    spin_start "Downloading Ollama..."

    local ollama_url
    case "$HW_ARCH" in
        x86_64)  ollama_url="https://github.com/ollama/ollama/releases/latest/download/ollama-linux-amd64.tgz" ;;
        aarch64) ollama_url="https://github.com/ollama/ollama/releases/latest/download/ollama-linux-arm64.tgz" ;;
        *)
            spin_stop
            warn "No Ollama binary for ${HW_ARCH}. Skipping."
            return 0
            ;;
    esac

    local tmp_tgz="/tmp/ollama.tgz"
    if wget -q -O "$tmp_tgz" "$ollama_url"; then
        spin_stop
        tar -xzf "$tmp_tgz" -C /tmp/
        install -m 755 /tmp/ollama "${ALTERNIX_MOUNT}/usr/local/bin/ollama" 2>/dev/null || \
        install -m 755 /tmp/bin/ollama "${ALTERNIX_MOUNT}/usr/local/bin/ollama" 2>/dev/null || true
        rm -f "$tmp_tgz"
        ok "Ollama installed."
    else
        spin_stop
        warn "Ollama download failed. Install manually post-boot."
    fi

    # OpenRC service for Ollama
    cat > "${ALTERNIX_MOUNT}/etc/init.d/ollama" << 'EOF'
#!/sbin/openrc-run
name="ollama"
description="Ollama LLM server"
command="/usr/local/bin/ollama"
command_args="serve"
command_background=true
pidfile="/run/ollama.pid"
output_log="/var/log/ollama.log"
error_log="/var/log/ollama.log"

depend() {
    need net
}
EOF
    chmod +x "${ALTERNIX_MOUNT}/etc/init.d/ollama"
    chroot "$ALTERNIX_MOUNT" rc-update add ollama default 2>/dev/null || true

    echo ""
}
