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
    rm -f /tmp/.alternix-installer-running
    local code=$?
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
setup_network

# Fix wrong RTC before any TLS (git/apt) — see net_sync_clock
net_sync_clock

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

# ════════════════════════════════════════════════════════════════
# STAGE 9b: Desktop Environment
# Runs AFTER Devuan base + seL4 + system config are complete.
# Selection happens here too, then installs immediately.
# ════════════════════════════════════════════════════════════════
progress_set 8 "Desktop"
banner
# DE MARKER CHECK — DO NOT REMOVE
# hook 0080 writes /etc/alternix/de-missing into the image when the
# AlternixDE build failed at ISO build time. Without this check the
# copy install would assume the desktop is already there and skip
# install_desktop, leaving a system with no desktop at all.
if [[ -f "${ALTERNIX_MOUNT}/etc/alternix/de-missing" ]]; then
    warn "System image has no baked desktop — building it on the target."
    ALTERNIX_DE_BAKED=0
else
    ALTERNIX_DE_BAKED=1
fi

if [[ "${ALTERNIX_COPY_INSTALL:-0}" -eq 1 && "${ALTERNIX_DE_BAKED}" -eq 1 && "${ALTERNIX_DESKTOP:-}" == "alternix" ]]; then
    # AlternixDE was compiled into the ISO image and copied across
    # with the rest of the rootfs. Rebuilding it here would repeat
    # 41 g++ runs on the target CPU for no gain.
    info "AlternixDE already present from the system image."
else
    install_desktop
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
# Restore dpkg's safe defaults before the system is handed over.
untune_target_dpkg

if [[ "${ALTERNIX_COPY_INSTALL:-0}" -eq 1 ]]; then
    finalise_copy
    _install_bootloader

    # Fail loudly rather than reporting success on an unbootable disk.
    if [[ ! -f "${ALTERNIX_MOUNT}/boot/grub/grub.cfg" ]]; then
        err "grub.cfg was not created — the installed system will not boot."
        err "Check the bootloader output above."
    fi
fi

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
