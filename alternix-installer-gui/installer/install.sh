#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# install.sh — Alternix Net Installer
#
# Flow:
#   welcome → hardware → network → user config → disk →
#   base install → seL4 → desktop → system config →
#   bootloader → done
#
# Requires: root, internet connection, 8 GB+ free disk
# ═══════════════════════════════════════════════════════════════

set -uo pipefail
# Note: -e intentionally omitted — each stage handles its own errors
# so a non-fatal warning doesn't kill the whole installer.

# Check if user deliberately dropped to shell — do not restart
if [[ -f /tmp/.alternix-shell-drop ]]; then
    # Stay silent — the shell is already running
    exit 0
fi

# Prevent re-entry if already running
if [[ -f /tmp/.alternix-installer-running ]]; then
    echo ""
    echo "Installer already ran. Type: install   to restart."
    exit 0
fi
touch /tmp/.alternix-installer-running

# Easy restart alias — just type: install
cat > /usr/local/bin/install << 'ALIAS'
#!/bin/bash
rm -f /tmp/.alternix-installer-running
exec bash /installer/install.sh
ALIAS
chmod +x /usr/local/bin/install

# Ctrl+C drops to shell cleanly — kill spinner then exit to shell
trap '_alternix_interrupted' INT

_alternix_interrupted() {
    spin_stop 2>/dev/null || true
    echo ""
    echo ""
    echo -e "  ${Y}Installer interrupted.${N}"
    echo -e "  Type ${W}install${N} to restart."
    rm -f /tmp/.alternix-installer-running
    trap - INT EXIT
    # Return to shell by ending this script without re-exec
    exit 0
}

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ALTERNIX_MOUNT="/mnt/alternix"
export ALTERNIX_LOG="/tmp/alternix-install.log"

# Tee all output to log file so errors are never lost
exec > >(tee -a "$ALTERNIX_LOG") 2>&1
echo "=== Alternix Installer started $(date) ==="

# Stop kernel messages (e.g. PCIe AER spam) flooding the installer TUI
dmesg -n 1 2>/dev/null || true

# Flag to suppress screen clear after errors
ALTERNIX_ERROR_SHOWN=0

# ── Source modules ────────────────────────────────────────────────
source "${INSTALLER_DIR}/ui.sh"
export ALTERNIX_ERROR_COUNT=0


source "${INSTALLER_DIR}/hardware-detect.sh"
source "${INSTALLER_DIR}/network.sh"
source "${INSTALLER_DIR}/partition.sh"
source "${INSTALLER_DIR}/install_base.sh"
source "${INSTALLER_DIR}/install_copy.sh"
source "${INSTALLER_DIR}/install_optional.sh"
source "${INSTALLER_DIR}/configure_system.sh"
source "${INSTALLER_DIR}/install_desktop.sh"

# UNATTENDED CONFIG — DO NOT MOVE ABOVE THE SOURCES
# osm-install writes this file, then runs this script. It must be
# sourced AFTER the modules, because each module sets its own
# defaults at the top of the file and would otherwise clobber it.
# When the file is absent every prompt below behaves exactly as
# it always has, so the text installer is unaffected.
if [[ -f /tmp/alternix-install.conf ]]; then
    # shellcheck source=/dev/null
    source /tmp/alternix-install.conf
fi

# ── Root check ────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root: sudo bash install.sh"
    exit 1
fi

# ── Trap: cleanup mounts on unexpected exit ───────────────────────
trap '_on_exit' EXIT

_show_menu() {
    local title="${1:-What would you like to do?}"
    echo ""
    echo "$title"
    echo ""
    echo "  1  Restart installer"
    echo "  2  Drop to shell"
    echo "  3  Shutdown"
    echo "  4  Reboot"
    echo "  5  View logs"
    echo ""
}

