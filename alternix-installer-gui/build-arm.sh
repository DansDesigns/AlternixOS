#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# build-arm.sh — Alternix SD card image for Raspberry Pi (arm64)
#
# Targets:  Raspberry Pi 3B+ and Raspberry Pi Compute Module 4.
#           One image boots both.
#
# Single-board computers do not boot ISOs. This builds a disk image
# that is written straight onto an SD card (or a CM4's eMMC). On first
# boot the root filesystem grows to fill the card.
#
# STAGE 1 (this script, today): a bootable Devuan system with the Pi
# kernel and firmware, NetworkManager, and XLibre, plus xterm so the
# display stack can be tested with `startx`. AlternixDE itself is
# stage 2 and is not baked in yet.
#
# Approach follows Debian's own Raspberry Pi images (raspi-team
# image-specs): Debian's standard arm64 kernel plus the raspi-firmware
# package, which generates config.txt and cmdline.txt. Everything comes
# from Devuan's repositories except XLibre, which comes from XLibre's
# Debian trixie arm64 repository because the Devuan one is amd64-only.
#
# Run as root on an x86 Devuan machine:
#     sudo bash build-arm.sh
#
# Host packages needed:
#     debootstrap qemu-user-static binfmt-support dosfstools
#     e2fsprogs fdisk xz-utils curl devuan-keyring
#
# Settings (environment variables, all optional):
#     DEVUAN_MIRROR   package mirror for the build
#     IMG_SIZE        image size before first-boot growth (default 3G)
#     IMG_LOCALE      default en_GB.UTF-8
#     IMG_KEYMAP      default gb
#     IMG_TIMEZONE    default Europe/London
#     WITH_XLIBRE     1 (default) or 0 for a console-only image
#     COMPRESS        1 (default) writes .img.xz, 0 keeps the raw .img
# ═══════════════════════════════════════════════════════════════

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build-arm"
MNT="${BUILD_DIR}/rootfs"
LOG="${BUILD_DIR}/arm-build.log"
IMG="${SCRIPT_DIR}/alternix-rpi-arm64.img"

SUITE="excalibur"
DEVUAN_MIRROR="${DEVUAN_MIRROR:-http://deb.devuan.org/merged}"
DEVUAN_KEYRING="/usr/share/keyrings/devuan-archive-keyring.gpg"
IMG_SIZE="${IMG_SIZE:-3G}"
BOOT_SIZE_MIB=512
IMG_LOCALE="${IMG_LOCALE:-en_GB.UTF-8}"
IMG_KEYMAP="${IMG_KEYMAP:-gb}"
IMG_TIMEZONE="${IMG_TIMEZONE:-Europe/London}"
IMG_HOSTNAME="alternix-pi"
WITH_XLIBRE="${WITH_XLIBRE:-1}"
COMPRESS="${COMPRESS:-1}"

# XLibre's Debian repository. Its Devuan repository publishes amd64
# only; the Debian trixie arm64 build has the same version and its
# dependencies are all satisfied on Devuan excalibur.
XLIBRE_REPO="https://xlibre-deb.github.io/debian/"
XLIBRE_KEY="https://xlibre-deb.github.io/key.asc"

LOOP=""

_info() { echo "  · $*"; }
_ok()   { echo "  ✓ $*"; }
_warn() { echo "  ! $*"; }
_err()  { echo "  ✗ $*" >&2; }
_die()  { _err "$*"; exit 1; }
_step() { echo ""; echo "  ══  $*  ══"; echo ""; }

# ── Run a command inside the arm64 root ───────────────────────────
# A clean environment, so the host's locale and variables do not leak
# into an emulated system that has neither.
_chroot() {
    chroot "$MNT" /usr/bin/env -i \
        HOME=/root TERM="${TERM:-xterm}" LC_ALL=C \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        DEBIAN_FRONTEND=noninteractive \
        "$@"
}

_apt() {
    _chroot apt-get -y --no-install-recommends \
        -o Dpkg::Options::=--force-confold "$@" \
        || _die "apt-get $* failed (see ${LOG})"
}

