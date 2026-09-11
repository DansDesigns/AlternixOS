#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# hardware-detect.sh — Alternix Hardware Detection
# Detects arch, RAM, CPU, GPU
# ═══════════════════════════════════════════════════════════════

HW_ARCH=""
HW_RAM_MB=0
HW_CPU=""
HW_GPU=""

# Network hardware — see detect_network_hardware() below.
HW_WIFI_CHIP=""            # e.g. "ath10k", "iwlwifi", "brcm", "realtek", "none"
HW_WIFI_DESC=""            # human-readable description for logging/UI
HW_WIFI_FIRMWARE_PKGS=()   # Debian/Devuan package(s) that provide its firmware

detect_hardware() {
    # Architecture
    HW_ARCH=$(uname -m)
    case "$HW_ARCH" in
        x86_64)  HW_ARCH="x86_64" ;;
        aarch64) HW_ARCH="aarch64" ;;
        armv7*)  HW_ARCH="armv7" ;;
        *)       warn "Unknown architecture: ${HW_ARCH}" ;;
    esac

    # RAM (in MB)
    HW_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)

    # CPU model
    HW_CPU=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | \
        sed 's/.*: //' | sed 's/  */ /g' || echo "Unknown")

    # GPU (best-effort)
    if command -v lspci &>/dev/null; then
        HW_GPU=$(lspci 2>/dev/null | grep -i "vga\|3d\|display" | \
            head -1 | sed 's/.*: //' || echo "Unknown")
    else
        HW_GPU="Unknown (lspci unavailable)"
    fi

    detect_network_hardware
}

# ═══════════════════════════════════════════════════════════════
# Network hardware detection — DO NOT REMOVE
# Blindly installing every vendor's firmware package and hoping one of
# them matches is how a missing firmware directory (ath10k on one
# machine, brcm80211 on another) went unnoticed until wifi was tested
# on real hardware. This looks at what's actually in the machine (PCI,
# USB, SDIO) and records which firmware package that hardware actually
# needs, so install_base.sh can verify — and if necessary, specifically
# retry — the ONE package that matters for THIS machine, instead of a
# generic check across every vendor's directory.
# ═══════════════════════════════════════════════════════════════
detect_network_hardware() {
    HW_WIFI_CHIP=""
    HW_WIFI_DESC=""
    HW_WIFI_FIRMWARE_PKGS=()

    local pci_net usb_net sdio_ids
    pci_net=$(lspci -nn 2>/dev/null | grep -iE "network controller|ethernet controller|wireless")
    usb_net=$(lsusb 2>/dev/null)
    sdio_ids=""
    if [[ -d /sys/bus/sdio/devices ]]; then
        sdio_ids=$(cat /sys/bus/sdio/devices/*/modalias 2>/dev/null)
    fi

    # Qualcomm Atheros — ath10k (QCA6174/9377 etc, PCI) or ath9k (older, PCI)
    if echo "$pci_net" | grep -qi "qualcomm atheros"; then
        HW_WIFI_CHIP="ath10k"
        HW_WIFI_DESC=$(echo "$pci_net" | grep -i "qualcomm atheros" | head -1 | sed 's/.*: //')
        HW_WIFI_FIRMWARE_PKGS+=("firmware-atheros")
    fi

    # Broadcom — brcmfmac, almost always SDIO on tablets (won't show in
    # lspci at all), sometimes PCIe/USB on laptops.
    if echo "$sdio_ids" | grep -qi "brcm" || \
       echo "$pci_net$usb_net" | grep -qi "broadcom"; then
        HW_WIFI_CHIP="brcm"
        HW_WIFI_DESC="Broadcom (SDIO/PCIe/USB) WiFi+BT combo"
        HW_WIFI_FIRMWARE_PKGS+=("firmware-brcm80211" "bluez-firmware")
    fi

    # Intel — iwlwifi (PCI)
    if echo "$pci_net" | grep -qiE "intel.*(wireless|wifi|centrino)"; then
        HW_WIFI_CHIP="iwlwifi"
        HW_WIFI_DESC=$(echo "$pci_net" | grep -i "intel" | head -1 | sed 's/.*: //')
        HW_WIFI_FIRMWARE_PKGS+=("firmware-iwlwifi")
    fi

    # Realtek — rtlwifi/rtw88/rtw89 (PCI or USB)
    if echo "$pci_net$usb_net" | grep -qiE "realtek.*(802\.11|wireless|wifi|rtl8[0-9]+[a-z]*)"; then
        HW_WIFI_CHIP="realtek"
        HW_WIFI_DESC=$(echo "$pci_net$usb_net" | grep -i "realtek" | head -1 | sed 's/.*: //')
        HW_WIFI_FIRMWARE_PKGS+=("firmware-realtek")
    fi

    if [[ -z "$HW_WIFI_CHIP" ]]; then
        HW_WIFI_CHIP="none"
        HW_WIFI_DESC="No WiFi hardware detected"
    fi

    # Dedupe package list (Broadcom entries can repeat across checks)
    if [[ ${#HW_WIFI_FIRMWARE_PKGS[@]} -gt 0 ]]; then
        mapfile -t HW_WIFI_FIRMWARE_PKGS < <(printf '%s\n' "${HW_WIFI_FIRMWARE_PKGS[@]}" | sort -u)
    fi
}

show_hardware() {
    section "Hardware"

    echo -e "  ${D}Architecture${N}   ${W}${HW_ARCH}${N}"
    echo -e "  ${D}RAM${N}            ${W}${HW_RAM_MB} MB${N}"
    echo -e "  ${D}CPU${N}            ${W}${HW_CPU}${N}"
    echo -e "  ${D}GPU${N}            ${W}${HW_GPU}${N}"
    echo -e "  ${D}WiFi${N}           ${W}${HW_WIFI_DESC}${N}"
    echo ""

}

# Probe whether the installed gcc can actually handle -march=native on
# this specific CPU. On some Atom-family chips (Bay Trail/Cherry Trail —
# Bonnell/Silvermont/Airmont cores, common in cheap tablets) native's
# CPUID-based autodetection hands back a -march= value the ISO's gcc is
# too old to recognize, and the very first compile unit fails outright.
_cc_supports_march_native() {
    command -v gcc &>/dev/null || return 1
    echo 'int main(void){return 0;}' | \
        gcc -march=native -O2 -x c -o /dev/null - >/dev/null 2>&1
}

# Compile flags based on arch
get_compile_flags() {
    local flags=""
    case "$HW_ARCH" in
        x86_64)
            if _cc_supports_march_native; then
                flags="-march=native -O2"
            else
                warn "gcc doesn't recognize this CPU's exact microarchitecture (common on Atom/Bay Trail tablets) — building with a generic x86_64 baseline instead of -march=native."
                flags="-mtune=generic -O2"
            fi
            ;;
        aarch64)
            if _cc_supports_march_native; then
                flags="-march=native -O2"
            else
                flags="-O2"
            fi
            ;;
        armv7)
            flags="-march=armv7-a -mfpu=neon -mfloat-abi=hard -O2"
            ;;
    esac
    echo "$flags"
}