_alternix_pager() {
    # Pure-bash scrollable pager — no less/more needed.
    # Use the whole screen: release the banner scroll region first.
    printf '\033[r' 
    # Keys: Up/Down arrows, PgUp/PgDn, Home/End, q to quit.
    local file="$1"
    local -a plines
    mapfile -t plines < "$file"
    local total=${#plines[@]}
    local rows=$(( $(stty size 2>/dev/null | cut -d' ' -f1 || echo 24) - 2 ))
    (( rows < 5 )) && rows=22
    local max_top=$(( total - rows ))
    (( max_top < 0 )) && max_top=0
    # Start at the END — the most recent output is what matters
    local top=$max_top

    while true; do
        clear
        local i
        for (( i=top; i<top+rows && i<total; i++ )); do
            printf '%s\n' "${plines[$i]}"
        done
        printf '\033[7m -- line %d-%d of %d  [arrows/PgUp/PgDn/Home/End scroll, q quit] --\033[0m' \
            $((top+1)) $(( top+rows<total ? top+rows : total )) "$total"

        IFS= read -rsn1 key
        if [[ "$key" == $'\033' ]]; then
            read -rsn2 -t 0.05 key2
            case "$key2" in
                '[A') (( top>0 )) && (( top-- )) ;;                    # Up
                '[B') (( top<max_top )) && (( top++ )) ;;              # Down
                '[5') read -rsn1 -t 0.05 _; top=$(( top-rows ));       # PgUp
                      (( top<0 )) && top=0 ;;
                '[6') read -rsn1 -t 0.05 _; top=$(( top+rows ));       # PgDn
                      (( top>max_top )) && top=$max_top ;;
                '[H') top=0 ;;                                         # Home
                '[F') top=$max_top ;;                                  # End
            esac
        elif [[ "$key" == "q" || "$key" == "Q" ]]; then
            break
        elif [[ -z "$key" ]]; then
            # ENTER: scroll one line
            (( top<max_top )) && (( top++ ))
        fi
    done
    clear
}

_show_logs() {
    local tmp="/tmp/.alternix-logview"
    {
        echo "=== /tmp/alternix-install.log ==="
        cat /tmp/alternix-install.log 2>/dev/null || echo "(no install log)"
        # seL4 build log now lives on the target disk (ALTERNIX_MOUNT), not
        # the live overlay's /tmp — see build_sel4.sh. Fall back to the
        # old /tmp path too, in case this runs before ALTERNIX_MOUNT is set.
        local sel4log="${ALTERNIX_MOUNT:-}/tmp/sel4-cmake.log"
        [[ -s "$sel4log" ]] || sel4log="/tmp/sel4-cmake.log"
        if [ -s "$sel4log" ]; then
            echo ""
            echo "=== ${sel4log} ==="
            cat "$sel4log"
        fi
    } > "$tmp"
    _alternix_pager "$tmp"
    rm -f "$tmp"
}