# ── Cleanup: always unmount and release the loop device ───────────
# Runs on every exit, including failures, so a broken build never
# leaves the image mounted or a loop device attached.
_unmount_all() {
    local m
    for m in dev/pts dev sys proc boot/firmware; do
        mountpoint -q "${MNT}/${m}" 2>/dev/null && umount -l "${MNT}/${m}" 2>/dev/null
    done
    mountpoint -q "$MNT" 2>/dev/null && umount -l "$MNT" 2>/dev/null
}

_detach() {
    if [[ -n "$LOOP" ]]; then
        losetup -d "$LOOP" 2>/dev/null
        LOOP=""
    fi
}

_cleanup() {
    _unmount_all
    _detach
}

# ═══════════════════════════════════════════════════════════════
# Host checks
# ═══════════════════════════════════════════════════════════════
check_host() {
    _step "Checking build host"
    [[ "$(id -u)" -eq 0 ]] || _die "Run as root: sudo bash build-arm.sh"

    local c missing=()
    for c in debootstrap sfdisk losetup mkfs.vfat mkfs.ext4 chroot curl; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [[ "$COMPRESS" == "1" ]] && ! command -v xz >/dev/null 2>&1 && missing+=("xz")
    [[ ${#missing[@]} -eq 0 ]] || _die "Missing host tools: ${missing[*]}"

    if [[ ! -f "$DEVUAN_KEYRING" ]]; then
        DEVUAN_KEYRING=$(dpkg -L devuan-keyring 2>/dev/null | grep '\.gpg$' | head -1)
        [[ -f "$DEVUAN_KEYRING" ]] || _die "Devuan keyring not found. Install devuan-keyring."
    fi
    _ok "Keyring: ${DEVUAN_KEYRING}"

    # ARM EMULATION
    # The image is built on an x86 machine, so every program run inside
    # it during the build is executed through QEMU. The kernel needs a
    # binfmt_misc entry telling it to hand aarch64 binaries to QEMU.
    QEMU_BIN=$(command -v qemu-aarch64-static 2>/dev/null)
    [[ -n "$QEMU_BIN" ]] || _die "qemu-aarch64-static not found. Install qemu-user-static and binfmt-support."

    if [[ ! -d /proc/sys/fs/binfmt_misc ]] || ! mountpoint -q /proc/sys/fs/binfmt_misc; then
        mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null
    fi
    if ! grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
        command -v update-binfmts >/dev/null 2>&1 && \
            update-binfmts --enable qemu-aarch64 >/dev/null 2>&1
    fi
    grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null || \
        _die "aarch64 emulation is not registered with the kernel. Install binfmt-support, then: update-binfmts --enable qemu-aarch64"
    _ok "ARM64 emulation: ${QEMU_BIN}"
    _ok "Build mirror: ${DEVUAN_MIRROR}"
}

# ═══════════════════════════════════════════════════════════════
# Image file, partitions, filesystems
# ═══════════════════════════════════════════════════════════════

# MBR, not GPT: the Pi 3B+'s boot ROM only understands MBR. The boot
# partition is FAT32 (type c) because the GPU firmware can read nothing
# else. Partitions start at 4 MiB for SD card erase-block alignment.
# Labels RASPIFIRM / RASPIROOT match Debian's Raspberry Pi images, and
# the kernel command line finds root by label rather than device name.
partition_image() {   # $1 image path
    local first=8192
    local boot_sectors=$(( BOOT_SIZE_MIB * 2048 ))
    sfdisk --quiet "$1" <<EOF || _die "Partitioning failed"
label: dos
unit: sectors
start=${first}, size=${boot_sectors}, type=c, bootable
start=$(( first + boot_sectors )), type=83
EOF
}

# PARTITION NODES — KEEP THE partx FALLBACK
# losetup -P asks the kernel to scan the partition table, but on kernels
# where the loop driver has max_part=0 the scan does not happen and
# ${LOOP}p1 never appears. partx -a adds the partitions explicitly and
# works either way.
attach_image() {      # $1 image path; sets LOOP
    LOOP=$(losetup -fP --show "$1") || _die "Could not attach loop device"
    local i
    for i in 1 2 3 4 5 6; do
        [[ -b "${LOOP}p1" && -b "${LOOP}p2" ]] && return 0
        sleep 0.5
    done
    partx -a "$LOOP" 2>/dev/null
    for i in 1 2 3 4 5 6; do
        [[ -b "${LOOP}p1" && -b "${LOOP}p2" ]] && return 0
        sleep 0.5
    done
    _die "Partitions on ${LOOP} did not appear, even after partx"
}

format_image() {
    mkfs.vfat -F 32 -n RASPIFIRM "${LOOP}p1" >/dev/null || _die "mkfs.vfat failed"
    mkfs.ext4 -q -F -L RASPIROOT "${LOOP}p2"            || _die "mkfs.ext4 failed"
}

create_image() {
    _step "Creating image (${IMG_SIZE})"
    rm -f "$IMG" "${IMG}.xz"
    truncate -s "$IMG_SIZE" "$IMG" || _die "Could not create ${IMG}"
    partition_image "$IMG"
    attach_image "$IMG"
    format_image
    mkdir -p "$MNT"
    mount "${LOOP}p2" "$MNT" || _die "Could not mount root partition"
    _ok "Image ${IMG} on ${LOOP}"
}

# ═══════════════════════════════════════════════════════════════
# Base system
# ═══════════════════════════════════════════════════════════════
bootstrap_base() {
    _step "Bootstrapping Devuan ${SUITE} arm64 (slow: runs under emulation)"
    debootstrap --arch=arm64 --foreign --variant=minbase \
        --include=ca-certificates \
        --keyring="$DEVUAN_KEYRING" "$SUITE" "$MNT" "$DEVUAN_MIRROR" \
        || _die "debootstrap first stage failed"

    # Present inside the root in case the kernel's binfmt entry does not
    # carry the fix-binary flag. Removed again at the end of the build.
    cp "$QEMU_BIN" "${MNT}/usr/bin/" || _die "Could not copy QEMU into the root"

    local out
    if ! out=$(chroot "$MNT" /debootstrap/debootstrap --second-stage 2>&1); then
        echo "$out" | tail -20
        echo "$out" | grep -qi "exec format error" && \
            _die "ARM binaries cannot run: aarch64 emulation is not working."
        _die "debootstrap second stage failed"
    fi
    _ok "Base system installed."

    local fs
    for fs in proc sys dev dev/pts; do
        mkdir -p "${MNT}/${fs}"
        mount --bind "/${fs}" "${MNT}/${fs}" || _die "Could not bind /${fs}"
    done
    cp -L /etc/resolv.conf "${MNT}/etc/resolv.conf"

    mkdir -p "${MNT}/boot/firmware"
    mount "${LOOP}p1" "${MNT}/boot/firmware" || _die "Could not mount boot partition"
}

configure_apt() {
    _step "Configuring package sources"
    cat > "${MNT}/etc/apt/sources.list" <<EOF
deb ${DEVUAN_MIRROR} ${SUITE} main contrib non-free non-free-firmware
deb ${DEVUAN_MIRROR} ${SUITE}-security main contrib non-free non-free-firmware
deb ${DEVUAN_MIRROR} ${SUITE}-updates main contrib non-free non-free-firmware
EOF

    # Same pins as the x86 ISO: no systemd, GNU coreutils only.
    mkdir -p "${MNT}/etc/apt/preferences.d"
    cat > "${MNT}/etc/apt/preferences.d/no-systemd" <<'EOF'
Package: systemd systemd-sysv systemd-shim live-config live-config-systemd
Pin: release *
Pin-Priority: -1
EOF
    cat > "${MNT}/etc/apt/preferences.d/no-rust-coreutils" <<'EOF'
Package: rust-coreutils rust-coreutils-* uutils-coreutils coreutils-from-uutils
Pin: release *
Pin-Priority: -1

Package: coreutils
Pin: release *
Pin-Priority: 1001
EOF

    # Build-time speed-ups. Every dpkg operation is emulated, so the
    # per-file fsync that dpkg normally does is especially costly.
    # Removed at the end so the finished system has dpkg's defaults.
    echo 'force-unsafe-io' > "${MNT}/etc/dpkg/dpkg.cfg.d/99-alternix-build"
    cat > "${MNT}/etc/apt/apt.conf.d/99-alternix-build" <<'EOF'
Acquire::Languages "none";
Acquire::http::Timeout "30";
Acquire::Retries "3";
APT::Install-Recommends "false";
EOF

    # Never start services inside the build root.
    printf '#!/bin/sh\nexit 101\n' > "${MNT}/usr/sbin/policy-rc.d"
    chmod 755 "${MNT}/usr/sbin/policy-rc.d"

    _apt update
    _ok "Package sources configured."
}

# ═══════════════════════════════════════════════════════════════
# Raspberry Pi kernel and firmware
# ═══════════════════════════════════════════════════════════════

# Written before raspi-firmware is installed, so its hook reads it the
# first time it generates config.txt.
#
# CM4 BOOT FIX — DO NOT REMOVE
# The mainline kernel's device tree for the CM4 is named differently
# from the file the Pi bootloader looks for, so a CM4 will not boot
# unless told which one to load. Debian's Raspberry Pi team handles it
# the same way.
#
# CM4 USB — DO NOT REMOVE
# The CM4 keeps its USB controller switched off by default to save
# power. Without otg_mode=1 a keyboard on the IO board does nothing.
#
# The trailing [all] closes the [cm4] section, so anything appended
# after this block applies to every board rather than only the CM4.
write_raspi_custom() {   # $1 root directory
    mkdir -p "$1/etc/default"
    cat > "$1/etc/default/raspi-firmware-custom" <<'EOF'
[cm4]
device_tree=bcm2711-rpi-cm4-io.dtb
otg_mode=1
[all]
EOF
}

# Root by label, exactly as Debian's images do it: both the default
# file (for future regeneration) and the already-generated cmdline.txt.
set_rootpart() {         # $1 root directory
    local def="$1/etc/default/raspi-firmware"
    if grep -q '^#\?ROOTPART=' "$def" 2>/dev/null; then
        sed -i 's/^#\?ROOTPART=.*/ROOTPART=LABEL=RASPIROOT/' "$def"
    else
        echo 'ROOTPART=LABEL=RASPIROOT' >> "$def"
    fi
    local cmd="$1/boot/firmware/cmdline.txt"
    if [[ -f "$cmd" ]]; then
        sed -i -E 's#root=[^ ]+#root=LABEL=RASPIROOT#' "$cmd"
        grep -q 'root=' "$cmd" || sed -i 's/$/ root=LABEL=RASPIROOT/' "$cmd"
    fi
}

# Loud check of everything the Pi needs on its boot partition. A
# missing file here means a board that shows nothing at all on screen,
# so the build stops rather than producing an image that cannot boot.
verify_boot_partition() {   # $1 boot partition directory; returns 1 on failure
    local b="$1" missing=() f k i

    for f in bootcode.bin start.elf fixup.dat start4.elf fixup4.dat \
             config.txt cmdline.txt \
             bcm2837-rpi-3-b-plus.dtb bcm2711-rpi-cm4-io.dtb; do
        [[ -f "${b}/${f}" ]] || missing+=("$f")
    done

    k=$(sed -n 's/^kernel=//p' "${b}/config.txt" 2>/dev/null | head -1)
    if [[ -z "$k" ]]; then missing+=("kernel= line in config.txt")
    elif [[ ! -f "${b}/${k}" ]]; then missing+=("kernel file ${k}"); fi

    i=$(sed -n 's/^initramfs[[:space:]]\+\([^[:space:]]\+\).*/\1/p' "${b}/config.txt" 2>/dev/null | head -1)
    if [[ -z "$i" ]]; then missing+=("initramfs line in config.txt")
    elif [[ ! -f "${b}/${i}" ]]; then missing+=("initramfs file ${i}"); fi

    grep -q 'device_tree=bcm2711-rpi-cm4-io.dtb' "${b}/config.txt" 2>/dev/null || missing+=("CM4 device_tree line")
    grep -q 'otg_mode=1' "${b}/config.txt" 2>/dev/null || missing+=("CM4 otg_mode line")
    grep -q 'arm_64bit=1' "${b}/config.txt" 2>/dev/null || missing+=("arm_64bit=1")
    grep -q 'root=LABEL=RASPIROOT' "${b}/cmdline.txt" 2>/dev/null || missing+=("root=LABEL=RASPIROOT in cmdline.txt")

    if [[ ${#missing[@]} -gt 0 ]]; then
        local m
        for m in "${missing[@]}"; do _err "boot partition is missing: ${m}"; done
        return 1
    fi
    return 0
}

install_kernel() {
    _step "Installing kernel and Raspberry Pi firmware"
    write_raspi_custom "$MNT"

    _apt install \
        sysvinit-core openrc elogind eudev dbus \
        linux-image-arm64 initramfs-tools raspi-firmware \
        firmware-brcm80211 bluez-firmware

    set_rootpart "$MNT"

    # Regenerate config.txt and cmdline.txt now that every setting is
    # in place, using the same hook the kernel package runs.
    local kver
    kver=$(ls "${MNT}/lib/modules" 2>/dev/null | sort -V | tail -1)
    [[ -n "$kver" ]] || _die "No kernel modules found; linux-image-arm64 did not install"
    _chroot /etc/kernel/postinst.d/z50-raspi-firmware "$kver" "/boot/vmlinuz-${kver}" \
        || _warn "z50-raspi-firmware returned an error; checking the result anyway"
    set_rootpart "$MNT"

    # FALLBACKS, applied only if the generated files lack them. Each
    # opens with [all] so it cannot end up scoped to a single board.
    local cfg="${MNT}/boot/firmware/config.txt"
    if [[ -f "$cfg" ]]; then
        if ! grep -q 'device_tree=bcm2711-rpi-cm4-io.dtb' "$cfg"; then
            _warn "raspi-firmware did not include the CM4 settings; appending them."
            { echo; cat "${MNT}/etc/default/raspi-firmware-custom"; } >> "$cfg"
        fi
        if ! grep -q 'arm_64bit=1' "$cfg"; then
            _warn "config.txt lacked arm_64bit=1; appending it."
            printf '\n[all]\narm_64bit=1\n' >> "$cfg"
        fi
    fi

    verify_boot_partition "${MNT}/boot/firmware" || \
        _die "The boot partition is incomplete. The image would not boot."
    _ok "Kernel ${kver}; boot partition verified for Pi 3B+ and CM4."
}

# ═══════════════════════════════════════════════════════════════
# System configuration
# ═══════════════════════════════════════════════════════════════

# Registers a service with whichever rc system is present. Devuan here
# runs sysvinit with OpenRC as the rc system, matching the x86 ISO.
_svc_enable() {
    _chroot update-rc.d "$1" defaults >/dev/null 2>&1
    _chroot sh -c "command -v rc-update >/dev/null && rc-update add '$1' default" >/dev/null 2>&1
    return 0
}

configure_system() {
    _step "Configuring system"

    # The Pi has no battery-backed clock. Without fake-hwclock every boot
    # starts in 1970, TLS fails, and apt rejects package lists as "not
    # yet valid". It restores the last saved time at boot.
    _apt install \
        locales console-setup keyboard-configuration kbd sudo kmod \
        network-manager wpasupplicant iproute2 iputils-ping curl \
        fake-hwclock cloud-guest-utils e2fsprogs dosfstools fdisk less

    cat > "${MNT}/etc/fstab" <<'EOF'
# noatime cuts SD card writes. Both found by label, not device name,
# so the same image works from SD, eMMC or USB.
LABEL=RASPIROOT  /               ext4  defaults,noatime  0 1
LABEL=RASPIFIRM  /boot/firmware  vfat  defaults,noatime  0 2
EOF

    echo "$IMG_HOSTNAME" > "${MNT}/etc/hostname"
    cat > "${MNT}/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   ${IMG_HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
EOF

    sed -i "s/^# *${IMG_LOCALE} /${IMG_LOCALE} /" "${MNT}/etc/locale.gen"
    grep -q "^${IMG_LOCALE} " "${MNT}/etc/locale.gen" || \
        echo "${IMG_LOCALE} UTF-8" >> "${MNT}/etc/locale.gen"
    _chroot locale-gen >/dev/null || _warn "locale-gen failed"
    echo "LANG=${IMG_LOCALE}" > "${MNT}/etc/default/locale"

    sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"${IMG_KEYMAP}\"/" "${MNT}/etc/default/keyboard" 2>/dev/null

    ln -sf "/usr/share/zoneinfo/${IMG_TIMEZONE}" "${MNT}/etc/localtime"
    echo "$IMG_TIMEZONE" > "${MNT}/etc/timezone"

    _svc_enable network-manager
    _svc_enable fake-hwclock

    _ok "System configured (${IMG_LOCALE}, ${IMG_KEYMAP}, ${IMG_TIMEZONE})."
}

# ═══════════════════════════════════════════════════════════════
# XLibre
# ═══════════════════════════════════════════════════════════════
install_xlibre() {
    [[ "$WITH_XLIBRE" == "1" ]] || { _info "WITH_XLIBRE=0: skipping X."; return 0; }
    _step "Installing XLibre (Debian trixie arm64 build)"

    # Key fetched on the host rather than inside the root: TLS under
    # emulation is slow, and the host is known to have working network.
    mkdir -p "${MNT}/etc/apt/keyrings"
    curl -fsSL "$XLIBRE_KEY" -o "${MNT}/etc/apt/keyrings/xlibre-deb.asc" \
        || _die "Could not download the XLibre signing key"

    cat > "${MNT}/etc/apt/sources.list.d/xlibre-deb.sources" <<EOF
Types: deb
URIs: ${XLIBRE_REPO}
Suites: trixie
Components: main
Architectures: arm64
Signed-By: /etc/apt/keyrings/xlibre-deb.asc
EOF
    _apt update
    _apt install xlibre xinit xterm x11-xserver-utils fonts-dejavu-core

    # REAL DEPENDENCY CHECK
    # These packages are built for Debian, whose X server links against
    # libudev1. Devuan provides that through eudev. Running the server
    # binary is the definitive test: a missing library fails here, at
    # build time, rather than as a black screen on the board.
    local x
    for x in /usr/lib/xorg/Xorg /usr/bin/Xorg; do [[ -x "${MNT}${x}" ]] && break; done
    [[ -x "${MNT}${x}" ]] || _die "XLibre installed but no Xorg binary was found"

    local missing
    missing=$(_chroot ldd "$x" 2>&1 | grep 'not found')
    if [[ -n "$missing" ]]; then
        echo "$missing" | sed 's/^/      /'
        _die "XLibre is missing shared libraries on Devuan arm64 (listed above)"
    fi
    local ver
    ver=$(_chroot "$x" -version 2>&1 | grep -m1 -i 'x server') \
        || _die "XLibre's server binary would not run"
    _ok "XLibre runs on Devuan arm64: ${ver}"
}

# ═══════════════════════════════════════════════════════════════
# First boot
# ═══════════════════════════════════════════════════════════════

# The image is deliberately small. On first boot this grows the root
# partition and filesystem to fill the card, then removes itself.
# Growing a mounted ext4 filesystem is supported, so this can run late
# in boot with everything else already up.
write_firstboot() {      # $1 root directory
    mkdir -p "$1/etc/init.d"
    cat > "$1/etc/init.d/alternix-firstboot" <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          alternix-firstboot
# Required-Start:    $local_fs
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:
# Short-Description: Grow the root filesystem to fill the card, once
### END INIT INFO

[ "$1" = "start" ] || exit 0

ROOTDEV=$(findmnt -n -o SOURCE /)
PART=$(basename "$ROOTDEV")
NUM=$(cat "/sys/class/block/${PART}/partition" 2>/dev/null)
DISK="/dev/$(basename "$(readlink -f "/sys/class/block/${PART}/..")")"

if [ -n "$NUM" ] && [ -b "$DISK" ]; then
    echo "alternix-firstboot: growing ${ROOTDEV} to fill ${DISK}"
    # growpart exits 1 with "NOCHANGE" when there is nothing to grow,
    # which is not an error worth stopping for.
    growpart "$DISK" "$NUM" || true
    resize2fs "$ROOTDEV" || echo "alternix-firstboot: resize2fs failed" >&2
fi

# Unique machine identity, generated on the real hardware.
[ -s /etc/machine-id ] || dbus-uuidgen --ensure=/etc/machine-id
mkdir -p /var/lib/dbus
[ -e /var/lib/dbus/machine-id ] || ln -s /etc/machine-id /var/lib/dbus/machine-id

# Run once only.
command -v rc-update >/dev/null && rc-update del alternix-firstboot default >/dev/null 2>&1
update-rc.d -f alternix-firstboot remove >/dev/null 2>&1
rm -f /etc/init.d/alternix-firstboot
exit 0
EOF
    chmod 755 "$1/etc/init.d/alternix-firstboot"
}

configure_firstboot() {
    _step "Configuring first boot"
    write_firstboot "$MNT"
    _svc_enable alternix-firstboot

    # TEMPORARY LOGIN for the stage 1 image. The password is expired,
    # so the first login forces it to be changed. Replaced by the
    # graphical first-boot setup in a later stage.
    echo 'root:alternix' | _chroot chpasswd || _die "Could not set the root password"
    _chroot passwd --expire root >/dev/null || _warn "Could not expire the root password"
    _ok "First-boot resize installed; root password expires on first login."
}

# ═══════════════════════════════════════════════════════════════
# Finish
# ═══════════════════════════════════════════════════════════════
finalise() {
    _step "Finalising image"

    # The finished system uses Devuan's round-robin, whatever mirror
    # was used to build it.
    cat > "${MNT}/etc/apt/sources.list" <<EOF
deb http://deb.devuan.org/merged ${SUITE} main contrib non-free non-free-firmware
deb http://deb.devuan.org/merged ${SUITE}-security main contrib non-free non-free-firmware
deb http://deb.devuan.org/merged ${SUITE}-updates main contrib non-free non-free-firmware
EOF

    _chroot apt-get clean
    rm -rf "${MNT}/var/lib/apt/lists/"*
    rm -f "${MNT}/etc/dpkg/dpkg.cfg.d/99-alternix-build" \
          "${MNT}/etc/apt/apt.conf.d/99-alternix-build" \
          "${MNT}/usr/sbin/policy-rc.d" \
          "${MNT}/usr/bin/$(basename "$QEMU_BIN")"

    # Identity that must be unique per board, matching install_copy.sh.
    : > "${MNT}/etc/machine-id"
    rm -f "${MNT}/var/lib/dbus/machine-id"
    : > "${MNT}/etc/resolv.conf"

    # Start the first boot from the build time rather than 1970.
    _chroot fake-hwclock save >/dev/null 2>&1 || true

    # ORDER MATTERS: check the filesystem after unmounting it but before
    # releasing the loop device. Detaching first leaves nothing to check.
    sync
    _unmount_all
    e2fsck -fy "${LOOP}p2" >/dev/null 2>&1
    [[ $? -le 1 ]] || _warn "e2fsck reported problems on the root filesystem"
    _detach

    if [[ "$COMPRESS" == "1" ]]; then
        _info "Compressing (xz)..."
        xz -T0 -3 -f "$IMG" || _die "Compression failed; the raw image is at ${IMG}"
        IMG="${IMG}.xz"
    fi
    _ok "Image written: ${IMG} ($(du -h "$IMG" | cut -f1))"
}

main() {
    trap _cleanup EXIT
    mkdir -p "$BUILD_DIR"
    check_host
    create_image
    bootstrap_base
    configure_apt
    install_kernel
    configure_system
    install_xlibre
    configure_firstboot
    finalise

    echo ""
    echo "  ══════════════════════════════════════════════════════════"
    echo "  Alternix Raspberry Pi image built: ${IMG}"
    echo ""
    echo "  Write it with Raspberry Pi Imager (\"Use custom\"), Rufus,"
    echo "  or:  xzcat ${IMG} | sudo dd of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "  A CM4 with eMMC must first be put into USB mass-storage mode"
    echo "  with rpiboot; a CM4 Lite boots from the carrier's SD slot."
    echo ""
    echo "  Log in as root, password: alternix (you will be asked to"
    echo "  change it). Test the display with:  startx"
    echo "  ══════════════════════════════════════════════════════════"
}

# Run only when executed, not when sourced, so the functions above can
# be tested individually.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    mkdir -p "$BUILD_DIR"
    main "$@" 2>&1 | tee "$LOG"
    exit "${PIPESTATUS[0]}"
fi
