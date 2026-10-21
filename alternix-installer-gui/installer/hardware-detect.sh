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

# Power-supply detection shared by the text display and pre-erase guard.
# Firmware on tablets often uses names like axp288_fuel_gauge, bq27xxx-0,
# or intel-battery rather than BAT0; sysfs "type" is authoritative.
# If the kernel does not expose a battery device, do NOT assume AC power:
# a USB hub/network dongle can be connected without charging the tablet.
HW_BATTERY_FOUND=0
HW_BATTERY_PCT=""
HW_BATTERY_STATUS=""
HW_MAINS_ONLINE=0
HW_CHARGING=0

_scan_power_supplies() {
    local root="${1:-/sys/class/power_supply}"
    local supply typ name present status pct now full online raw
    local battery=0
    HW_BATTERY_FOUND=0
    HW_BATTERY_PCT=""
    HW_BATTERY_STATUS=""
    HW_MAINS_ONLINE=0
    HW_CHARGING=0

    for supply in "$root"/*; do
        [[ -d "$supply" ]] || continue  # sysfs devices are usually symlinks
        typ=""; status=""; pct=""; present=""; online=""
        [[ -r "$supply/type" ]] && IFS= read -r typ < "$supply/type"
        if [[ -z "$typ" && -r "$supply/uevent" ]]; then
            raw=$(grep -m1 '^POWER_SUPPLY_TYPE=' "$supply/uevent" 2>/dev/null || true)
            typ=${raw#POWER_SUPPLY_TYPE=}
        fi
        typ=${typ,,}
        name=${supply##*/}; name=${name,,}

        if [[ "$typ" == mains ]]; then
            [[ -r "$supply/online" ]] && IFS= read -r online < "$supply/online"
            [[ "$online" == 1 ]] && HW_MAINS_ONLINE=1
            continue
        fi
        # USB/USB-C 'online' alone is NOT proof of a wall charger. The
        # kernel may report a connected data hub or peripheral as online.
        case "$typ" in
            usb|usb_*|wireless) continue ;;
        esac
        [[ -r "$supply/present" ]] && IFS= read -r present < "$supply/present"
        [[ "$present" == 0 ]] && continue

        [[ -r "$supply/status" ]] && IFS= read -r status < "$supply/status"
        [[ -r "$supply/capacity" ]] && IFS= read -r pct < "$supply/capacity"
        [[ "$pct" =~ ^[0-9]+$ ]] && (( 10#$pct <= 100 )) || pct=""

        battery=0
        if [[ "$typ" == battery ]]; then
            battery=1
        elif [[ -z "$typ" || "$typ" == unknown ]]; then
            # Fallback for incomplete firmware: require battery-like
            # readings rather than trusting an arbitrary device name.
            if [[ -n "$status" && -n "$pct" ]] ||
               { [[ -r "$supply/energy_now" && -r "$supply/energy_full" ]] ||
                 [[ -r "$supply/charge_now" && -r "$supply/charge_full" ]]; }; then
                battery=1
            elif [[ "$name" == *battery* || "$name" == bat[0-9]* ||
                    "$name" == *fuel*gauge* ]] && [[ -n "$pct" || -n "$status" ]]; then
                battery=1
            fi
        fi
        (( battery )) || continue
        HW_BATTERY_FOUND=1

        if [[ -z "$pct" ]]; then
            # Some tablets omit capacity but expose charge/energy counters.
            for raw in energy charge; do
                now=""; full=""
                [[ -r "$supply/${raw}_now" ]] && IFS= read -r now < "$supply/${raw}_now"
                [[ -r "$supply/${raw}_full" ]] && IFS= read -r full < "$supply/${raw}_full"
                pct=$(awk -v n="$now" -v f="$full" 'BEGIN {
                    if (n ~ /^[0-9]+$/ && f ~ /^[0-9]+$/ && f > 0) {
                        p=int(n*100/f+0.5); if (p>100) p=100; print p
                    }
                }')
                [[ -n "$pct" ]] && break
            done
        fi

        # Keep the LOWEST percentage across multiple battery packs.
        # An unknown capacity never erases a valid earlier reading.
        if [[ -n "$pct" ]] && { [[ -z "$HW_BATTERY_PCT" ]] ||
           (( pct < HW_BATTERY_PCT )); }; then
            HW_BATTERY_PCT=$pct
            HW_BATTERY_STATUS=$status
        elif [[ -z "$HW_BATTERY_STATUS" ]]; then
            HW_BATTERY_STATUS=$status
        fi
        [[ "${status,,}" == charging ]] && HW_CHARGING=1
    done

    # An explicitly discharging battery overrides ambiguous power reports.
    # A real mains power supply can also make installation safe when the
    # battery is intentionally not charging (e.g. charge threshold).
    if [[ "${HW_BATTERY_STATUS,,}" == discharging ]]; then
        HW_MAINS_ONLINE=0
    fi
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