_on_exit() {
    local code=$?
    rm -f /tmp/.alternix-installer-running
    # The GUI launches this script with stdin closed. Any interactive
    # recovery menu here would loop forever instead of reporting failure
    # to QProcess. Preserve logs and return the actual nonzero status.
    if [[ $code -ne 0 && "${ALTERNIX_UNATTENDED:-0}" -eq 1 ]]; then
        echo "INSTALL FAILED (exit ${code}); see ${ALTERNIX_LOG}" >&2
        if mountpoint -q "${ALTERNIX_MOUNT:-/mnt/alternix}" 2>/dev/null; then
            local failed_dir="${ALTERNIX_MOUNT}/var/log/alternix-install"
            mkdir -p "$failed_dir" 2>/dev/null || true
            cp "${ALTERNIX_LOG}" "${failed_dir}/failed-install.log" 2>/dev/null || true
        fi
        if [[ -x "${INSTALLER_DIR}/alternix-media" ]]; then
            bash "${INSTALLER_DIR}/alternix-media" savelog >/dev/null 2>&1 || true
        fi
        trap - EXIT
        exit "$code"
    fi
    if [[ $code -ne 0 ]]; then
        ALTERNIX_ERROR_SHOWN=1
        spin_stop 2>/dev/null || true
        echo ""
        echo -e "\033[0;31m╔══════════════════════════════════════════════════╗\033[0m"
        echo -e "\033[0;31m║  INSTALLER ERROR — exit code ${code}                \033[0m"
        echo -e "\033[0;31m╚══════════════════════════════════════════════════╝\033[0m"
        echo ""
        err "Installer exited unexpectedly (code ${code})."
        echo ""
        # Show last 25 lines of log immediately on screen
        if [[ -f "$ALTERNIX_LOG" ]]; then
            echo -e "  ${Y}=== Last 25 lines of install log ===${N}"
            echo ""
            cat "$ALTERNIX_LOG" | while IFS= read -r l; do echo "  $l"; done
            echo ""
        fi
        info "Cleaning up mounts..."
        cleanup_mounts 2>/dev/null || true
        echo ""
        echo -e "  ${T}Full log: ${ALTERNIX_LOG}${N}"
        echo ""

        _show_menu
        while true; do
            echo -en "  ${W}Choice${N}: "
            IFS= read -r choice
            case "$choice" in
                1) rm -f /tmp/.alternix-installer-running; exec bash /installer/install.sh ;;
                2) rm -f /tmp/.alternix-installer-running
                   touch /tmp/.alternix-shell-drop
                   echo ""
                   echo " Alternix Shell — type: install  to restart"
                   echo ""
                   printf '\033[r'
           env PS1="[alternix]: " /bin/bash --norc -i
                   rm -f /tmp/.alternix-shell-drop
                   exit 0 ;;
                3) printf '\033[r'; sync; /sbin/poweroff -f ;;
                4) printf '\033[r'; sync; /sbin/reboot -f ;;
                5) _show_logs
                   # Redraw menu after returning from logs
                   echo ""
                   echo -e "  ${W}What would you like to do?${N}"
                   echo ""
                   echo -e "  ${T}1${N}  Restart installer"
                   echo -e "  ${T}2${N}  Drop to shell"
                   echo -e "  ${T}3${N}  Shutdown"
                   echo -e "  ${T}4${N}  Reboot"
                   echo -e "  ${T}5${N}  View logs"
                   echo "" ;;
                ""|$'
') ;;
                *) warn "Enter 1-5." ;;
            esac
        done
    fi
}

# ════════════════════════════════════════════════════════════════
# STAGE 1: Welcome
# ════════════════════════════════════════════════════════════════
banner

# Console font — asked FIRST, before anything else, so the rest of
# the installer is readable on high-DPI/touchscreen displays.
[[ "${ALTERNIX_UNATTENDED:-0}" -eq 1 ]] || select_font_size
banner

# UNATTENDED GUARD — THIS BLOCK IS WHY THE GUI STALLED
# Everything from here to the end of the confirm is a repeat of what
# osm-install already asked. Worse, `confirm` blocks on stdin, which
# under the GUI is a closed pipe, so the install sat forever at a
# prompt the user could not see or answer.
if [[ "${ALTERNIX_UNATTENDED:-0}" -ne 1 ]]; then

echo -e "  ${W}Welcome to Alternix.${N}"
echo ""
echo -e "  This installer will:"
echo ""
echo -e "    ${T}1${N}  Detect your hardware"
echo -e "    ${T}2${N}  Connect to the internet"
echo -e "    ${T}3${N}  Collect your preferences (user, disk, locale)"
echo -e "    ${T}4${N}  Partition and format your disk"
echo -e "    ${T}5${N}  Install Devuan base + OpenRC (no systemd)"
echo -e "    ${T}6${N}  Build the seL4 microkernel"
echo -e "    ${T}7${N}  Install your chosen desktop environment"
echo -e "    ${T}8${N}  Configure and boot"
echo ""
echo -e "  ${D}Estimated time:  30–50 minutes (seL4 build included)${N}"
echo -e "  ${D}Requires:        internet connection · 8 GB+ free disk${N}"
echo ""

if ! confirm "Begin installation?"; then
    echo ""
    echo -e "  ${W}What would you like to do?${N}"
    echo ""
    echo -e "  ${T}1${N}  Restart installer"
    echo -e "  ${T}2${N}  Drop to shell"
    echo -e "  ${T}3${N}  Shutdown"
    echo -e "  ${T}4${N}  Reboot"
    echo -e "  ${T}5${N}  View logs"
    echo ""
    while true; do
        echo -en "  ${W}Choice${N}: "
        IFS= read -r choice
        case "$choice" in
            1) rm -f /tmp/.alternix-installer-running; exec bash /installer/install.sh ;;
            2) rm -f /tmp/.alternix-installer-running
               echo -e "  Type ${W}install${N} to restart."
               trap - INT EXIT; exit 0 ;;
            3) printf '\033[r'; sync; /sbin/poweroff -f ;;
            4) printf '\033[r'; sync; /sbin/reboot -f ;;
            5) _show_logs
               echo ""
               echo -e "  ${W}What would you like to do?${N}"
               echo ""
               echo -e "  ${T}1${N}  Restart installer"
               echo -e "  ${T}2${N}  Drop to shell"
               echo -e "  ${T}3${N}  Shutdown"
               echo -e "  ${T}4${N}  Reboot"
               echo -e "  ${T}5${N}  View logs"
               echo "" ;;
            *) warn "Enter 1-5." ;;
        esac
    done
fi

fi   # end unattended guard

# ════════════════════════════════════════════════════════════════
# STAGE 2: Hardware Detection
# ════════════════════════════════════════════════════════════════
detect_hardware
show_hardware

[[ "${ALTERNIX_UNATTENDED:-0}" -eq 1 ]] || press_any_key

# ════════════════════════════════════════════════════════════════
# STAGE 3: Network
# ════════════════════════════════════════════════════════════════
banner
progress_set 1 "Network"
banner
# A graphical install of the prebuilt Alternix image needs neither a
# network scan nor online time-sync. The GUI can set up Wi-Fi separately;
# installed NetworkManager lets the user connect after first boot.
# Other desktops and selected optional network components retain networking.
# GUI cannot answer an interactive network prompt, so fail before erasure if
# an online-only selection has no connection. Prebuilt Alternix is exempt.
if [[ "${ALTERNIX_UNATTENDED:-0}" -eq 1 ]] && \
   { [[ "${ALTERNIX_DESKTOP:-}" != alternix ]] || \
     [[ -n "${ALTERNIX_OPTIONAL:-}" ]] || \
     [[ "${ALTERNIX_TELEPHONY:-2}" != 2 ]] || \
     [[ "$(cat /etc/alternix/iso-mode 2>/dev/null)" != live-preview ]]; }; then
    if ! timeout 10 bash "${INSTALLER_DIR}/alternix-net" status >/dev/null 2>&1; then
        die "This selection needs Internet. Offline installation is supported for prebuilt Alternix without optional downloads."
    fi
fi
if [[ "${ALTERNIX_UNATTENDED:-0}" -eq 1 && \
      "${ALTERNIX_DESKTOP:-}" == alternix && \
      -s /etc/alternix/de-baked && \
      -z "${ALTERNIX_OPTIONAL:-}" && \
      "${ALTERNIX_TELEPHONY:-2}" == 2 ]]; then
    info "Prebuilt image install: skipping unnecessary network downloads and scanning."
else
    setup_network
    # Fix wrong RTC before any TLS (git/apt) — see net_sync_clock
    net_sync_clock
fi

# ════════════════════════════════════════════════════════════════
# STAGE 4: Gather config (user + disk preferences)
# before touching anything on disk
# ════════════════════════════════════════════════════════════════
banner
progress_set 2 "User config"
banner
[[ -n "${ALTERNIX_USERNAME:-}" ]] || gather_user_config

# ════════════════════════════════════════════════════════════════
# STAGE 4b: Desktop selection
# MOVED UP — DO NOT MOVE BACK
# This used to run at stage 9b, after the base system and system
# config were already done. That is roughly forty minutes into an
# install, so an unattended run would stop and wait for input long
# after the user walked away. Asking here keeps every question in
# the first two minutes. install_desktop still runs at stage 9b.
# ════════════════════════════════════════════════════════════════
select_desktop

# PRE-ERASE GUARD — both build profiles are explicit. The live-preview
# MUST contain a complete desktop, while net-install deliberately does not.
# For net-install check GitHub *before* changing the disk, since the
# selected desktop is downloaded and built on the target from Git.
ALTERNIX_ISO_MODE=$(cat /etc/alternix/iso-mode 2>/dev/null || echo live-preview)
if [[ "${ALTERNIX_DESKTOP:-}" == "alternix" && "${ALTERNIX_FORCE_DEBOOTSTRAP:-0}" != 1 ]]; then
    _find_squashfs || die "No bundled live rootfs: refusing to erase the target disk. Rebuild the ISO."
    case "$ALTERNIX_ISO_MODE" in
        live-preview)
            if [[ ! -s /etc/alternix/de-baked || -f /etc/alternix/de-missing ]] || \
               [[ ! -x /usr/local/bin/osm-launcher ]]; then
                die "Live-preview desktop was not fully prebuilt. Refusing to erase the disk."
            fi
            # The image must include the user assets in /etc/skel, not
            # just system binaries in /usr/local/bin. Refuse to erase a
            # disk if the root-built home wasn't staged for new users.
            for required in \
                .alternix-prebuilt-home \
                .config/qtile/config.py \
                .config/Alternix/sounds \
                .local/share/applications/breakout.desktop \
                Pictures/wallpapers \
                extras/games/breakout.html; do
                [[ -e "/etc/skel/$required" ]] || \
                    die "Incomplete live-preview user assets: /etc/skel/$required is missing."
            done
            ALTERNIX_PREBUILT_INSTALL=1
            info "Prebuilt AlternixDE and complete user assets detected; offline copy installation available."
            ;;
        net-install)
            info "Net-install: AlternixDE will be cloned from GitHub after the base system is copied."
            if ! timeout 60 git -c credential.interactive=never ls-remote --exit-code \
                https://github.com/DansDesigns/AlternixDE.git HEAD >/dev/null 2>&1; then
                die "AlternixDE GitHub repository is unreachable. Connect to the internet before erasing the disk."
            fi
            ;;
        *) die "Unknown ISO build mode: ${ALTERNIX_ISO_MODE}" ;;
    esac
fi

# Prevent starting a destructive installation on a nearly exhausted tablet.
# Firmware without usable power_supply sysfs readings is unaffected.
_check_tablet_battery_before_erase() {
    _scan_power_supplies
    # If firmware fails to expose battery capacity, do not mistake a USB
    # accessory for mains or invent a battery percentage.
    if (( HW_BATTERY_FOUND )) && [[ -z "$HW_BATTERY_PCT" ]]; then
        warn "Battery detected but firmware does not expose its charge level; check power before installing."
        return
    fi
    if (( HW_BATTERY_FOUND )) && [[ -n "$HW_BATTERY_PCT" ]] &&
       (( ! HW_CHARGING && ! HW_MAINS_ONLINE )); then
        if (( HW_BATTERY_PCT < 50 )); then
            die "Battery is ${HW_BATTERY_PCT}% with no charger detected. Connect power or charge to at least 50% before erasing the disk."
        fi
        if (( HW_BATTERY_PCT < 75 )); then
            warn "Battery is ${HW_BATTERY_PCT}% and no charger is detected. Please connect external power before installing."
        fi
    fi
}

_check_tablet_battery_before_erase

# ════════════════════════════════════════════════════════════════
# STAGE 5: Disk
# ════════════════════════════════════════════════════════════════
banner
progress_set 3 "Disk setup"
banner
setup_disk

# ════════════════════════════════════════════════════════════════
# STAGE 6: Base System
#
# Two paths. The copy path unpacks the prebuilt rootfs that
# shipped on the ISO — no downloads, no compiling, a few minutes.
# The debootstrap path is kept as a fallback for ISOs built
# without an image, and for anyone building their own.
#
# ALTERNIX_FORCE_DEBOOTSTRAP=1 forces the old path.
# ════════════════════════════════════════════════════════════════
banner
progress_set 4 "Base system"
banner
if [[ "${ALTERNIX_FORCE_DEBOOTSTRAP:-0}" -eq 1 ]]; then
    info "Forced debootstrap install."
    install_base
elif _find_squashfs; then
    copy_rootfs
    delive_target
    ALTERNIX_COPY_INSTALL=1
else
    warn "No rootfs image on this medium — falling back to debootstrap."
    install_base
fi

# Speed up every package operation that follows. Undone at the end.
tune_target_dpkg

# ════════════════════════════════════════════════════════════════
# STAGE 7: (seL4 removed)
# seL4 was compiled but nothing ever booted it, and the build
# pulled cmake, ninja and a python toolchain onto every target.
# build_sel4.sh is left in the tree but is no longer sourced.
# ════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════
# STAGE 9: Configure System
# ════════════════════════════════════════════════════════════════
banner
progress_set 7 "Configuring"
banner
configure_system

# The ISO was baked using root as a temporary build account. Make the
# prebuilt user's files portable to the actual chosen installed account.
# No git, network, apt or new software compilation is needed here.
if [[ "${ALTERNIX_PREBUILT_INSTALL:-0}" -eq 1 &&
      "${ALTERNIX_COPY_INSTALL:-0}" -eq 1 &&
      "${ALTERNIX_DESKTOP:-}" == alternix ]]; then
    personalise_prebuilt_home
fi

# ════════════════════════════════════════════════════════════════
# STAGE 9b: Desktop Environment
# Runs AFTER Devuan base + seL4 + system config are complete.
# Selection happens here too, then installs immediately.
# ════════════════════════════════════════════════════════════════
progress_set 8 "Desktop"
banner
# Verify the positive prebuilt marker on the copied target, not merely
# the absence of an old failure marker. The copy installation must not
# silently rebuild the desktop on a battery-powered tablet.
if [[ -s "${ALTERNIX_MOUNT}/etc/alternix/de-baked" && \
      ! -f "${ALTERNIX_MOUNT}/etc/alternix/de-missing" ]]; then
    ALTERNIX_DE_BAKED=1
else
    ALTERNIX_DE_BAKED=0
fi
if [[ "${ALTERNIX_COPY_INSTALL:-0}" -eq 1 && \
      "${ALTERNIX_DESKTOP:-}" == "alternix" && \
      "${ALTERNIX_ISO_MODE:-live-preview}" == "live-preview" && \
      "${ALTERNIX_DE_BAKED}" -ne 1 ]]; then
    die "Copied live-preview rootfs is missing the prebuilt Alternix desktop marker."
fi

if [[ "${ALTERNIX_COPY_INSTALL:-0}" -eq 1 && "${ALTERNIX_DE_BAKED}" -eq 1 && "${ALTERNIX_DESKTOP:-}" == "alternix" ]]; then
    # AlternixDE was compiled into the ISO image and copied across
    # with the rest of the rootfs. Rebuilding it here would repeat
    # 41 g++ runs on the target CPU for no gain.
    info "AlternixDE already present from the system image."
else
    if ! install_desktop; then
        die "Desktop installation failed. Check ${ALTERNIX_LOG}; the installed system is incomplete."
    fi
fi

# On-screen keyboard defaults, for both the baked and the built
# desktop. Without these onboard opens tiled by Qtile and fills half
# the screen; see installer/onboard-defaults.sh.
if [[ "${ALTERNIX_DESKTOP:-}" == "alternix" ]]; then
    bash "${INSTALLER_DIR}/onboard-defaults.sh" "$ALTERNIX_MOUNT" \
        "${ALTERNIX_ONBOARD_PCT:-30}" "${ALTERNIX_ONBOARD_THEME:-Nightshade}" \
        "${ALTERNIX_SCREEN_W:-}" "${ALTERNIX_SCREEN_H:-}" \
        || warn "Could not set the on-screen keyboard defaults; onboard will use its own."
fi

# ════════════════════════════════════════════════════════════════
# STAGE 9c: Bootloader + initramfs (copy install only)
#
# MISSING BOOTLOADER — DO NOT REMOVE THIS BLOCK
# _install_bootloader lives INSIDE install_base() (install_base.sh:65).
# The copy path never calls install_base, so without this the target
# gets no GRUB at all and boots to nothing. This is what produced
# "grub.cfg NOT found - system may not boot!".
#
# ORDER MATTERS: initramfs first, then GRUB. update-grub writes the
# initrd line from what is actually present in /boot, so building the
# initramfs afterwards leaves a menu entry pointing at the old one.
# ════════════════════════════════════════════════════════════════
# Optional components run after the desktop, since some depend on it,
# and before untune_target_dpkg so they still get the faster unpacking.
install_optional_components

# Restore dpkg's safe defaults before the system is handed over.
untune_target_dpkg

if [[ "${ALTERNIX_COPY_INSTALL:-0}" -eq 1 ]]; then
    finalise_copy || die "Finalising the installed initramfs failed."
    _install_bootloader || die "Bootloader installation failed."

    if [[ ! -s "${ALTERNIX_MOUNT}/boot/grub/grub.cfg" ]]; then
        die "grub.cfg was not created — installation cannot be marked complete."
    fi
fi

# ════════════════════════════════════════════════════════════════
# STAGE 10: Verify installation before claiming success
# ════════════════════════════════════════════════════════════════
# Refuse to report completion if a non-fatal stage recorded an error.
if [[ "${ALTERNIX_ERROR_COUNT:-0}" -gt 0 ]]; then
    die "Installation encountered ${ALTERNIX_ERROR_COUNT} error(s); see $ALTERNIX_LOG."
fi
[[ -s "${ALTERNIX_MOUNT}/etc/fstab" ]] || die "Installed fstab is missing."
root_uuid=$(blkid -s UUID -o value "$PART_ROOT")
[[ -n "$root_uuid" ]] || die "Installed root partition has no UUID."
grep -Fq "UUID=${root_uuid}  /  " "${ALTERNIX_MOUNT}/etc/fstab" || \
    die "Installed fstab does not reference the actual root UUID."
[[ -s "${ALTERNIX_MOUNT}/boot/grub/grub.cfg" ]] || die "Installed GRUB configuration is missing."
grep -Fq "root=UUID=${root_uuid}" "${ALTERNIX_MOUNT}/boot/grub/grub.cfg" || \
    die "Installed GRUB does not reference the actual root UUID."
if [[ "$USE_EFI" -eq 1 ]]; then
    mountpoint -q "${ALTERNIX_MOUNT}/boot/efi" || die "EFI partition is not mounted."
    [[ -f "${ALTERNIX_MOUNT}/boot/efi/EFI/BOOT/BOOTIA32.EFI" || \
       -f "${ALTERNIX_MOUNT}/boot/efi/EFI/BOOT/BOOTX64.EFI" ]] || \
        die "No EFI fallback loader found on the installed EFI partition."
fi
info "Boot verification: root UUID=${root_uuid}; GRUB and fstab agree."

# ════════════════════════════════════════════════════════════════
# STAGE 10: Done
# ════════════════════════════════════════════════════════════════
banner

echo -e "  ${G}Installation complete.${N}"
echo ""
echo -e "  ${W}Installed to:${N}  ${TARGET_DISK}"
echo -e "  ${W}Hostname:${N}      ${ALTERNIX_HOSTNAME}"
echo -e "  ${W}User:${N}          ${ALTERNIX_USERNAME}"
echo -e "  ${W}Arch:${N}          ${HW_ARCH}"
echo ""
echo -e "  ${D}Remove the installation media and reboot.${N}"

# Verify bootloader was installed
if [[ -f "${ALTERNIX_MOUNT}/boot/grub/grub.cfg" ]]; then
    ok "grub.cfg found — bootloader installed correctly."
else
    warn "grub.cfg NOT found — system may not boot!"
    warn "Check: ls ${ALTERNIX_MOUNT}/boot/"
    ls "${ALTERNIX_MOUNT}/boot/" 2>/dev/null | while IFS= read -r f; do warn "  $f"; done
fi

echo ""

cleanup_mounts

rm -f /tmp/.alternix-installer-running

# ════════════════════════════════════════════════════════════════
# KEEP THE LOGS ON THE INSTALLED SYSTEM — DO NOT REMOVE
# /tmp is a RAM disk and disappears on reboot. Saving to the USB stick
# only works when the stick is writable: a virtual machine booting the
# ISO file sees it as a read-only CD, and a dd-written stick is
# read-only too, so in both cases there was no log to look at afterwards.
# The disk just installed to is always writable and still mounted here,
# so the logs are copied there and can be read after the first boot.
# The config file is copied without its password line.
# ════════════════════════════════════════════════════════════════
if [[ -n "${ALTERNIX_MOUNT:-}" ]] && mountpoint -q "$ALTERNIX_MOUNT" 2>/dev/null; then
    _logdir="${ALTERNIX_MOUNT}/var/log/alternix-install"
    if mkdir -p "$_logdir" 2>/dev/null; then
        for _f in /tmp/alternix-install.log /tmp/alternix-de-target.log \
                  /tmp/alternix-xorg.log; do
            [[ -f "$_f" ]] && cp -f "$_f" "$_logdir/" 2>/dev/null
        done
        [[ -f /tmp/alternix-install.conf ]] && \
            grep -v '^ALTERNIX_PASSWORD=' /tmp/alternix-install.conf \
                > "$_logdir/install.conf" 2>/dev/null
        chmod 755 "$_logdir"; chmod 644 "$_logdir"/* 2>/dev/null
        info "Install logs kept on the new system in /var/log/alternix-install/"
    fi
    sync
fi

# UNATTENDED EXIT — DO NOT REMOVE
# The menu below is an infinite `while true` loop reading stdin. Under
# the graphical installer stdin is a closed pipe, so `read` returns
# immediately with an empty choice, which matches the ""|newline case
# and loops forever. install.sh therefore never exits, QProcess never
# emits finished(), and osm-install sits on the progress page with no
# way to reboot. Exit cleanly instead and let the GUI present the
# reboot / shutdown / log options itself.
if [[ "${ALTERNIX_UNATTENDED:-0}" -eq 1 ]]; then
    # SAVE THE LOG TO THE INSTALL MEDIUM
    # /tmp is a tmpfs that dies with the reboot, and on a tablet with no
    # terminal it is unreachable anyway. The medium's second partition
    # can be read on any other machine afterwards.
    if [[ -x "${INSTALLER_DIR}/alternix-media" ]]; then
        bash "${INSTALLER_DIR}/alternix-media" savelog >/dev/null 2>&1 || \
            warn "Could not save the log to the installation medium."
    fi
    if [[ "${ALTERNIX_ERROR_COUNT:-0}" -gt 0 ]]; then
        exit 1
    fi
    exit 0
fi

echo -e "  ${W}What would you like to do?${N}"
echo ""
echo -e "  ${T}1${N}  Reboot"
echo -e "  ${T}2${N}  Drop to shell (inspect before rebooting)"
echo -e "  ${T}3${N}  View install log"
echo -e "  ${T}4${N}  Shutdown"
echo ""
while true; do
    echo -en "  ${W}Choice${N}: "
    IFS= read -r choice
    case "$choice" in
        1) printf '\033[r'; sync; /sbin/reboot -f ;;
        2) rm -f /tmp/.alternix-installer-running
           touch /tmp/.alternix-shell-drop
           echo ""
           echo " Alternix Shell — type: install  to restart"
           echo " System at: ${ALTERNIX_MOUNT}"
           echo " Grub: ls ${ALTERNIX_MOUNT}/boot/grub/"
           echo " Log:  cat /tmp/alternix-install.log"
           echo ""
           printf '\033[r'
           env PS1="[alternix]: " /bin/bash --norc -i
           rm -f /tmp/.alternix-shell-drop
           exit 0 ;;
        3) _show_logs
           echo ""
           echo -e "  ${T}1${N}  Reboot"
           echo -e "  ${T}2${N}  Drop to shell (inspect before rebooting)"
           echo -e "  ${T}3${N}  View install log"
           echo -e "  ${T}4${N}  Shutdown"
           echo "" ;;
        4) printf '\033[r'; sync; /sbin/poweroff -f ;;
        ""|$'
') ;;
        *) warn "Enter 1-4." ;;
    esac
done
