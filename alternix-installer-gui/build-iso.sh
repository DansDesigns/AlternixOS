#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# build-iso.sh — Alternix Installer ISO Builder
#
# Builds a minimal Devuan live environment containing
# the Alternix installer scripts. Uses live-build.
#
# Run as root on a Devuan/Debian host.
# Output: alternix-installer.iso
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"

# ── Package mirror used to BUILD the ISO ──────────────────────────
# deb.devuan.org is a round-robin across all Devuan mirrors, which is what
# Devuan asks people to use. Occasionally it hands out a mirror whose
# Release file does not match its own package lists, and apt then fails
# with "File has unexpected size ... Mirror sync in progress?". It can
# keep handing out the same broken mirror, so rerunning does not always
# help. To pin a specific mirror for one build:
#
#   DEVUAN_MIRROR=http://ftp.fau.de/devuan/merged ./build-iso.sh
#
# Any "BaseURL" from Devuan's mirror list works, with /merged appended.
# This affects only the ISO build and the live session. Installed
# systems get their own sources.list from configure_system.sh, which
# always uses deb.devuan.org, so pinning here never reaches a user.
DEVUAN_MIRROR="${DEVUAN_MIRROR:-http://deb.devuan.org/merged}"
OUTPUT_ISO="${SCRIPT_DIR}/alternix-installer.iso"
ALTERNIX_BUILD_MODE="" # chosen interactively, or read from the completed image for finalisation

# ── Colours (minimal, build-time only) ───────────────────────────
_info()  { echo "  · $*"; }
_ok()    { echo "  ✓ $*"; }
_err()   { echo "  ✗ $*" >&2; }
_die()   { _err "$*"; exit 1; }
_step()  { echo ""; echo "  ══  $*  ══"; echo ""; }

# Large FAT32 boot images may contain a full Linux initrd. The following
# validation steps used to run completely silently, making a working ISO
# appear frozen after the IA32 check. Keep the byte-for-byte checks, but
# report the active operation and give periodic elapsed-time updates.
# Coreutils timeout prevents a stalled mtools process from hanging forever.
ALTERNIX_VERIFY_TIMEOUT_SECONDS="${ALTERNIX_VERIFY_TIMEOUT_SECONDS:-1800}"
[[ "$ALTERNIX_VERIFY_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || \
    _die "ALTERNIX_VERIFY_TIMEOUT_SECONDS must be a positive integer."

_monitored_cmd() {  # label command args...
    local description="$1" log_file command_pid elapsed=0 status=0
    shift
    log_file=$(mktemp) || return 1
    printf '%s | START | %s\n' "$(date -Is)" "$description" >> "${BUILD_DIR}/iso-verification.log"
    timeout --kill-after=10s "${ALTERNIX_VERIFY_TIMEOUT_SECONDS}s" "$@" </dev/null > "$log_file" 2>&1 &
    command_pid=$!
    while kill -0 "$command_pid" 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        if (( elapsed % 15 == 0 )); then
            _info "${description}: ${elapsed}s elapsed; operation still running..."
        fi
    done
    if wait "$command_pid"; then
        printf '%s | OK | %s | %ss\n' "$(date -Is)" "$description" "$elapsed" >> "${BUILD_DIR}/iso-verification.log"
        rm -f "$log_file"
        return 0
    else
        status=$?
        _err "${description}: failed with exit code ${status} after ${elapsed}s."
        if (( status == 124 || status == 137 )); then
            _err "Operation exceeded the verification timeout (${ALTERNIX_VERIFY_TIMEOUT_SECONDS}s)."
        fi
        if [[ -s "$log_file" ]]; then
            _err "Command output (last 20 lines):"
            tail -20 "$log_file" >&2
        fi
        printf '%s | FAIL | %s | code=%s | %ss\n' "$(date -Is)" "$description" "$status" "$elapsed" >> "${BUILD_DIR}/iso-verification.log"
        rm -f "$log_file"
        return "$status"
    fi
}

# ── Single SquashFS for reliable live-boot ────────────────────────────
# live-boot failed mounting the previous 9-way OverlayFS lowerdir stack on
# real VirtualBox tests. Do not split filesystem.squashfs or generate a
# filesystem.module: use the original image created by live-build.
#
# A live-preview SquashFS above 4 GiB is a VALID file on ISO9660, but Rufus
# FAT32 **ISO extraction** cannot store it. For such images write the
# ISO as a raw hybrid image (Rufus DD mode, USBImager, or `dd`). The EFI
# system partition within the image is still FAT32. Net-install remains
# small enough for conventional FAT32 ISO extraction.
_verify_single_rootfs() {
    local live_dir="$BUILD_DIR/binary/live"
    local rootfs="$live_dir/filesystem.squashfs"
    local rootfs_bytes
    [[ -s "$rootfs" ]] || _die "Missing standard live/filesystem.squashfs."
    if [[ -e "$live_dir/filesystem.module" ]] || \
       compgen -G "$live_dir/filesystem-[0-9]*.squashfs" >/dev/null; then
        _die "Refusing a layered live rootfs: live-boot failed to overlay these layers in VirtualBox. Rebuild from scratch."
    fi
    rootfs_bytes=$(stat -c %s "$rootfs") || _die "Could not stat live root filesystem."
    unsquashfs -s "$rootfs" >/dev/null 2>&1 || _die "The live SquashFS image is corrupt."
    if (( rootfs_bytes > 4294967295 )); then
        if [[ "$ALTERNIX_BUILD_MODE" == net-install ]]; then
            _die "Net-install rootfs exceeds FAT32's per-file limit; investigate unexpected packages."
        fi
        _info "Live-preview has one $(du -h "$rootfs" | cut -f1) SquashFS."
        _info "This exceeds FAT32's 4 GiB FILE limit. Use Rufus DD/raw image mode, NOT ISO extraction mode."
        _info "The embedded EFI boot partition remains FAT32 for UEFI firmware."
    else
        _ok "Single live SquashFS fits FAT32 ($(du -h "$rootfs" | cut -f1))."
    fi
}

# ── Finish / verify an existing ISO without rebuilding ──────────────
# live-build may preserve `EFI/boot/bootia32.efi` (Claude's original
# Rufus ISO-mode layout). ISO9660 Rock Ridge filenames are case-sensitive
# to xorriso, even though the extracted FAT32 USB is case-insensitive.
# Therefore NEVER assume /EFI/BOOT/BOOTIA32.EFI when extracting from ISO.
# Use the exact relative filename from the binary/ tree instead.
_finalize_iso() {
    local existing_iso expected_ia32 expected_x64 visor_payload
    local iso_ia32_path iso_x64_path embedded_efi tmp copied size
    _step "Verifying and finalising existing ISO"
    command -v xorriso >/dev/null 2>&1 || _die "xorriso is required to verify an existing ISO."
    command -v mcopy >/dev/null 2>&1 || _die "mtools is required to verify an existing ISO."
    [[ -d "$BUILD_DIR/binary" ]] || \
        _die "Missing $BUILD_DIR/binary. Cannot finalise: the completed build files are absent."
    existing_iso=$(find "$BUILD_DIR" -maxdepth 1 -type f -name '*.iso' -print -quit)
    [[ -n "$existing_iso" && -s "$existing_iso" ]] || \
        _die "No completed ISO in $BUILD_DIR. Run the normal build if live-build did not generate one."
    expected_ia32=$(find "$BUILD_DIR/binary/EFI" -type f -iname bootia32.efi -print -quit 2>/dev/null)
    expected_x64=$(find "$BUILD_DIR/binary/EFI" -type f -iname bootx64.efi -print -quit 2>/dev/null)
    [[ -n "$expected_ia32" && -s "$expected_ia32" ]] || \
        _die "Missing IA32 GRUB from binary/EFI; this build cannot be finalised."
    [[ -n "$expected_x64" && -s "$expected_x64" ]] || \
        _die "Missing x64 loader from binary/EFI; this build cannot be finalised."
    iso_ia32_path="/${expected_ia32#"$BUILD_DIR/binary/"}"
    iso_x64_path="/${expected_x64#"$BUILD_DIR/binary/"}"
    # Only live-preview promises a prebuilt desktop; net-install downloads
    # AlternixDE later if the user selects it on the target machine.
    if [[ "$ALTERNIX_BUILD_MODE" == "live-preview" ]]; then
        [[ -s "$BUILD_DIR/chroot/etc/alternix/de-baked" ]] || \
            _die "The live-preview image has no prebuilt Alternix desktop."
    else
        [[ ! -e "$BUILD_DIR/chroot/etc/alternix/de-baked" ]] || \
            _die "Net-install unexpectedly contains a prebuilt AlternixDE marker."
    fi
    local sq_info
    [[ -s "$BUILD_DIR/binary/live/filesystem.squashfs" ]] || _die "Missing live filesystem.squashfs."
    _verify_single_rootfs
    sq_info=$(unsquashfs -s "$BUILD_DIR/binary/live/filesystem.squashfs" 2>&1) || \
        _die "Cannot read squashfs header."
    printf '%s\n' "$sq_info" | grep -Eq '^Compression[[:space:]]+(zstd|gzip|lz4)([[:space:]]|$)' || \
        _die "The existing image is not compressed with a fast tablet-friendly codec."
    embedded_efi="$BUILD_DIR/binary/boot/grub/efi.img"
    [[ -s "$embedded_efi" ]] || _die "Embedded EFI image missing from binary/boot/grub."

    _info "Actual ISO path for IA32 GRUB: $iso_ia32_path"
    _info "Actual ISO path for x64 loader: $iso_x64_path"
    if ! xorriso -indev "$existing_iso" -report_el_torito plain -report_system_area plain \
            > "$BUILD_DIR/iso-boot-report.txt" 2>&1; then
        _die "Cannot read boot metadata from $existing_iso."
    fi
    grep -Eq 'El Torito boot img.*UEFI' "$BUILD_DIR/iso-boot-report.txt" || \
        _die "Completed ISO lacks an El Torito UEFI boot image."

    tmp=$(mktemp -d) || _die "Cannot create temporary verification directory."
    if ! xorriso -osirrox on -indev "$existing_iso" \
         -extract /boot/grub/efi.img "$tmp/efi.img" >/dev/null 2>&1; then
        rm -rf "$tmp"
        _die "Completed ISO has no embedded EFI boot image."
    fi
    if ! cmp -s "$tmp/efi.img" "$embedded_efi"; then
        rm -rf "$tmp"
        _die "Completed ISO contains a stale EFI image that differs from binary/boot/grub/efi.img."
    fi
    if [[ "$(dd if="$tmp/efi.img" bs=1 skip=82 count=8 2>/dev/null)" != 'FAT32   ' ]]; then
        rm -rf "$tmp"
        _die "Embedded EFI image is not FAT32."
    fi
    for label in BOOTIA32.EFI BOOTX64.EFI; do
        if ! mcopy -o -i "$tmp/efi.img" "::/EFI/BOOT/$label" "$tmp/$label" >/dev/null 2>&1; then
            rm -rf "$tmp"
            _die "Completed ISO's embedded FAT32 boot image is missing $label."
        fi
    done
    if ! cmp -s "$tmp/BOOTIA32.EFI" "$expected_ia32" || \
       ! cmp -s "$tmp/BOOTX64.EFI" "$expected_x64"; then
        rm -rf "$tmp"
        _die "The completed ISO's embedded EFI loaders do not match binary/EFI."
    fi
    _ok "Embedded FAT32 boot image contains matching GRUB IA32 and x64 EFI loaders."

    # A Rufus ISO-mode USB uses the normal ISO tree. xorriso must use the
    # actual *case-preserved* Rock Ridge filenames, not canonical FAT names.
    if ! xorriso -osirrox on -indev "$existing_iso" \
         -extract "$iso_ia32_path" "$tmp/from-iso-ia32.efi" >/dev/null 2>&1; then
        _err "Expected file missing from ISO tree: $iso_ia32_path"
        _info "Actual /EFI entries recorded in ISO (for diagnosis):"
        xorriso -indev "$existing_iso" -find /EFI -type f -exec echo -- 2>&1 | tail -40 || true
        rm -rf "$tmp"
        _die "Completed ISO has no IA32 GRUB at its expected Rufus ISO-mode path."
    fi
    if ! xorriso -osirrox on -indev "$existing_iso" \
         -extract "$iso_x64_path" "$tmp/from-iso-x64.efi" >/dev/null 2>&1; then
        rm -rf "$tmp"
        _die "Completed ISO has no x64 loader at its expected Rufus ISO-mode path: $iso_x64_path"
    fi
    if ! cmp -s "$tmp/from-iso-ia32.efi" "$expected_ia32" || \
       ! cmp -s "$tmp/from-iso-x64.efi" "$expected_x64"; then
        rm -rf "$tmp"
        _die "One or both ISO-tree EFI loaders do not match the generated files."
    fi
    visor_payload="$BUILD_DIR/binary/EFI/visor/visor_x64.efi"
    if [[ -s "$visor_payload" ]] && ! cmp -s "$visor_payload" "$expected_x64"; then
        rm -rf "$tmp"
        _die "The completed ISO's x64 loader is not the generated Visor executable."
    fi
    rm -rf "$tmp"
    _ok "Finished ISO: 32-bit GRUB and 64-bit Visor verified in both boot layouts."

    _step "Finalising"
    _info "Copying finished ISO ($(du -h "$existing_iso" | cut -f1)) to $OUTPUT_ISO..."
    if ! _monitored_cmd "Copying final ISO" cp --reflink=auto "$existing_iso" "$OUTPUT_ISO"; then
        _die "Cannot copy finished ISO to $OUTPUT_ISO."
    fi
    [[ -s "$OUTPUT_ISO" ]] || _die "Final ISO copy is empty."
    size=$(du -sh "$OUTPUT_ISO" | cut -f1)
    _ok "Alternix installer ISO ready: $OUTPUT_ISO ($size)"
    if [[ "$ALTERNIX_BUILD_MODE" == live-preview ]] && \
       (( $(stat -c %s "$BUILD_DIR/binary/live/filesystem.squashfs") > 4294967295 )); then
        _info "WRITE USB AS A RAW IMAGE: Rufus DD mode / USBImager / Linux dd."
        _info "Do not use Rufus ISO extraction on FAT32: the SquashFS file exceeds 4 GiB."
    fi
    _info "Boot defaults: 32-bit UEFI = GRUB; 64-bit UEFI = Visor; legacy BIOS = GRUB."
}

# ── Root check ────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || _die "Run as root: sudo bash build-iso.sh"

# Two build profiles: a small network installer or a complete, prebuilt
# live desktop. --mode is provided for automated builds; normal use shows
# the requested choice menu before any downloads or build-directory cleanup.
if [[ "${1:-}" == '--finalize-existing' ]]; then
    [[ -s "$BUILD_DIR/chroot/etc/alternix/iso-mode" ]] || \
        _die "Cannot determine the existing ISO mode from build/chroot/etc/alternix/iso-mode."
    ALTERNIX_BUILD_MODE=$(cat "$BUILD_DIR/chroot/etc/alternix/iso-mode")
    case "$ALTERNIX_BUILD_MODE" in
        net-install|live-preview) ;;
        *) _die "Unknown existing ISO mode: $ALTERNIX_BUILD_MODE" ;;
    esac
    OUTPUT_ISO="${SCRIPT_DIR}/alternix-${ALTERNIX_BUILD_MODE}.iso"
    _finalize_iso
    exit 0
elif [[ "${1:-}" == '--mode' && $# -eq 2 ]]; then
    ALTERNIX_BUILD_MODE="$2"
elif [[ $# -eq 0 ]]; then
    _step "Choose AlternixOS x86-64 ISO build"
    printf '%s\n' \
        '  1) x86-64 net-install  — minimal installer; fetch AlternixDE from GitHub if selected' \
        '  2) x86-64 live-preview — prebuilt AlternixDE, Live boot, fast copy install (DD/raw USB if >4 GiB)' \
        ''
    if [[ ! -t 0 ]]; then
        _die "No interactive terminal. Specify --mode net-install or --mode live-preview."
    fi
    while true; do
        read -r -p '  Select ISO [1/2]: ' _build_choice
        case "$_build_choice" in
            1) ALTERNIX_BUILD_MODE=net-install; break ;;
            2) ALTERNIX_BUILD_MODE=live-preview; break ;;
            *) _err 'Choose 1 or 2.' ;;
        esac
    done
else
    _die "Usage: sudo bash build-iso.sh [--mode net-install|live-preview|--finalize-existing]"
fi
case "$ALTERNIX_BUILD_MODE" in
    net-install|live-preview) ;;
    *) _die "Invalid ISO mode: $ALTERNIX_BUILD_MODE (use net-install or live-preview)." ;;
esac
OUTPUT_ISO="${SCRIPT_DIR}/alternix-${ALTERNIX_BUILD_MODE}.iso"
_step "Building x86-64 $ALTERNIX_BUILD_MODE ISO"
if [[ "$ALTERNIX_BUILD_MODE" == "net-install" ]]; then
    _info 'No prebuilt desktop. The graphical/text installer will clone AlternixDE only if selected.'
else
    _info 'Prebuild AlternixDE into the ISO. Include Try Alternix (Live) and fast desktop copy.'
    _info 'Large images must be written to USB in raw/DD mode, not Rufus FAT32 ISO mode.'
fi

# ── Dependencies ──────────────────────────────────────────────────
_step "Checking dependencies"

# Both EFI platforms are required: amd64 for Visor/GRUB and i386-efi for
# tablets with 32-bit firmware. mtools/dosfstools rebuild the hybrid ISO ESP.
# IMPORTANT: `dpkg -l package` can exit 0 even for a "un" (not installed)
# package entry. Check the status string rather than the command exit code.
_pkg_installed() {
    [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == "install ok installed" ]]
}

missing_deps=()
for dep in live-build debootstrap xorriso grub-pc-bin grub-efi-amd64-bin grub-efi-ia32-bin grub2-common mtools dosfstools isolinux syslinux-utils; do
    if ! _pkg_installed "$dep"; then
        missing_deps+=("$dep")
    fi
done
if (( ${#missing_deps[@]} > 0 )); then
    _info "Installing missing build packages: ${missing_deps[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_deps[@]}" || \
        _die "Cannot install required build packages: ${missing_deps[*]} (check APT sources and run apt-get update)."
    for dep in "${missing_deps[@]}"; do
        _pkg_installed "$dep" || _die "Package $dep is still not installed after APT finished."
    done
fi

# Install Devuan keyring so debootstrap can verify signatures
if ! _pkg_installed devuan-keyring; then
    _info "Installing Devuan keyring..."
    # Fetch and install the keyring package directly
    # Find the actual current keyring deb from the pool index
    keyring_deb="/tmp/devuan-keyring.deb"
    keyring_url=$(wget -qO- "http://deb.devuan.org/devuan/pool/main/d/devuan-keyring/" 2>/dev/null |         grep -oP 'devuan-keyring_[^"]+_all\.deb' | sort -V | tail -1)
    if [[ -z "$keyring_url" ]]; then
        # Fallback to known version
        keyring_url="devuan-keyring_2022.09.04_all.deb"
    fi
    wget -q -O "$keyring_deb"         "http://deb.devuan.org/devuan/pool/main/d/devuan-keyring/${keyring_url}" ||         _die "Failed to fetch Devuan keyring."
    dpkg -i "$keyring_deb" &>/dev/null
    rm -f "$keyring_deb"
fi

# Export Devuan keyring for debootstrap
DEVUAN_KEYRING="/usr/share/keyrings/devuan-archive-keyring.gpg"
if [[ ! -f "$DEVUAN_KEYRING" ]]; then
    # Try alternate path
    DEVUAN_KEYRING=$(dpkg -L devuan-keyring 2>/dev/null | grep '\.gpg$' | head -1)
    [[ -z "$DEVUAN_KEYRING" ]] && _die "Devuan keyring GPG file not found after install."
fi
_info "Devuan keyring: ${DEVUAN_KEYRING}"

_ok "Dependencies OK."

# Fail before the slow live-build stage if the FAT image tools are absent.
# A binary hook may receive a different PATH, so it also searches absolute
# /usr/sbin and /sbin paths when choosing mkfs.fat.
export PATH="${PATH:-/usr/bin:/bin}:/usr/sbin:/sbin:/usr/local/sbin"
if ! command -v mcopy >/dev/null 2>&1 || ! command -v mdir >/dev/null 2>&1; then
    _die "mtools utilities (mcopy/mdir) not found. Install mtools on the build host."
fi
_fat_formatter_available() {
    local candidate
    for candidate in /usr/sbin/mkfs.fat /sbin/mkfs.fat \
                     /usr/sbin/mkfs.vfat /sbin/mkfs.vfat \
                     /usr/sbin/mkfs.msdos /sbin/mkfs.msdos \
                     mkfs.fat mkfs.vfat mkfs.msdos; do
        if command -v "$candidate" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}
if ! _fat_formatter_available; then
    _info "dosfstools is registered but its FAT formatter is missing; repairing installation..."
    DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y dosfstools || \
        _die "Could not reinstall dosfstools. Check APT sources and try: sudo apt-get install --reinstall dosfstools"
    hash -r
    _fat_formatter_available || \
        _die "FAT formatter still unavailable after reinstalling dosfstools. Check: dpkg -L dosfstools | grep mkfs"
fi
_ok "FAT image tools available."

# Regression guard: FAT12/16/32 labels are limited to 11 characters.
# Keep the embedded EFI image label short; this is independent of the
# ISO9660 volume name and does not change the firmware boot selection.
EFI_FAT_LABEL=ALTERNIX
[[ "${#EFI_FAT_LABEL}" -le 11 ]] || _die "EFI FAT volume label exceeds 11 characters."

# ── Clean build dir ───────────────────────────────────────────────
_step "Preparing build directory"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Also clean any live-build cache that may have stale chroot state
lb clean --purge 2>/dev/null || true
_ok "Build dir: ${BUILD_DIR}"

# ── Squashfs compression selection ────────────────────────────────
# COMPRESSION IS THE BIGGEST LEVER ON INSTALL TIME — DO NOT HARDCODE
# The copy install unpacks this squashfs onto the target, so the codec
# chosen here is paid back on every install on every machine. Rough
# single-core decompression rates: zstd 400+ MB/s, lz4 very fast but
# poor ratio, gzip 150-250 MB/s, xz only 20-40 MB/s. xz is the
# live-build default and would make a copy install SLOWER than
# debootstrap on an Atom.
#
# Which values are accepted varies by live-build version, so probe
# instead of assuming. Preference order is best-for-unpacking first.
_pick_compression() {
    local probe_dir c rc
    probe_dir="$(mktemp -d)"
    for c in zstd lz4 gzip xz; do
        rc=1
        ( cd "$probe_dir" && lb config --chroot-squashfs-compression-type "$c" ) >/dev/null 2>&1 && rc=0
        rm -rf "${probe_dir:?}"/* "${probe_dir:?}"/.??* 2>/dev/null || true
        if [[ $rc -eq 0 ]]; then
            rm -rf "$probe_dir"
            echo "$c"
            return 0
        fi
    done
    rm -rf "$probe_dir"
    # Nothing probed clean. Return empty so the caller omits the flag
    # entirely and lets live-build use its own default.
    echo ""
    return 1
}

_step "Selecting squashfs compression"
LB_COMPRESSION_CHOICE="$(_pick_compression || true)"
if [[ -z "$LB_COMPRESSION_CHOICE" ]]; then
    _info "Could not probe a supported codec — using live-build's default."
    _info "If that default is xz, copy installs will be slow to unpack."
    COMPRESSION_ARG=()
else
    COMPRESSION_ARG=(--chroot-squashfs-compression-type "$LB_COMPRESSION_CHOICE")
    case "$LB_COMPRESSION_CHOICE" in
        zstd) _ok  "Compression: zstd (fast to unpack, small)" ;;
        lz4)  _ok  "Compression: lz4 (fastest to unpack, larger ISO)" ;;
        gzip) _ok  "Compression: gzip (good unpack speed, larger ISO)" ;;
        xz)   _info "Compression: xz — smallest ISO but slow to unpack."
              _info "Copy installs will take noticeably longer on slow CPUs." ;;
    esac
fi

# ── live-build configuration ──────────────────────────────────────
_step "Configuring live-build"

lb config \
    --distribution "excalibur" \
    --archive-areas "main contrib non-free non-free-firmware" \
    --mirror-bootstrap "$DEVUAN_MIRROR" \
    --mirror-binary "$DEVUAN_MIRROR" \
    --mirror-chroot-security "$DEVUAN_MIRROR" \
    --mirror-binary-security "$DEVUAN_MIRROR" \
    --architectures "amd64" \
    --binary-images "iso-hybrid" \
    --bootloaders "grub-efi,grub-pc" \
    --iso-application "Alternix Installer" \
    --zsync "false" \
    --uefi-secure-boot "disable" \
    --memtest "none" \
    --iso-volume "Alternix-Installer" \
    --iso-application "Alternix Net Installer" \
    --iso-publisher "Alternix" \
    --apt-indices "false" \
    --apt-recommends "false" \
    --firmware-chroot "false" \
    --firmware-binary "false" \
    --apt-source-archives "false" \
    "${COMPRESSION_ARG[@]}" \
    --debootstrap-options "--variant=minbase --keyring=${DEVUAN_KEYRING}"

_ok "live-build configured."

# Override LB_INITSYSTEM — must be written to config/common after lb config runs.
# lb_chroot_live-packages reads LB_INITSYSTEM and installs live-config-${LB_INITSYSTEM}.
# Setting it to sysvinit installs live-config-sysvinit instead of live-config-systemd.
# Set LB_INITSYSTEM=none so live-build does not try to install live-config-systemd.
# We add live-config-sysvinit explicitly in our package list instead.
echo 'LB_INITSYSTEM="none"' >> config/common

# Do NOT let live-build auto-select every package which installs files into
# /lib/firmware.  It includes firmware-b43legacy-installer (and b43-installer),
# whose postinst downloads proprietary firmware from third-party URLs.
# On 2026-10-18 that download timed out in chroot, breaking the entire build.
# We list real, self-contained firmware packages explicitly below instead.
# Force the settings in config files as well as lb config flags; some live-build
# versions accept a flag but later regenerate defaults from config/common.
for _cfg in config/common config/chroot config/binary; do
    [[ -f "$_cfg" ]] || continue
    for _fw_var in LB_FIRMWARE_CHROOT LB_FIRMWARE_BINARY; do
        if grep -q "^${_fw_var}=" "$_cfg"; then
            sed -i "s|^${_fw_var}=.*|${_fw_var}=\"false\"|" "$_cfg"
        else
            printf '%s="false"\n' "$_fw_var" >> "$_cfg"
        fi
    done
done
_ok "Automatic firmware selection disabled; curated firmware packages retained."

# NO SOURCE PACKAGE INDICES — DO NOT RE-ENABLE
# live-build defaults to adding deb-src lines, so every apt-get update in
# the build also downloads the Sources indices. They are rewritten at
# each stage, so main/Sources (10.6 MB) was fetched about seven times
# per build — roughly 75 MB that nothing uses, since this build never
# compiles Debian source packages. Each download is also another chance
# of hitting a mirror mid-sync: a build failed on exactly that, with
# "File has unexpected size ... Mirror sync in progress?" on a Sources
# file. Written into the config file as well as passed as a flag, for
# the same reason as the compression setting below.
_src_set=0
for _cf in config/common config/bootstrap config/chroot config/binary config/source; do
    if grep -q '^LB_APT_SOURCE_ARCHIVES=' "$_cf" 2>/dev/null; then
        sed -i 's|^LB_APT_SOURCE_ARCHIVES=.*|LB_APT_SOURCE_ARCHIVES="false"|' "$_cf"
        _src_set=1
    fi
done
[[ $_src_set -eq 0 ]] && echo 'LB_APT_SOURCE_ARCHIVES="false"' >> config/common
_ok "Source package indices disabled."

# --compression controls source/tar archives, NOT filesystem.squashfs.
# The matching squashfs option and variable in live-build 20250505 are
# --chroot-squashfs-compression-type and LB_CHROOT_SQUASHFS_COMPRESSION_TYPE.
# Never silently fall back to slow xz on an Atom-class tablet.
if [[ -n "$LB_COMPRESSION_CHOICE" ]]; then
    for _cf in config/common config/binary; do
        if grep -q '^LB_CHROOT_SQUASHFS_COMPRESSION_TYPE=' "$_cf" 2>/dev/null; then
            sed -i "s|^LB_CHROOT_SQUASHFS_COMPRESSION_TYPE=.*|LB_CHROOT_SQUASHFS_COMPRESSION_TYPE=\"${LB_COMPRESSION_CHOICE}\"|" "$_cf"
        else
            printf 'LB_CHROOT_SQUASHFS_COMPRESSION_TYPE="%s"\n' "$LB_COMPRESSION_CHOICE" >> "$_cf"
        fi
    done
    _ok "Actual squashfs compression configured: ${LB_COMPRESSION_CHOICE}"
else
    _die "Cannot configure a fast squashfs codec. This would produce an exceptionally slow tablet installer."
fi

# Find and patch lb_chroot_live-packages to skip live-config-systemd.
# On Devuan, live-config-systemd doesn't exist and causes the build to fail.
# Patch /usr/lib/live/build/config to remove live-config-systemd and systemd-sysv.
# This file hardcodes these packages — we strip them out before lb build runs.
_LB_CONFIG="/usr/lib/live/build/config"
if [ -f "$_LB_CONFIG" ]; then
    sed -i 's/live-config-systemd systemd-sysv dracut-live dracut-config-generic dracut//g' "$_LB_CONFIG"
    sed -i 's/live-config live-config-systemd systemd-sysv//g' "$_LB_CONFIG"
    sed -i 's/NEEDED_PACKAGES="${NEEDED_PACKAGES} live-config-systemd systemd-sysv"//g' "$_LB_CONFIG"
    _ok "Patched: $_LB_CONFIG"
else
    die "Cannot find $_LB_CONFIG"
fi


# ── Devuan apt keyring for binary stage ───────────────────────────
_step "Configuring Devuan apt authentication"

mkdir -p config/archives
# Tell apt in the chroot to trust Devuan's key
cp "$DEVUAN_KEYRING" config/archives/devuan.key

# Only copy the keyring — live-build writes sources.list from --mirror flags.
# Adding devuan.list here causes "configured multiple times" warnings.


# ── Keep the live installer awake on all boot architectures ─────────
# Both IA32 UEFI and x64 UEFI launch the same amd64 live root filesystem.
# Mask systemd sleep targets by shipping /etc/systemd/system/* -> /dev/null,
# even though this Devuan ISO normally uses sysvinit/OpenRC rather than systemd.
# elogind is the actual seat/power manager on the live ISO; explicit config
# below is essential because masking systemd units alone does not stop it.
_step "Disabling installer suspend, hibernate and hybrid sleep"
LIVE_SLEEP_MASK_DIR="config/includes.chroot/etc/systemd/system"
mkdir -p "$LIVE_SLEEP_MASK_DIR" \
    config/includes.chroot/etc/elogind/sleep.conf.d \
    config/includes.chroot/etc/elogind/logind.conf.d \
    config/includes.chroot/etc/systemd/sleep.conf.d
for sleep_unit in sleep.target suspend.target hibernate.target \
                  hybrid-sleep.target suspend-then-hibernate.target; do
    ln -sfn /dev/null "$LIVE_SLEEP_MASK_DIR/$sleep_unit"
done
cat > config/includes.chroot/etc/elogind/sleep.conf.d/90-alternix-installer-awake.conf << 'AWAKEEOF'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
AWAKEEOF
cat > config/includes.chroot/etc/elogind/logind.conf.d/90-alternix-installer-awake.conf << 'AWAKEEOF'
[Login]
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
AWAKEEOF
# Kept as a defence-in-depth fallback if a different init is chosen.
cp config/includes.chroot/etc/elogind/sleep.conf.d/90-alternix-installer-awake.conf \
   config/includes.chroot/etc/systemd/sleep.conf.d/90-alternix-installer-awake.conf
_ok "Installer sleep targets masked; elogind suspend/hibernate disabled."

# ── Block systemd packages via apt preferences ────────────────────
mkdir -p config/includes.chroot/etc/apt/preferences.d
cat > config/includes.chroot/etc/apt/preferences.d/no-systemd << 'PREFEOF'
Package: systemd systemd-sysv systemd-shim live-config live-config-systemd
Pin: release *
Pin-Priority: -1
PREFEOF

# Block Rust coreutils (uutils) — GNU coreutils only.
# The Rust rewrite still has behavioural breakage; Alternix stays on GNU.
cat > config/includes.chroot/etc/apt/preferences.d/no-rust-coreutils << 'PREFEOF'
Package: rust-coreutils rust-coreutils-* uutils-coreutils coreutils-from-uutils
Pin: release *
Pin-Priority: -1

Package: coreutils
Pin: release *
Pin-Priority: 1001
PREFEOF

# ── Package list ──────────────────────────────────────────────────
_step "Writing package lists"

mkdir -p config/package-lists

cat > config/package-lists/alternix-installer.list.chroot << 'EOF'
# ── Init system (no systemd) ─────────────────────────────────────
sysvinit-core
openrc
elogind

# ── Shell + core utils ────────────────────────────────────────────
bash
busybox
coreutils
util-linux
procps
findutils
grep
sed
gawk
less
kmod

# ── Installer requirements ────────────────────────────────────────
debootstrap
parted
gdisk
e2fsprogs
dosfstools
lvm2

# ── Network tools ─────────────────────────────────────────────────
iproute2
iputils-ping
wget
curl
ca-certificates
net-tools
iw
wireless-tools
wpasupplicant
dhcpcd5
rfkill
ethtool
nftables

# ── Wired NIC firmware + drivers ──────────────────────────────────
# Realtek (r8168, r8169 — very common on desktops/laptops)
firmware-realtek
# Intel (e1000e, igb, ixgbe — Intel NICs)
# Broadcom NICs (bnx2, tg3)

# ── WiFi firmware ─────────────────────────────────────────────────
# Intel WiFi (iwlwifi — ThinkPads, modern laptops)
firmware-iwlwifi
# Atheros (ath9k, ath10k — common in many laptops)
firmware-atheros
# Realtek WiFi (rtl8192, rtlwifi)
firmware-realtek
# Broadcom WiFi (b43, brcmsmac — MacBooks, some laptops)
firmware-brcm80211
# Ralink/MediaTek (rt2800, mt7601 — USB dongles)
# Generic free firmware
firmware-linux-free
# Non-free catch-all (covers many remaining cards)

# ── USB drivers ───────────────────────────────────────────────────
# USB mass storage + HID are built into the kernel.
# These packages support USB network adapters and input:
# USB-to-Ethernet adapters (ASIX, CDC, RTL8150)
# already covered by kernel modules — no extra firmware needed.
# USB HID (keyboards, mice) — kernel built-in, no package needed.
# USB hub / xhci / ehci — kernel built-in.
# usbutils gives lsusb for diagnostics:
usbutils

# ── Keyboard / input ──────────────────────────────────────────────
# Console keyboard maps (essential — without this kbd may be wrong layout)
console-setup
kbd
# loadkeys is part of kbd — no separate package needed

# ── Storage / block ───────────────────────────────────────────────
# NVMe, SATA, USB storage — all kernel built-in on amd64.
# mdadm for RAID detection:
mdadm
# smartmontools for disk health:
smartmontools

# ── Boot ──────────────────────────────────────────────────────────
os-prober
grub2-common
grub-pc-bin
grub-efi-amd64-bin
grub-efi-ia32-bin

# ── Terminal / UI ─────────────────────────────────────────────────
tmux
ncurses-bin
xterm

# ── X server (graphical installer + AlternixDE live session) ─────
# XLibre and its input drivers are installed by the bundled AlternixDE
# installer during the desktop prebuild. Do not preinstall conflicting
# stock Xorg packages here. Missing modules fail the build validation.
xinit
x11-xserver-utils
x11-utils
xinput

# ── Qt5 runtime + build (osm-install and the osm-apps) ───────────
libqt5widgets5
libqt5gui5
libqt5core5a
libqt5dbus5
libqt5network5
libqt5svg5
qtbase5-dev
qtbase5-dev-tools
pkg-config
# Needed to link osm-install against Xlib for the embedded terminal.
# Comes in via qtbase5-dev today, listed explicitly so that a future
# change to that dependency cannot break the installer build silently.
libx11-dev

# ── Fonts ─────────────────────────────────────────────────────────
# DejaVu explicitly: some Noto faces lack digit glyphs, which makes
# fontconfig substitute a face that ignores the widget stylesheet.
fonts-dejavu-core
fonts-liberation2

# ── Copy-install requirements ─────────────────────────────────────
# unsquashfs unpacks the rootfs image onto the target. Without this
# package install_copy.sh cannot run at all.
squashfs-tools
rsync
ntfs-3g

# ── Privilege escalation ──────────────────────────────────────────
# Required for the AlternixDE prebuild and later installed system.
sudo

# ── Build tools ───────────────────────────────────────────────────
# seL4 has been dropped, so cmake, ninja-build, device-tree-compiler,
# gnu-efi, python3-yaml, python3-jinja2, python3-ply, python3-lxml
# and libxml2-utils are no longer pulled in. What remains is what the
# AlternixDE build and the qtile venv need.
git
build-essential
gcc
g++
make
python3
python3-pip
python3-dev
python3-venv
python3-setuptools
efibootmgr

# VISOR BUILD DEPENDENCY — DO NOT REMOVE
# Visor is the Alternix boot manager and is built from source during
# every install by _install_visor (install_base.sh:282). It needs
# gnu-efi to build. The live ISO runs with apt indices disabled, so
# the runtime `apt-get install -y gnu-efi` in that function cannot
# succeed on its own and the package has to be here. Without it the
# build fails with "visor_x64.efi not produced" and the install falls
# back to GRUB.
gnu-efi

# ── Extra firmware ────────────────────────────────────────────────
# COPY INSTALL REQUIREMENT — DO NOT TRIM
# Previously auto-discovered firmware, now explicitly selected.  These
# packages all resolved in the user's 2026-10-18 Excalibur build log.
# Crucially, omit firmware-b43-installer and firmware-b43legacy-installer:
# their post-install scripts fetch proprietary driver archives over the
# network and will abort the entire ISO build if a third-party host fails.
# firmware-brcm80211, below, still covers modern Broadcom adapters.
atmel-firmware
firmware-amd-graphics
firmware-ast
firmware-ath9k-htc
firmware-bnx2
firmware-bnx2x
firmware-carl9170
firmware-cavium
firmware-cirrus
firmware-intel-graphics
firmware-intel-misc
# Do not include firmware-ipw2x00 or firmware-ivtv in an unattended ISO build.
# Both require explicit licence acceptance in their dpkg preinst scripts;
# DEBIAN_FRONTEND=noninteractive cannot answer those questions, so dpkg exits 2.
# Older Intel PRO/Wireless 2100/2200/2915 and Hauppauge capture devices may
# need optional, interactive firmware installation after first boot.
firmware-linux
firmware-linux-nonfree
firmware-marvell-prestera
firmware-mediatek
firmware-myricom
firmware-netronome
firmware-netxen
firmware-nvidia-graphics
firmware-nvidia-tesla-535-gsp
firmware-qlogic
firmware-siano
firmware-zd1211
# The copy install has no network package step, so any firmware not
# baked into this image does not exist on the installed system. With
# debootstrap a missing WiFi blob could be fetched mid-install; here
# it cannot. The result would be a machine that installs perfectly
# and boots with no wireless.
firmware-misc-nonfree
firmware-libertas
firmware-ti-connectivity
firmware-sof-signed
firmware-intel-sound
intel-microcode
amd64-microcode

# ── Diagnostics ───────────────────────────────────────────────────
lshw
pciutils
fdisk
EOF

# Catch accidentally reintroduced packages that break unattended builds.
# B43 installer packages download external files while dpkg is configuring;
# ipw2x00 and ivtv have mandatory interactive EULA prompts during preinst.
# The APT non-recommends setting above ensures optional recommendations do not
# silently pull these packages in through firmware meta-packages.
if grep -Eq '^[[:space:]]*firmware-b43(legacy)?-installer([[:space:]]|$)' \
    config/package-lists/alternix-installer.list.chroot; then
    _die "Network-dependent Broadcom firmware installer packages must not be in the live image."
fi
if grep -Eq '^[[:space:]]*firmware-(ipw2x00|ivtv)([[:space:]]|$)' \
    config/package-lists/alternix-installer.list.chroot; then
    _die "firmware-ipw2x00 and firmware-ivtv require interactive licence acceptance; cannot install unattended."
fi
if [[ "$ALTERNIX_BUILD_MODE" == "net-install" ]]; then
    # Without the AlternixDE prebuild, XLibre is not installed. Provide
    # Xorg and libinput so osm-install still starts on tablets/touchscreens.
    cat >> config/package-lists/alternix-installer.list.chroot << 'NETXORG'
# Graphical net-installer display/input (no desktop environment)
xserver-xorg-core
xserver-xorg-input-libinput
xserver-xorg-video-fbdev
xserver-xorg-video-vesa
dbus-x11
NETXORG
fi
_ok "Firmware selection: unattended-safe packages; no third-party downloaders or licence prompts."
_ok "Package lists written."

# ── Copy installer scripts ────────────────────────────────────────
_step "Embedding installer scripts"

mkdir -p config/includes.chroot/installer config/includes.chroot/etc/alternix
printf '%s\n' "$ALTERNIX_BUILD_MODE" > config/includes.chroot/etc/alternix/iso-mode
cp -r "${SCRIPT_DIR}/installer/"* config/includes.chroot/installer/
chmod +x config/includes.chroot/installer/*.sh

_ok "Installer scripts embedded."

# ── live-boot package (required for boot=live to work) ────────────
# Add to package list
echo "live-boot" >> config/package-lists/alternix-installer.list.chroot
echo "live-boot-initramfs-tools" >> config/package-lists/alternix-installer.list.chroot
# live-config intentionally excluded — it pulls in live-config-systemd on Devuan.
# Autologin is handled by the profile.d script instead.

# ── Kernel module pre-load hook ───────────────────────────────────
mkdir -p config/hooks/normal
cat > config/hooks/normal/0050-alternix-modules.hook.chroot << 'HOOKEOF'
#!/bin/bash
set -e
# Ensure critical modules are available in the live env
# USB: xhci_hcd (USB3), ehci_hcd (USB2), ohci_hcd (USB1)
# HID: usbhid, hid_generic (keyboards/mice)
# Storage: usb_storage, uas (USB attached SCSI)
# NIC: r8169 (Realtek), e1000e (Intel), forcedeth (nForce)
# WiFi: iwlwifi, ath9k, ath10k_pci, brcmsmac, rtl8192ce
cat >> /etc/modules << EOF
xhci_hcd
ehci_hcd
ohci_hcd
usbhid
hid_generic
usb_storage
uas
r8169
e1000e
r8168
iwlwifi
iwl6000g2a
iwl6000g2b
ath9k
EOF
HOOKEOF
chmod +x config/hooks/normal/0050-alternix-modules.hook.chroot

# ── Console keyboard hook ─────────────────────────────────────────
cat > config/hooks/normal/0060-alternix-console.hook.chroot << 'HOOKEOF'
#!/bin/bash
set -e
# Set default console keyboard layout
echo 'XKBLAYOUT="gb"' >> /etc/default/keyboard || true
# Reconfigure console-setup if available
dpkg-reconfigure -f noninteractive console-setup 2>/dev/null || true
HOOKEOF
chmod +x config/hooks/normal/0060-alternix-console.hook.chroot

# ── Cursor theme ──────────────────────────────────────────────────
_step "Installing cursor theme"

CURSOR_SRC="${SCRIPT_DIR}/cursors/Bibata-Modern-Ice_tar.xz"
CURSOR_DEST="config/includes.chroot/usr/share/icons"

if [[ -f "$CURSOR_SRC" ]]; then
    mkdir -p "$CURSOR_DEST"
    tar -xf "$CURSOR_SRC" -C "$CURSOR_DEST"
    if [[ -d "${CURSOR_DEST}/Bibata-Modern-Ice/cursors" ]]; then
        # DEFAULT CURSOR THEME
        # There is no window manager or settings daemon in the live
        # session, so nothing applies a cursor theme on our behalf.
        # Xcursor resolves the theme literally named "default", so
        # shipping default/index.theme that inherits Bibata is what
        # makes X itself use it. XCURSOR_THEME in the launcher covers
        # the toolkit side.
        mkdir -p "${CURSOR_DEST}/default"
        cat > "${CURSOR_DEST}/default/index.theme" << 'CURSOREOF'
[Icon Theme]
Name=Default
Comment=Default cursor theme
Inherits=Bibata-Modern-Ice
CURSOREOF
        _ok "Cursor theme installed (Bibata-Modern-Ice)."
    else
        _info "Cursor archive unpacked but no cursors/ directory inside."
    fi
else
    _info "No cursor theme at ${CURSOR_SRC} - using the X default."
fi

# ── Conditional desktop prebuild and graphical installer (one chroot stage) ──
# Live-build executes this once, before compressing the final rootfs.
# There is no separate desktop build hook and no package-manager command rewriting.
_step "Configuring $ALTERNIX_BUILD_MODE desktop and graphical installer"

cat > config/hooks/normal/0090-osm-install.hook.chroot << 'HOOKEOF'
#!/bin/bash
# Compile the graphical installer inside the chroot, where Qt5 dev
# is present. Building here rather than on the host guarantees the
# binary matches the runtime libraries it will actually link against.
set -e

# This existing hook compiles osm-install in BOTH build modes. Desktop
# compilation is needed ONLY for live-preview; net-install uses the
# system-image base and installs the chosen desktop on the target later.
if [ "$(cat /etc/alternix/iso-mode 2>/dev/null)" = live-preview ]; then

# Build the live desktop and system-wide applications before compiling
# the installer GUI. This is still the same 0090 chroot stage.

DE_REPO="${ALTERNIXDE_REPO:-https://github.com/DansDesigns/AlternixDE}"

# Use the repo layout expected by the AlternixDE installer: the repo
# contains Alternix/ assets plus the root install script. The root user's
# home is the temporary build account; normal users inherit /etc/skel.
export HOME=/root
DE_DIR="${HOME}/Alternix"
BUILD_LOG=/tmp/alternixde-build.log
: > "$BUILD_LOG"

echo "  · Cloning AlternixDE into ${DE_DIR}..."
rm -rf "$DE_DIR"
if ! git clone --depth 1 "$DE_REPO" "$DE_DIR" >>"$BUILD_LOG" 2>&1; then
    echo "  x AlternixDE clone failed:"
    tail -20 "$BUILD_LOG" | sed 's/^/      /'
    exit 1
fi

cd "$DE_DIR"

if [ ! -d "$DE_DIR/Alternix/apps" ] || [ ! -d "$DE_DIR/Alternix/configs" ]; then
    echo '  x AlternixDE repo does not contain the expected desktop source and configs.'
    exit 1
fi

# Run the exact APT-only AlternixDE installer supplied with this ISO
# builder. Do not parse, sed-rewrite, or substitute package-manager
# commands from the cloned repository: command-shape assumptions caused
# repeated builds to fail before even attempting the desktop.
if [ ! -s /installer/install-alternix_devuan.sh ]; then
    echo '  x Bundled AlternixDE installer is missing from /installer.'
    exit 1
fi
cp -f /installer/install-alternix_devuan.sh "$DE_DIR/install-alternix_devuan.sh"
sed -i 's/\r$//' "$DE_DIR/install-alternix_devuan.sh"
chmod +x "$DE_DIR/install-alternix_devuan.sh"

# The desktop installer cleans up its source tree during installation.
# Stash the repository BEFORE running it so copy-installed systems still
# have the exact sources without downloading them again.
mkdir -p /usr/share/alternix
rm -rf /usr/share/alternix/AlternixDE
cp -a "$DE_DIR" /usr/share/alternix/AlternixDE

# Noninteractive build: username root; select "2" for any remaining
# optional prompts and Continue rather than reboot. The input stream stays
# open so the installer's read commands do not abort on EOF under set -e.
export TARGET_USER="root"
export DEBIAN_FRONTEND=noninteractive
# `clear` on line 3 of that script fails under TERM=dumb or an unset
# TERM, and `set -e` on line 2 then kills it with no output.
export TERM=xterm

echo "  · Building AlternixDE (this takes a while; output -> ${BUILD_LOG})"

# BUILD WRAPPERS — see /installer/de-shims.sh. They supply the
# noninteractive auto-cpufreq installer selection, register its OpenRC
# service without probing missing chroot CPU governors, and defer actual
# daemon startup until boot on real hardware.
_de_shims_active=0
cleanup_de_build_shims() {
    if [ "$_de_shims_active" = 1 ] && [ -f /installer/de-shims.sh ]; then
        bash /installer/de-shims.sh remove / || true
    fi
}
trap cleanup_de_build_shims EXIT
if [ -f /installer/de-shims.sh ]; then
    bash /installer/de-shims.sh add / >>"$BUILD_LOG" 2>&1 || {
        echo '  x Could not install temporary build shims.'
        exit 1
    }
    _de_shims_active=1
    export PATH="/usr/local/lib/alternix-de-shims:${PATH}"
else
    echo '  x /installer/de-shims.sh missing.'
    exit 1
fi

set +e
{ echo "root"; yes 2; } | \
    timeout 7200 bash install-alternix_devuan.sh >>"$BUILD_LOG" 2>&1
DE_RC=$?
set -e

# Remove temporary wrappers whether the build succeeded or not.
cleanup_de_build_shims
_de_shims_active=0
trap - EXIT

if [ "$DE_RC" -ne 0 ]; then
    echo "  x AlternixDE prebuild failed (exit ${DE_RC})."
    [ "$DE_RC" -ne 124 ] || echo '  x Desktop build exceeded the 2-hour timeout.'
    echo '  ---- Last 70 lines from the desktop installation log ----'
    tail -70 "$BUILD_LOG" | sed 's/^/      /'
    echo '  ---- APT dependency status ----'
    apt-get check 2>&1 | tail -25 | sed 's/^/      /' || true
    echo '  x No ISO will be issued without the complete prebuilt desktop.'
    exit 1
fi

# SKEL COPY — DO NOT REMOVE
# The build writes configs into the building user's home. The real user
# does not exist yet — configure_system.sh creates them during the
# install — so copying into /etc/skel is what gives whoever is created
# later a working desktop.
for d in .config .local/share; do
    if [ -d "${HOME}/${d}" ]; then
        mkdir -p "/etc/skel/${d}"
        cp -a "${HOME}/${d}/." "/etc/skel/${d}/" 2>/dev/null || true
    fi
done

# SUDOERS CLEANUP — DO NOT REMOVE
# install-alternix_devuan.sh:66 writes a permanent NOPASSWD rule so its
# own sudo calls do not expire mid-build, and never removes it. Left in
# place it would ship passwordless root on every installed machine.
rm -f /etc/sudoers.d/alternix-nopasswd

# Source repository was retained before the installer ran, because that
# installer may delete its working directory as its final cleanup step.
if [ ! -f /usr/share/alternix/AlternixDE/install-alternix_devuan.sh ]; then
    echo '  x Preserved AlternixDE source is missing.'
    exit 1
fi
echo '  + AlternixDE source retained for copy-installed systems.'

# A zero exit code alone is insufficient: check the essential desktop,
# window manager and its applications before certifying the live image.
for binary in /root/.qtile_venv/bin/qtile /usr/local/bin/osm-launcher \
              /usr/local/bin/osm-settings /usr/local/bin/osm-files; do
    if [ ! -x "$binary" ]; then
        echo "  x AlternixDE reports success but required binary is missing: $binary"
        tail -60 "$BUILD_LOG" 2>/dev/null || true
        exit 1
    fi
done
[ -f /root/.config/qtile/config.py ] || {
    echo '  x Alternix Qtile configuration is absent from the built image.'
    exit 1
}
# The build ran as root, but installation creates an ordinary user.
# The venv in /root is inaccessible to that user. The upstream installer
# also installs a system-wide qtile; verify it and configure the new
# user's session to use that executable, not /root/.qtile_venv.
QTILE_GLOBAL=$(command -v qtile 2>/dev/null || true)
if [ -z "$QTILE_GLOBAL" ] || [ ! -x "$QTILE_GLOBAL" ]; then
    echo '  x System-wide Qtile is missing; a copied installation would not log in.'
    exit 1
fi
# The desktop installer initially links this path to root's private venv.
# Copy-installed users cannot access /root: point it to the global binary.
mkdir -p /usr/lib/udev
ln -sfn "$QTILE_GLOBAL" /usr/lib/udev/qtile
cat > /etc/skel/.xinitrc <<'USERXINIT'
#!/bin/sh
exec dbus-launch --exit-with-session /usr/local/bin/qtile start
USERXINIT
# Resolve qtile's actual location in case the distro uses /usr/bin.
sed -i "s|/usr/local/bin/qtile|${QTILE_GLOBAL}|" /etc/skel/.xinitrc
chmod 755 /etc/skel/.xinitrc
cat > /etc/skel/.bash_profile <<'USERBASH'
# Log in on tty1 to start the installed Alternix desktop.
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = /dev/tty1 ]; then
    exec startx
fi
USERBASH
mkdir -p /etc/alternix
rm -f /etc/alternix/de-missing
printf 'Built into the live filesystem by Alternix ISO Maker\n' > /etc/alternix/de-baked
# The build-time Alternix script auto-starts X from root/.bash_profile.
# On live media /etc/profile.d/alternix-installer.sh handles the choice
# between install and live mode. Prevent a second unintended X session.
printf '# Alternix live session startup is handled by /etc/profile.d/alternix-installer.sh\n' > /root/.bash_profile
cd /
rm -rf "$DE_DIR"
rm -f "$BUILD_LOG"
echo "  + AlternixDE desktop and applications prebuilt and validated."
else
    echo '  + Net-install mode: skipping AlternixDE clone/build inside the ISO.'
    rm -f /etc/alternix/de-baked
fi
# ── Graphical installer ──────────────────────────────────────────
SRC="/installer/osm-install.cpp"
[ -f "$SRC" ] || { echo "  x ${SRC} not found."; exit 1; }

echo "  · Compiling osm-install..."
# -lX11 is required: the embedded terminal calls XSetInputFocus to put
# the keyboard onto xterm, because with no window manager running
# nothing else will.
g++ -std=c++17 -Wall -Wextra -O2 -fPIC \
    -I/installer \
    "$SRC" -o /usr/local/bin/osm-install \
    $(pkg-config --cflags --libs Qt5Widgets) -lX11 || {
        echo "  x osm-install failed to compile."
        exit 1
    }
chmod 755 /usr/local/bin/osm-install

# Both modes require real input drivers for the graphical installer.
# The live-preview has XLibre and net-install has Xorg/libinput.
if ! find /usr/lib -name '*_drv.so' -print -quit 2>/dev/null | grep -q .; then
    echo '  x No Xorg/XLibre input driver modules found after desktop prebuild.'
    exit 1
fi
echo '  + X input drivers installed.'
if ! command -v Xorg >/dev/null 2>&1 && \
   ! command -v XLibre >/dev/null 2>&1 && \
   ! command -v X >/dev/null 2>&1; then
    echo '  x No Xorg/XLibre display server executable found.'
    exit 1
fi

# alternix-net resolves its own directory, so it stays in /installer
# alongside network.sh. Just make sure it is executable.
chmod +x /installer/alternix-net 2>/dev/null || true

echo "  + osm-install compiled."
HOOKEOF
chmod +x config/hooks/normal/0090-osm-install.hook.chroot

_ok "Graphical installer stage and $ALTERNIX_BUILD_MODE desktop policy configured."

# ── Auto-launch installer on boot ────────────────────────────────
_step "Configuring auto-launch"

# 1. Write inittab to autologin root on tty1 via a chroot hook
#    (inittab exists in the chroot because we install sysvinit-core)
mkdir -p config/hooks/normal
cat > config/hooks/normal/0070-alternix-autologin.hook.chroot << 'HOOKEOF'
#!/bin/bash
# Replace tty1 getty with autologin getty
if [ -f /etc/inittab ]; then
    # Comment out existing tty1 line and add autologin version
    sed -i "s|^1:.*:respawn:.*tty1.*|#&|" /etc/inittab
    echo "1:2345:respawn:/sbin/agetty --autologin root --noclear tty1 38400 linux" >> /etc/inittab
fi
HOOKEOF
chmod +x config/hooks/normal/0070-alternix-autologin.hook.chroot

# 2. profile.d script launches installer once root is logged in
mkdir -p config/includes.chroot/etc/profile.d
cat > config/includes.chroot/etc/profile.d/alternix-installer.sh << 'EOF'
#!/bin/bash
# Auto-launch the Alternix installer if running as root on tty1.
#
# Graphical by default. Three of the four reference machines are
# tablets with no keyboard attached, so a TUI is unusable on them.
# The text installer stays reachable from the GRUB menu, which adds
# alternix.tui=1 to the kernel command line.

[ "$(id -u)" -eq 0 ] || return 0
[ "$(tty)" = "/dev/tty1" ] || return 0
[ -f /installer/install.sh ] || return 0

# Do not relaunch if we are already inside the X session.
[ -n "${DISPLAY:-}" ] && return 0

_want_tui=0
grep -qw "alternix.tui=1" /proc/cmdline 2>/dev/null && _want_tui=1
[ -x /usr/local/bin/osm-install ] || _want_tui=1
command -v startx >/dev/null 2>&1 || _want_tui=1

# A separate boot entry selects the real Alternix desktop without opening
# the installer. Do not start an incomplete/unbaked desktop.
if grep -qw 'alternix.live=1' /proc/cmdline 2>/dev/null; then
    if [ ! -s /etc/alternix/de-baked ] || \
       [ ! -x /root/.qtile_venv/bin/qtile ]; then
        echo 'Alternix Live is unavailable: this image has no prebuilt desktop.'
        echo 'The ISO builder must complete the AlternixDE build first.'
        return 0
    fi
    export XCURSOR_THEME=Bibata-Modern-Ice
    export XCURSOR_SIZE=24
    echo 'Starting Alternix Live. Launch osm-install to install from this session.'
    startx /usr/local/bin/alternix-live-session -- -nolisten tcp vt1 \
        > /tmp/alternix-live-xorg.log 2>&1
    echo 'Live desktop ended. Run: startx /usr/local/bin/alternix-live-session'
    return 0
fi

if [ "$_want_tui" -eq 0 ]; then
    # Cursor theme for the installer session. Xcursor reads these
    # from the environment; without them Qt falls back to the stock
    # black X cursors regardless of what is installed.
    export XCURSOR_THEME=Bibata-Modern-Ice
    export XCURSOR_SIZE=24

    startx /usr/local/bin/osm-install -- -nolisten tcp vt1 \
        > /tmp/alternix-xorg.log 2>&1
    echo ""
    echo "Graphical installer exited. You are now at a shell."
    echo "To restart graphical: startx /usr/local/bin/osm-install"
    echo "To use text mode:     bash /installer/install.sh"
    echo "X log:                /tmp/alternix-xorg.log"
else
    # Use bash not exec so Ctrl+C drops back to this shell
    bash /installer/install.sh
    echo ""
    echo "Installer exited. You are now at a shell."
    echo "To restart: bash /installer/install.sh"
    echo "To view log: cat /tmp/alternix-install.log | tail -50"
fi
EOF
chmod +x config/includes.chroot/etc/profile.d/alternix-installer.sh

# In live-preview, the full desktop is separate from the installer.
# This launch script is inert in net-install, which has no Live boot entry.
mkdir -p config/includes.chroot/usr/local/bin \
         config/includes.chroot/usr/share/applications
cat > config/includes.chroot/usr/local/bin/alternix-live-session << 'LIVEEOF'
#!/bin/sh
export HOME=/root
export XDG_CONFIG_HOME=/root/.config
export XDG_CACHE_HOME=/root/.cache
export XDG_DATA_HOME=/root/.local/share
export PATH=/root/.qtile_venv/bin:/usr/local/bin:/usr/bin:/bin
cd /root || exit 1
[ -x /root/.qtile_venv/bin/qtile ] || {
    echo 'Alternix Qtile executable is missing from live image.' >&2
    exit 1
}
exec dbus-launch --exit-with-session /root/.qtile_venv/bin/qtile start
LIVEEOF
chmod +x config/includes.chroot/usr/local/bin/alternix-live-session
cat > config/includes.chroot/usr/share/applications/alternix-install.desktop << 'LIVEDESKTOP'
[Desktop Entry]
Type=Application
Name=Install Alternix
Comment=Install Alternix from the live desktop
Exec=/usr/local/bin/osm-install
Icon=system-software-install
Terminal=false
Categories=System;
LIVEDESKTOP
_ok "Installer and selectable live desktop startup configured."

# ── GRUB config ───────────────────────────────────────────────────
_step "Configuring GRUB menu"

mkdir -p config/bootloaders/grub-pc
mkdir -p config/bootloaders/grub-efi

cat > config/bootloaders/grub-pc/grub.cfg << 'EOF'
set default=0
set timeout=5

if background_image /boot/grub/background.png; then
    set color_normal=cyan/black
    set color_highlight=white/cyan
fi

# Unversioned names are created by the 9999 binary hook.
menuentry "Install Alternix" {
    search --no-floppy --file --set=root /live/vmlinuz
    linux /live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer quiet
    initrd /live/initrd.img
}

menuentry "Try Alternix (Live)" {
    search --no-floppy --file --set=root /live/vmlinuz
    linux /live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer alternix.live=1 quiet
    initrd /live/initrd.img
}

menuentry "Install Alternix (text mode)" {
    search --no-floppy --file --set=root /live/vmlinuz
    linux /live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer alternix.tui=1 quiet
    initrd /live/initrd.img
}

menuentry "Install Alternix (nomodeset)" {
    search --no-floppy --file --set=root /live/vmlinuz
    linux /live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer nomodeset
    initrd /live/initrd.img
}

menuentry "Install Alternix (safe mode, text)" {
    search --no-floppy --file --set=root /live/vmlinuz
    linux /live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer alternix.tui=1 noapic noacpi nomodeset
    initrd /live/initrd.img
}
EOF

if [[ "$ALTERNIX_BUILD_MODE" == "net-install" ]]; then
    # No full desktop exists on this image; do not offer a broken Live option.
    sed -i '/^menuentry "Try Alternix (Live)" {/,/^}/d' \
        config/bootloaders/grub-pc/grub.cfg
fi
cp config/bootloaders/grub-pc/grub.cfg config/bootloaders/grub-efi/grub.cfg

# Copy GRUB background from branding folder if present
mkdir -p config/bootloaders/grub-pc
mkdir -p config/bootloaders/grub-efi
BRANDING_IMG="${SCRIPT_DIR}/branding/grub-background.png"
if [[ -f "$BRANDING_IMG" ]]; then
    cp "$BRANDING_IMG" config/bootloaders/grub-pc/background.png
    cp "$BRANDING_IMG" config/bootloaders/grub-efi/background.png
    # Also embed in the live filesystem so grub finds it at boot
    mkdir -p config/includes.chroot/boot/grub
    cp "$BRANDING_IMG" config/includes.chroot/boot/grub/background.png
    _ok "GRUB background: ${BRANDING_IMG}"
else
    _info "No branding/grub-background.png found — GRUB will use default background."
    _info "Place a PNG at: ${SCRIPT_DIR}/branding/grub-background.png"
fi

_ok "GRUB config written."

# Add a binary hook to rewrite grub.cfg with the actual kernel filename
mkdir -p config/hooks/normal
cat > config/hooks/normal/9999-fix-grub-kernel.hook.binary << 'HOOKEOF'
#!/bin/sh
# KERNEL PATH FIX — DO NOT REMOVE
# Binary hooks run with cwd = the ISO binary/ directory.
# Copy the versioned kernel/initrd to unversioned names so the
# grub.cfg /live/vmlinuz and /live/initrd.img paths always work.
set -e
VMLINUZ=$(ls live/vmlinuz-* 2>/dev/null | sort | tail -1)
INITRD=$(ls live/initrd.img-* 2>/dev/null | sort | tail -1)
if [ -n "$VMLINUZ" ]; then
    cp "$VMLINUZ" live/vmlinuz
    echo "Copied $VMLINUZ -> live/vmlinuz"
else
    echo "WARNING: no live/vmlinuz-* found in $(pwd)"
    ls live/ || true
fi
if [ -n "$INITRD" ]; then
    cp "$INITRD" live/initrd.img
    echo "Copied $INITRD -> live/initrd.img"
fi
HOOKEOF
chmod +x config/hooks/normal/9999-fix-grub-kernel.hook.binary

# ── EFI boot menu: Visor (64-bit), standalone GRUB (32-bit) ───────
# A plain bootia32.efi does NOT automatically gain the live-build GRUB
# configuration. Build a self-contained i386-efi GRUB with its own text
# installer menu embedded in the EFI executable. This works from both a
# file-copied FAT USB (Rufus ISO mode) and the hybrid ISO's EFI image.
# Never chainload Visor from i386-efi: Visor only supports x86_64 EFI.
_step "Preparing 32-bit UEFI GRUB text menu"

EFI_STAGE="config/includes.binary/alternix-efi-stage"
rm -rf "$EFI_STAGE"
mkdir -p "$EFI_STAGE"

if [[ -f "${SCRIPT_DIR}/efi/bootia32.efi" || -f "${SCRIPT_DIR}/efi/BOOTIA32.EFI" ]]; then
    _info "Existing efi/bootia32.efi found; using a newly built standalone GRUB instead."
    _info "This ensures 32-bit EFI loads the installer menu rather than trying Visor."
fi

# Embedded IA32 GRUB menu with two independent UEFI display routes.
# Several early x86 tablet firmwares do not present a usable EFI Simple Text
# Output Protocol (black screen), even though GOP has a working framebuffer.
# Keep console active for devices which already work (such as Linx tablets),
# while *appending* GOP-backed gfxterm when the firmware supports it. Do not
# replace console with gfxterm: that would regress other tablets.
# Both the font and config live inside BOOTIA32.EFI's GRUB memdisk.
cat > "$EFI_STAGE/grub-ia32.cfg" << 'IA32CFG'
set default=0
set timeout=12
set pager=1
terminal_input console
terminal_output console
set color_normal=white/black
set color_highlight=black/light-gray

echo 'Alternix: IA32 GRUB entered using UEFI console.'
# Try graphics WITHOUT turning off firmware console. No reliance on files
# located on the EFI System Partition or the external ISO filesystem.
if insmod efi_gop; then
    if insmod gfxterm; then
        if loadfont $prefix/fonts/unicode.pf2; then
            set gfxmode=auto
            if terminal_output --append gfxterm; then
                set gfxpayload=keep
                echo 'Alternix: GOP framebuffer text output enabled.'
            fi
        fi
    fi
fi
echo 'Alternix: 32-bit UEFI GRUB started (64-bit firmware uses Visor).'

# GRUB can see ISO9660 media (dd) and FAT USB sticks (Rufus ISO mode).
# Do NOT search for the ESP: on dd media it only contains bootloaders.
menuentry "Install Alternix" {
    search --no-floppy --file --set=root /live/vmlinuz
    linux /live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer quiet
    initrd /live/initrd.img
}

menuentry "Try Alternix (Live)" {
    search --no-floppy --file --set=root /live/vmlinuz
    linux /live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer alternix.live=1 quiet
    initrd /live/initrd.img
}
menuentry "Install Alternix (text mode)" {
    search --no-floppy --file --set=root /live/vmlinuz
    linux /live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer alternix.tui=1 quiet
    initrd /live/initrd.img
}
menuentry "Install Alternix (nomodeset)" {
    search --no-floppy --file --set=root /live/vmlinuz
    linux /live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer nomodeset
    initrd /live/initrd.img
}
menuentry "Install Alternix (safe mode, text)" {
    search --no-floppy --file --set=root /live/vmlinuz
    linux /live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer alternix.tui=1 noapic noacpi nomodeset
    initrd /live/initrd.img
}
# Explicitly report kernel messages and avoid i915 if EFI->kernel handoff
# causes a blank screen. This is only an alternative entry, not the default.
menuentry "Install Alternix (verbose / Intel graphics off)" {
    search --no-floppy --file --set=root /live/vmlinuz
    linux /live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer alternix.tui=1 nomodeset i915.modeset=0 loglevel=7 ignore_loglevel plymouth.enable=0
    initrd /live/initrd.img
}
# A no-kernel boot check; useful when a machine can show the GRUB menu but
# hangs as soon as Linux is selected. It makes no disk modifications.
menuentry "Diagnostics: verify GRUB and boot files (no Linux)" {
    echo "Alternix EFI diagnostic (firmware arch: $grub_cpu/$grub_platform)"
    if search --no-floppy --file --set=root /live/vmlinuz; then
        echo "PASS: /live/vmlinuz found on $root"
        if test -f /live/initrd.img; then
            echo "PASS: /live/initrd.img found"
        else
            echo "ERROR: /live/initrd.img is missing"
        fi
    else
        echo "ERROR: /live/vmlinuz not found: USB layout/media unreadable"
    fi
    echo 'Select any key to return to the GRUB menu.'
    read
}
IA32CFG
if [[ "$ALTERNIX_BUILD_MODE" == "net-install" ]]; then
    sed -i '/^menuentry "Try Alternix (Live)" {/,/^}/d' "$EFI_STAGE/grub-ia32.cfg"
fi

# Only load real i386-efi modules. There is NO search_fs_label.mod in
# Debian/Devuan GRUB; the label-search module is called search_label.mod.
# This menu searches by file, so search_fs_file is sufficient.
IA32_GRUB_MOD_DIR="/usr/lib/grub/i386-efi"
[[ -d "$IA32_GRUB_MOD_DIR" ]] || \
    _die "Missing $IA32_GRUB_MOD_DIR. Install grub-efi-ia32-bin on the BUILD host."
command -v grub-mkstandalone >/dev/null || \
    _die "grub-mkstandalone is missing (install grub2-common)."
IA32_GRUB_MODULES=(
    normal linux part_gpt part_msdos fat iso9660 udf ext2
    search search_fs_file configfile read test
)
for module in "${IA32_GRUB_MODULES[@]}"; do
    [[ -f "$IA32_GRUB_MOD_DIR/${module}.mod" ]] || \
        _die "Missing $IA32_GRUB_MOD_DIR/${module}.mod; reinstall grub-efi-ia32-bin."
done
# GOP is optional: retain the old EFI console-only loader if one of the
# graphics components or the embedded font is not available on the host.
IA32_FONT_ARG='--fonts='
IA32_GOP_MODULES=(efi_gop gfxterm font video video_fb)
IA32_GOP_READY=1
for module in "${IA32_GOP_MODULES[@]}"; do
    if [[ ! -f "$IA32_GRUB_MOD_DIR/${module}.mod" ]]; then
        _info "Optional i386-efi graphics module unavailable: $module"
        IA32_GOP_READY=0
    fi
done
if [[ ! -s /usr/share/grub/unicode.pf2 ]]; then
    _info 'GRUB Unicode font unavailable; GOP text output will not be enabled.'
    IA32_GOP_READY=0
fi
if (( IA32_GOP_READY )); then
    IA32_GRUB_MODULES+=("${IA32_GOP_MODULES[@]}")
    IA32_FONT_ARG='--fonts=unicode'
    _info 'Embedding GOP text-output support alongside UEFI console output.'
else
    _info 'Keeping original UEFI console-only output (GOP prerequisites missing).'
fi
_info "Using verified i386-efi GRUB modules (file-search installer menu)."
# The grafted grub.cfg and optional font live inside the GRUB memdisk.
if ! grub-mkstandalone -O i386-efi \
    -o "$EFI_STAGE/bootia32.efi" \
    "$IA32_FONT_ARG" --locales="" --themes="" \
    --modules="${IA32_GRUB_MODULES[*]}" \
    "boot/grub/grub.cfg=$EFI_STAGE/grub-ia32.cfg"; then
    _die "Cannot build 32-bit GRUB; verify grub-efi-ia32-bin/grub2-common. ISO must not be marked as IA32-bootable."
fi
[[ -s "$EFI_STAGE/bootia32.efi" ]] || _die "32-bit GRUB EFI file is empty."
_ok "Standalone i386-efi GRUB built with installer choices and a boot-file diagnostic."

# The firmware itself selects the EFI executable on removable media:
#     EFI/BOOT/BOOTIA32.EFI  -> i386-efi GRUB (text installer)
#     EFI/BOOT/BOOTX64.EFI  -> Visor (when available)
# No per-device loader switching or external USB patch is necessary.

# Build Visor inside the chroot, where gnu-efi and gcc already are. The
# result is kept at /usr/share/alternix/visor so it serves two purposes:
# the ISO boot menu (via the binary hook below) and the installed system
# (install_base.sh uses it instead of cloning and compiling at install
# time, which previously failed whenever gnu-efi or the network did).
# ── Reproducible Visor EFI executable selection ──────────────────
# By default, follow upstream HEAD (same as previous releases). A known-
# working installed visor_x64.efi can instead be imported into
# visor/visor_x64.efi using ./import-working-visor.sh. This is the best
# regression test when one older UEFI device boots an earlier Visor build.
# VISOR_GIT_REF is an optional tag/commit to test a specific upstream build.
VISOR_OVERRIDE_FILE="${SCRIPT_DIR}/visor/visor_x64.efi"
if [[ -f "$VISOR_OVERRIDE_FILE" ]]; then
    _step "Using supplied working Visor EFI executable"
    [[ -f "${SCRIPT_DIR}/visor/check-efi.py" ]] || \
        _die "Missing visor/check-efi.py validation helper."
    command -v python3 >/dev/null || _die "python3 is required to validate supplied Visor EFI."
    python3 "${SCRIPT_DIR}/visor/check-efi.py" "$VISOR_OVERRIDE_FILE" || \
        _die "The supplied Visor file is not an x64 UEFI application."
    mkdir -p config/includes.chroot/usr/share/alternix/visor
    cp "$VISOR_OVERRIDE_FILE" config/includes.chroot/usr/share/alternix/visor/visor_x64.efi
    # Reuse matching icons from the known-working ESP when supplied locally.
    if compgen -G "${SCRIPT_DIR}/visor/icons/*.png" >/dev/null; then
        mkdir -p config/includes.chroot/usr/share/alternix/visor/icons
        cp "${SCRIPT_DIR}/visor/icons/"*.png config/includes.chroot/usr/share/alternix/visor/icons/
    fi
    if [[ -s "${SCRIPT_DIR}/visor/logo.png" ]]; then
        cp "${SCRIPT_DIR}/visor/logo.png" config/includes.chroot/usr/share/alternix/visor/logo.png
    fi
    printf 'Local EFI executable SHA256: %s\n' "$(sha256sum "$VISOR_OVERRIDE_FILE" | cut -d' ' -f1)" \
        > config/includes.chroot/usr/share/alternix/visor/SOURCE-REVISION.txt
    _ok "Prebuilt Visor included: $(sha256sum "$VISOR_OVERRIDE_FILE" | cut -d' ' -f1)"
    if [[ -n "${VISOR_GIT_REF:-}" ]]; then
        _info "VISOR_GIT_REF ignored because a local working EFI executable was supplied."
    fi
elif [[ -n "${VISOR_GIT_REF:-}" ]]; then
    # No shell evaluation: the hook reads a single git revision token.
    [[ "$VISOR_GIT_REF" =~ ^[a-zA-Z0-9._/-]+$ ]] || \
        _die "VISOR_GIT_REF contains unexpected characters."
    mkdir -p config/includes.chroot/etc
    printf '%s\n' "$VISOR_GIT_REF" > config/includes.chroot/etc/alternix-visor-git-ref
    _info "Pinning upstream Visor to revision: $VISOR_GIT_REF"
else
    _info "Visor source: latest upstream HEAD (set VISOR_GIT_REF to freeze revision)."
fi

cat > config/hooks/normal/0085-visor.hook.chroot << 'HOOKEOF'
#!/bin/bash
# Build the Visor boot manager. Non-fatal: if this fails the ISO keeps
# live-build's GRUB as its boot menu and installs fall back to building
# Visor on the target, as they did before.
DEST=/usr/share/alternix/visor
LOG=/tmp/visor-build.log
rm -rf /tmp/visor-build

# config/includes.chroot is populated before the chroot hooks. When a user
# supplies their KNOWN WORKING installed Visor, do not download and silently
# replace it with a possibly incompatible newer build.
if [ -s "$DEST/visor_x64.efi" ]; then
    echo "  + Using known-working Visor EFI supplied by the ISO builder."
    sha256sum "$DEST/visor_x64.efi"

    # An imported EFI binary does not contain the external PNG assets.
    # Visor resolves installer entry names to icons/linux.png; without it,
    # the GUI shows placeholder squares even though the loader itself works.
    # Preserve the supplied loader exactly, but fetch/copy assets separately.
    mkdir -p "$DEST/icons" "$DEST/backgrounds"
    if [ ! -s "$DEST/icons/linux.png" ] || [ ! -s "$DEST/icons/unknown.png" ]; then
        echo "  · Restoring Visor menu icons for the supplied EFI loader..."
        if ! timeout --kill-after=10s 120s git clone --depth 1 -q \
                https://github.com/IO-ZetZor/Visor-BootManager.git \
                /tmp/visor-build >"$LOG" 2>&1; then
            echo "  ! Cannot obtain Visor icons; original EFI binary remains unchanged."
            tail -10 "$LOG"
            exit 1
        fi
        cp /tmp/visor-build/assets/icons/*.png       "$DEST/icons/"       2>/dev/null || true
        cp /tmp/visor-build/assets/backgrounds/*.png "$DEST/backgrounds/" 2>/dev/null || true
        cp /tmp/visor-build/assets/logo.png "$DEST/logo.png" 2>/dev/null || true
        rm -rf /tmp/visor-build "$LOG"
    fi
    if [ ! -s "$DEST/icons/linux.png" ] || [ ! -s "$DEST/icons/unknown.png" ]; then
        echo "  ! Missing required Visor PNG icons (linux.png / unknown.png)."
        exit 1
    fi
    echo "  + Visor icons available; supplied EFI executable was not replaced."
    exit 0
fi
rm -rf "$DEST"

# If requested, use a SPECIFIC upstream git revision for reproducible tests.
# Missing/bad explicit ref must be fatal, never fall back to another version.
VISOR_REF=""
if [ -s /etc/alternix-visor-git-ref ]; then
    VISOR_REF=$(head -n 1 /etc/alternix-visor-git-ref)
fi

echo "  · Building upstream Visor boot manager..."
if ! git clone --depth 1 -q https://github.com/IO-ZetZor/Visor-BootManager.git \
        /tmp/visor-build >"$LOG" 2>&1; then
    if [ -n "$VISOR_REF" ]; then
        echo "  ! Could not download requested Visor revision: $VISOR_REF";
        tail -5 "$LOG"; exit 1
    fi
    echo "  ! Visor clone failed — ISO will use GRUB."; tail -5 "$LOG"; exit 0
fi
if [ -n "$VISOR_REF" ]; then
    echo "  · Selecting Visor upstream revision: $VISOR_REF"
    if ! git -C /tmp/visor-build fetch --depth 1 origin "$VISOR_REF" >>"$LOG" 2>&1 || \
       ! git -C /tmp/visor-build checkout --detach FETCH_HEAD >>"$LOG" 2>&1; then
        echo "  ! Requested Visor revision unavailable: $VISOR_REF"
        tail -15 "$LOG"
        exit 1
    fi
fi
VISOR_COMMIT=$(git -C /tmp/visor-build rev-parse HEAD 2>/dev/null || true)

# ARCH=x86_64 matches the upstream Makefile; it builds a PE32+ EFI app.
if ! ( cd /tmp/visor-build && make ARCH=x86_64 ) >>"$LOG" 2>&1 || \
   [ ! -s /tmp/visor-build/visor_x64.efi ]; then
    echo "  ! Visor build failed — ISO will use GRUB. Last lines:"
    tail -15 "$LOG" | sed 's/^/      /'
    rm -rf /tmp/visor-build; exit 0
fi

mkdir -p "$DEST/icons" "$DEST/backgrounds"
cp /tmp/visor-build/visor_x64.efi "$DEST/"
cp /tmp/visor-build/assets/icons/*.png       "$DEST/icons/"       2>/dev/null || true
cp /tmp/visor-build/assets/backgrounds/*.png "$DEST/backgrounds/" 2>/dev/null || true
cp /tmp/visor-build/assets/logo.png "$DEST/logo.png" 2>/dev/null || true
printf 'Visor source: https://github.com/IO-ZetZor/Visor-BootManager\nCommit: %s\n' "$VISOR_COMMIT" > "$DEST/SOURCE-REVISION.txt"
rm -rf /tmp/visor-build "$LOG"
echo "  + Visor built from commit $VISOR_COMMIT ($(stat -c %s "$DEST/visor_x64.efi") bytes)."
HOOKEOF
chmod +x config/hooks/normal/0085-visor.hook.chroot

cat > config/hooks/normal/9998-alternix-efi.hook.binary << 'HOOKEOF'
#!/bin/sh
# Runs in binary/ after binary_grub-efi, before the ISO is assembled.
STAGE="alternix-efi-stage"
VISOR="../chroot/usr/share/alternix/visor"

# Restore Claude's proven Rufus ISO-mode x64 layout: do not rename or
# reconstruct live-build's existing EFI/boot directory. On ISO9660 the
# spelling and layout matter; Rufus copies this tree onto the FAT32 USB.
# Keep a single directory to avoid name collisions on case-insensitive FAT.
BOOTDIR=$(find EFI -mindepth 1 -maxdepth 1 -type d -iname boot 2>/dev/null | head -1)
if [ "$(find EFI -mindepth 1 -maxdepth 1 -type d -iname boot 2>/dev/null | wc -l)" -gt 1 ]; then
    echo "efi: ERROR multiple differently cased EFI boot directories would collide on FAT32"
    exit 1
fi
if [ -z "$BOOTDIR" ]; then
    mkdir -p EFI/boot || exit 1
    BOOTDIR=EFI/boot
fi

# EFI.IMG HAS NO ROOM TO SPARE — DO NOT GO BACK TO A PLAIN mcopy
# Sticks written with dd, Etcher or Rufus in DD mode boot from
# boot/grub/efi.img, not from the EFI folder. live-build sizes that
# image to fit its own small loaders with only ~55 KB spare, so copying
# a full 32-bit loader over live-build's one failed with "Disk full",
# the image kept live-build's loader, and 32-bit tablets would not boot
# until bootia32.efi was copied onto the stick by hand. The image is
# now rebuilt with room for it.
# live-build may execute binary hooks with /usr/sbin and /sbin missing
# from PATH. On current Debian/Devuan, dosfstools normally installs
# /usr/sbin/mkfs.fat (mkfs.msdos is only an optional compatibility link).
# Include standard admin directories and test the executable itself.
PATH="${PATH:-/usr/bin:/bin}:/usr/sbin:/sbin:/usr/local/sbin"
export PATH

efi_img_put() {   # $1 = 32-bit loader to place in boot/grub/efi.img
    IMG=boot/grub/efi.img
    MKFS=""
    for candidate in \
        /usr/sbin/mkfs.fat /sbin/mkfs.fat \
        /usr/sbin/mkfs.vfat /sbin/mkfs.vfat \
        /usr/sbin/mkfs.msdos /sbin/mkfs.msdos \
        mkfs.fat mkfs.vfat mkfs.msdos; do
        # command -v accepts both absolute paths and commands in PATH.
        if command -v "$candidate" >/dev/null 2>&1; then
            MKFS=$(command -v "$candidate")
            break
        fi
    done
    if [ -z "$MKFS" ] || [ ! -x "$MKFS" ]; then
        echo "efi: ERROR: dosfstools mkfs.fat executable is unavailable (tried /usr/sbin/mkfs.fat)."
        return 1
    fi
    for utility in mcopy mdir; do
        if ! command -v "$utility" >/dev/null 2>&1; then
            echo "efi: ERROR: $utility is unavailable (install mtools on the build host)."
            return 1
        fi
    done
    echo "efi: building embedded FAT image with $MKFS"
    export MTOOLS_SKIP_CHECK=1
    TMP=$(mktemp -d)
    mcopy -s -n -i "$IMG" '::*' "$TMP/" || { rm -rf "$TMP"; return 1; }

    # EFI directory names are case-insensitive once copied into FAT32.
    # Normalise the original live-build tree before inserting IA32 GRUB,
    # avoiding both `efi/boot` and `EFI/BOOT` appearing on Linux.
    OLDEFI=$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -iname efi | head -1)
    if [ -n "$OLDEFI" ] && [ "$OLDEFI" != "$TMP/EFI" ]; then
        [ ! -e "$TMP/EFI" ] || { echo "efi: ERROR duplicate EFI directories"; rm -rf "$TMP"; return 1; }
        mv "$OLDEFI" "$TMP/EFI" || { rm -rf "$TMP"; return 1; }
    fi
    if [ -d "$TMP/EFI" ]; then
        OLDBOOT=$(find "$TMP/EFI" -mindepth 1 -maxdepth 1 -type d -iname boot | head -1)
        if [ -n "$OLDBOOT" ] && [ "$OLDBOOT" != "$TMP/EFI/BOOT" ]; then
            [ ! -e "$TMP/EFI/BOOT" ] || { echo "efi: ERROR duplicate BOOT directories"; rm -rf "$TMP"; return 1; }
            mv "$OLDBOOT" "$TMP/EFI/BOOT" || { rm -rf "$TMP"; return 1; }
        fi
    fi
    mkdir -p "$TMP/EFI/BOOT"
    find "$TMP" -type f -iname bootia32.efi -exec rm -f {} +
    cp "$1" "$TMP/EFI/BOOT/BOOTIA32.EFI" || { rm -rf "$TMP"; return 1; }

    # On raw/DD-written USB media firmware reads this FAT EFI image, NOT
    # the ISO9660 /EFI directory. The previous build left BOOTX64.EFI as
    # GRUB here even after Visor had been built successfully. Stage the
    # same x64 Visor menu, boot.conf, kernel and initrd in this image so
    # x64 firmware sees the working installed-system style boot layout.
    if [ -s "EFI/visor/visor_x64.efi" ] && [ -s "$BOOTDIR/$N64" ]; then
        [ -s EFI/visor/boot.conf ] || {
            echo "efi: ERROR: Visor exists but boot.conf is missing"
            rm -rf "$TMP"; return 1
        }
        # Save GRUB before replacing the original x64 boot file. Prefer
        # the ISO tree fallback, which is guaranteed to contain the GRUB
        # loader before Visor was installed. Handle either filename case
        # from live-build's original FAT image.
        ORIGINAL_X64=$(find "$TMP/EFI/BOOT" -maxdepth 1 -type f \
            -iname bootx64.efi -print -quit)
        if [ -s "$BOOTDIR/grubx64-alternix.efi" ]; then
            cp "$BOOTDIR/grubx64-alternix.efi" \
                "$TMP/EFI/BOOT/grubx64-alternix.efi" || {
                rm -rf "$TMP"; return 1
            }
        elif [ -n "$ORIGINAL_X64" ] && [ -s "$ORIGINAL_X64" ]; then
            cp "$ORIGINAL_X64" "$TMP/EFI/BOOT/grubx64-alternix.efi" || {
                rm -rf "$TMP"; return 1
            }
        else
            echo "efi: ERROR: no x64 GRUB fallback for Visor"
            rm -rf "$TMP"; return 1
        fi
        # IMPORTANT: Linux filesystems are case-sensitive; FAT32 is not.
        # An original bootx64.efi and a new BOOTX64.EFI are different files
        # in TMP, but COLLIDE on FAT32. The second mcopy can silently
        # overwrite the first. Remove ALL case variants BEFORE inserting
        # Visor, so exactly one canonical BOOTX64.EFI enters the image.
        find "$TMP/EFI/BOOT" -maxdepth 1 -type f -iname bootx64.efi \
            -exec rm -f {} +
        cp "$BOOTDIR/$N64" "$TMP/EFI/BOOT/BOOTX64.EFI" || {
            rm -rf "$TMP"; return 1
        }
        X64_COPIES=$(find "$TMP/EFI/BOOT" -maxdepth 1 -type f \
            -iname bootx64.efi | wc -l)
        if [ "$X64_COPIES" -ne 1 ]; then
            echo "efi: ERROR: expected exactly one x64 EFI loader, found $X64_COPIES"
            rm -rf "$TMP"; return 1
        fi
        echo "efi: canonical BOOTX64.EFI staged (no FAT32 case collision)"
        rm -rf "$TMP/EFI/visor"
        cp -R EFI/visor "$TMP/EFI/visor" || { rm -rf "$TMP"; return 1; }
        mkdir -p "$TMP/live"
        for name in vmlinuz initrd.img; do
            source_file=""
            if [ -s "live/$name" ]; then
                source_file="live/$name"
            else
                # Match the last versioned file selected by the 9999
                # unversioned-kernel hook (lexicographic sort order).
                for candidate in "live/$name"-*; do
                    [ -s "$candidate" ] && source_file="$candidate"
                done
            fi
            if [ -z "$source_file" ]; then
                echo "efi: ERROR: missing live/$name for FAT32 Visor boot"
                rm -rf "$TMP"; return 1
            fi
            cp "$source_file" "$TMP/live/$name" || { rm -rf "$TMP"; return 1; }
            echo "efi: staged $source_file for x64 Visor on raw USB media"
        done
        echo "efi: x64 Visor, its configuration, kernel and initrd staged in FAT32 EFI image"
    fi

    # Many tablet UEFI implementations are picky about FAT12/FAT16 boot
    # images. mkfs.fat otherwise auto-selects a small FAT type. Use an
    # explicit FAT32 ESP of at least 64 MiB for the hybrid ISO image.
    # Preserve original live-build files (including the x64 loader).
    KB=$(du -sk "$TMP" | cut -f1)
    KB=$(( (KB + 8192 + 1023) / 1024 * 1024 ))
    [ "$KB" -ge 65536 ] || KB=65536
    rm -f "$IMG.new"
    # FAT volume labels are at most 11 characters. The old label
    # ALTERNIX_EFI (12 characters) caused mkfs.fat to abort here after
    # the whole live-build chroot had already completed.
    EFI_FAT_LABEL=ALTERNIX
    if [ "${#EFI_FAT_LABEL}" -gt 11 ]; then
        echo "efi: ERROR FAT label is longer than 11 characters: $EFI_FAT_LABEL"
        rm -rf "$TMP" "$IMG.new"
        return 1
    fi
    if "$MKFS" -F 32 -n "$EFI_FAT_LABEL" -C "$IMG.new" "$KB" >/dev/null && \
       mcopy -s -i "$IMG.new" "$TMP"/* ::/ && \
       mdir -i "$IMG.new" ::/EFI/BOOT/BOOTIA32.EFI >/dev/null 2>&1; then
        # Detect x64 replacement failures HERE, before the final ISO is
        # assembled. In particular, catch FAT32 case-insensitive filename
        # collisions that can silently restore live-build's old GRUB.
        if [ -s "EFI/visor/visor_x64.efi" ]; then
            FAT_X64_CHECK=$(mktemp -d)
            if ! mcopy -o -i "$IMG.new" ::/EFI/BOOT/BOOTX64.EFI \
                    "$FAT_X64_CHECK/BOOTX64.EFI" >/dev/null 2>&1; then
                echo 'efi: ERROR: rebuilt FAT32 image cannot extract BOOTX64.EFI'
                rm -rf "$FAT_X64_CHECK" "$TMP" "$IMG.new"
                return 1
            fi
            if ! cmp -s "$FAT_X64_CHECK/BOOTX64.EFI" "$BOOTDIR/$N64"; then
                echo 'efi: ERROR: rebuilt FAT32 image has a different x64 loader (not Visor)'
                sha256sum "$BOOTDIR/$N64" "$FAT_X64_CHECK/BOOTX64.EFI" 2>/dev/null || true
                rm -rf "$FAT_X64_CHECK" "$TMP" "$IMG.new"
                return 1
            fi
            rm -rf "$FAT_X64_CHECK"
            echo 'efi: verified embedded BOOTX64.EFI is Visor (matching SHA256 bytes)'
        fi
        # FAT32 has its type signature at offset 82 in the boot sector.
        FAT_TYPE=$(dd if="$IMG.new" bs=1 skip=82 count=8 2>/dev/null)
        if [ "$FAT_TYPE" = 'FAT32   ' ]; then
            mv -f "$IMG.new" "$IMG"
            rm -rf "$TMP"
            return 0
        fi
        echo "efi: ERROR embedded EFI filesystem is not FAT32."
    fi
    rm -rf "$TMP" "$IMG.new"
    return 1
}

# Match Claude's existing 64-bit loader filename and directory casing.
# This preserves the layout Rufus ISO mode presented to the ElitePad.
# EFI firmware still chooses by architecture: IA32 GRUB vs x64 Visor.
X64=$(find "$BOOTDIR" -maxdepth 1 -type f -iname bootx64.efi | head -1)
case "$(basename "${X64:-bootx64.efi}")" in
    BOOTX64.EFI) N32="BOOTIA32.EFI"; N64="BOOTX64.EFI" ;;
    *)           N32="bootia32.efi"; N64="bootx64.efi" ;;
esac
echo "efi: existing boot directory $BOOTDIR; x64 loader name $N64"

# ── 32-bit loader ─────────────────────────────────────────────────
if [ ! -s "$STAGE/bootia32.efi" ]; then
    echo "efi: ERROR missing standalone 32-bit GRUB"
    exit 1
fi
# IA32 GRUB is independent of x64 Visor. Match existing filename case
# to avoid accidentally creating duplicate files when Rufus extracts to FAT32.
find "$BOOTDIR" -maxdepth 1 -type f -iname bootia32.efi -exec rm -f {} +
cp "$STAGE/bootia32.efi" "$BOOTDIR/$N32" || exit 1
echo "efi: 32-bit GRUB text selector installed as $BOOTDIR/$N32"

# Both the ISO tree and the embedded FAT EFI boot image are populated.
# EFI image rebuilding runs AFTER Visor's configuration is written so
# extracted USB, DD USB and optical EFI media present the same menus.

# The 32-bit GRUB is installed automatically for every ISO and every USB.
# Do not add device-specific bootloader switch scripts or compatibility files.

# ── Visor as the 64-bit boot menu ─────────────────────────────────
# Visor reads kernels and initrds from the FAT filesystem that launched
# it. Stage these files into the embedded FAT image for DD-written media,
# not only into the ordinary ISO tree used by extracted FAT USB media.
if [ -f "$VISOR/visor_x64.efi" ]; then
    mkdir -p EFI/visor/icons EFI/visor/backgrounds
    cp "$VISOR/visor_x64.efi" EFI/visor/
    # Retain provenance for comparing EFI executables across ISO builds.
    if [ -f "$VISOR/SOURCE-REVISION.txt" ]; then
        cp "$VISOR/SOURCE-REVISION.txt" EFI/visor/SOURCE-REVISION.txt
    fi
    cp "$VISOR/icons/"*.png       EFI/visor/icons/       2>/dev/null || true
    cp "$VISOR/backgrounds/"*.png EFI/visor/backgrounds/ 2>/dev/null || true
    if [ -s "$VISOR/logo.png" ]; then
        cp "$VISOR/logo.png" EFI/visor/logo.png || exit 1
    fi
    # An existing filename is not sufficient: reject truncated or non-PNG
    # files before embedding them in either boot medium. Keep Visor's own
    # supplied icon art, not a synthetic placeholder image.
    for icon_name in linux unknown; do
        icon_path="EFI/visor/icons/$icon_name.png"
        if [ ! -s "$icon_path" ]; then
            echo "efi: ERROR missing required Visor icon: $icon_path"
            exit 1
        fi
        png_header=$(head -c 8 "$icon_path" | od -An -tx1 | tr -d ' \n')
        if [ "$png_header" != 89504e470d0a1a0a ]; then
            echo "efi: ERROR invalid PNG signature: $icon_path"
            exit 1
        fi
    done

    # Restore Claude's original installer background and Visor menu setup.
    # These are only for 64-bit Rufus ISO-mode booting; IA32 uses GRUB.
    BG=""
    if [ -f ../chroot/boot/grub/background.png ]; then
        cp ../chroot/boot/grub/background.png EFI/visor/backgrounds/alternix.png
        BG='background=\EFI\visor\backgrounds\alternix.png'
    fi

    # Keep GRUB as a menu entry rather than discarding it, so any
    # machine Visor struggles with still has a way in.
    GRUB_BACKUP=""
    if [ -n "$X64" ] && [ -f "$X64" ]; then
        mv "$X64" "$BOOTDIR/grubx64-alternix.efi"
        GRUB_BACKUP="\\$(printf '%s' "$BOOTDIR" | tr '/' '\\')\\grubx64-alternix.efi"
    fi
    cp "$VISOR/visor_x64.efi" "$BOOTDIR/$N64"

    # PRINTF, NEVER ECHO — DO NOT CHANGE
    # This hook runs under /bin/sh, which is dash, and dash's echo
    # interprets backslash escapes. Visor paths are full of backslashes:
    # "\live\vmlinuz" had its \v turned into a vertical tab, and "\boot"
    # into a backspace, so every entry pointed at a file that does not
    # exist. printf '%s\n' prints its argument exactly as given.
    CMD="boot=live components live-config.username=root live-config.autologin=root pci=noaer"
    KERN='\live\vmlinuz'
    INITRD='\live\initrd.img'

    # Names such as "Install Alternix" do not match an upstream distro icon.
    # Explicit absolute ESP paths prevent Visor from drawing its fallback
    # coloured square when automatic icon-name lookup fails.  All these
    # images are copied both to EFI/visor/ and into the embedded FAT32 ESP.
    LINUX_ICON='\EFI\visor\icons\linux.png'
    FALLBACK_ICON='\EFI\visor\icons\unknown.png'
    entry() {  # $1 name, $2 extra cmdline
        printf '%s\n' "" "entry {" \
            "    name    = \"$1\"" \
            "    icon    = $LINUX_ICON" \
            "    kernel  = $KERN" \
            "    initrd  = $INITRD" \
            "    cmdline = \"$CMD $2\"" \
            "}"
    }

    {
        # Match Claude's original working 64-bit Visor menu configuration.
        # Keep the flags, menu ordering and background unchanged: do not
        # force graphics, logging, self-heal or resolution overrides here.
        printf '%s\n' "timeout=10" "default=0" "title=Alternix Installer"
        [ -n "$BG" ] && printf '%s\n' "$BG"
        entry "Install Alternix"                   "quiet"
        if [ "$(cat ../chroot/etc/alternix/iso-mode 2>/dev/null)" = live-preview ]; then
            entry "Try Alternix (Live)"           "alternix.live=1 quiet"
        fi
        entry "Install Alternix (text mode)"       "alternix.tui=1 quiet"
        entry "Install Alternix (nomodeset)"       "nomodeset"
        entry "Install Alternix (safe mode, text)" "alternix.tui=1 noapic noacpi nomodeset"
        if [ -n "$GRUB_BACKUP" ]; then
            printf '%s\n' "" \
                "# A PE image with no initrd or cmdline is chainloaded." \
                "entry {" \
                "    name    = \"GRUB menu (fallback)\"" \
                "    icon    = $FALLBACK_ICON" \
                "    kernel  = $GRUB_BACKUP" \
                "}"
        fi
    } > EFI/visor/boot.conf
    echo "efi: Visor installed as $BOOTDIR/$N64 (GRUB kept as a menu entry)"
else
    if [ -n "$X64" ] && [ -s "$X64" ] && [ "$X64" != "$BOOTDIR/$N64" ]; then
        mv "$X64" "$BOOTDIR/$N64" || exit 1
    fi
    echo "efi: Visor not built; the ISO keeps live-build's x64 GRUB menu."
fi

# Rebuild after Visor and its config have been placed into the ISO tree.
# Do not assume that the ISO9660 EFI/ directory is the removable-media
# ESP; x64 and IA32 firmware boot the ESP in boot/grub/efi.img on DD USB.
if [ -f boot/grub/efi.img ]; then
    if efi_img_put "$STAGE/bootia32.efi"; then
        echo "efi: IA32 GRUB and x64 boot files embedded in boot/grub/efi.img ($(du -k boot/grub/efi.img | cut -f1) KB)"
    else
        echo "efi: ERROR cannot rebuild embedded EFI image; see preceding mkfs.fat/mtools error"
        exit 1
    fi
else
    echo "efi: ERROR boot/grub/efi.img is missing; DD-written UEFI media could not boot"
    exit 1
fi

rm -rf "$STAGE"
HOOKEOF
chmod +x config/hooks/normal/9998-alternix-efi.hook.binary
_ok "EFI boot menu hook written."

# ── Build ─────────────────────────────────────────────────────────
_step "Building Devuan ISO (automatic package mirror failover)"

LB_LOG="${BUILD_DIR}/lb-build.log"
ATTEMPTS_LOG="${BUILD_DIR}/lb-build-attempts.log"
: > "$ATTEMPTS_LOG"

# Retry the *actual lb build* invocation, which invokes lb bootstrap internally.
# An earlier version only retried a separate 'lb bootstrap' call, leaving the
# subsequent 'lb build' free to fail at the same download step without retrying.
# The raw final attempt goes in lb-build.log; every attempt and chosen mirror
# is retained in lb-build-attempts.log for diagnostics.
#
# Default: Devuan's recommended official endpoint, then two independently
# hosted package mirrors. The independent hosts have their own /merged trees;
# this is not an ISO/CD-image mirror. Do not mix in Debian package repositories.
# Custom DEVUAN_MIRROR values are honoured and retried once without override.
BOOTSTRAP_MIRRORS=("$DEVUAN_MIRROR" "$DEVUAN_MIRROR")
if [[ "${DEVUAN_MIRROR%/}" == 'http://deb.devuan.org/merged' ]]; then
    BOOTSTRAP_MIRRORS=(
        'http://deb.devuan.org/merged'
        'https://ftp.fau.de/devuan/merged'
        'https://ftp.fau.de/devuan/merged'
        'https://mirror.mirohost.net/devuan/merged'
    )
fi

# Update the live-build configs for every stage, not just bootstrap. The
# source and binary stages must use the same package source as the chroot.
_switch_live_build_mirror() {
    local old="$1" new="$2" cfg contents
    [[ "$old" == "$new" ]] && return 0
    for cfg in config/common config/bootstrap config/chroot config/binary config/source; do
        [[ -f "$cfg" ]] || continue
        contents="$(< "$cfg")"
        contents="${contents//"$old"/"$new"}"
        printf '%s\n' "$contents" > "$cfg"
    done
    DEVUAN_MIRROR="$new"
}

_build_succeeded=0
for (( _try=0; _try<${#BOOTSTRAP_MIRRORS[@]}; _try++ )); do
    _mirror="${BOOTSTRAP_MIRRORS[$_try]}"
    if (( _try > 0 )); then
        _info "Cleaning partial build before changing mirrors..."
        # --purge removes partial caches/state but retains config/, hooks,
        # package lists and installer assets created earlier in this script.
        if ! lb clean --purge >> "$ATTEMPTS_LOG" 2>&1; then
            _die "Cannot clean failed build. See $ATTEMPTS_LOG"
        fi
        _switch_live_build_mirror "$DEVUAN_MIRROR" "$_mirror"
    fi
    printf '\n==== Build attempt %s/%s | mirror: %s ====\n' \
        "$((_try + 1))" "${#BOOTSTRAP_MIRRORS[@]}" "$_mirror" | tee -a "$ATTEMPTS_LOG"
    _info "Using Devuan mirror: $_mirror"
    _info "Running live-build attempt $((_try + 1))/${#BOOTSTRAP_MIRRORS[@]}"

    # Do not use 'lb bootstrap' here: run the command that really generates
    # the ISO, and check its exit status independently of tee's status.
    set +e
    lb build 2>&1 | tee "$LB_LOG" | while IFS= read -r line; do
        echo "  ${line}"
    done
    _build_rc=${PIPESTATUS[0]}
    set -e
    {
        printf '\n==== Attempt %s | mirror: %s | exit: %s ====\n' \
            "$((_try + 1))" "$_mirror" "$_build_rc"
        cat "$LB_LOG"
    } >> "$ATTEMPTS_LOG"

    if (( _build_rc == 0 )) && ! grep -qE '^E:|^lb build failed|efi: ERROR' "$LB_LOG"; then
        _build_succeeded=1
        _ok "ISO build completed using $_mirror"
        break
    fi

    # Only automatically repeat if we know the failure was in debootstrap's
    # network download step. Re-running after a failed hook could repeat a
    # large build and conceal an unrelated defect.
    if ! grep -Eqi "couldn.t download (package|packages)|failed to fetch|unable to fetch|mirror sync in progress|temporary failure resolving|connection (failed|timed out)|network is unreachable|404 not found" "$LB_LOG" \
       || ! grep -Eq 'lb bootstrap|lb bootstrap_debootstrap|Running debootstrap' "$LB_LOG" \
       || grep -q 'P: Bootstrap stage completed' "$LB_LOG"; then
        _die "live-build failed outside the bootstrap download stage. Check $LB_LOG and $ATTEMPTS_LOG"
    fi

    # Give a useful upstream HTTP response when debootstrap's default output
    # suppresses the reason an individual .deb failed. A failed probe is
    # diagnostics only; it cannot make the build succeed or be marked valid.
    _failed_url="$(grep -m1 -Eo 'https?://[^[:space:]]+\.deb' "$LB_LOG" || true)"
    if [[ -n "$_failed_url" ]] && command -v wget >/dev/null 2>&1; then
        {
            printf '\nChecking failed package URL: %s\n' "$_failed_url"
            wget --spider -S --timeout=10 --tries=1 "$_failed_url" 2>&1 | tail -15 || true
        } >> "$ATTEMPTS_LOG"
    fi
    _info "Devuan base package download failed; mirror recovery will try another attempt."
done

if (( !_build_succeeded )); then
    _die "Devuan package downloads failed on every attempted mirror. See $ATTEMPTS_LOG (all attempts) and $LB_LOG (last attempt)."
fi

# Also verify the ISO was actually produced
if [[ ! -f "${BUILD_DIR}/live-image-amd64.hybrid.iso" ]] &&    ! find "${BUILD_DIR}" -name "*.iso" | grep -q .; then
    _die "live-build produced no ISO. Check ${LB_LOG}"
fi

# Report the main live-preview payload groups so future ISO size changes
# can be traced to desktop packages rather than guessed from the ISO alone.
if [[ "$ALTERNIX_BUILD_MODE" == "live-preview" ]]; then
    _step "Live-preview payload size breakdown"
    for component in usr opt var/lib/flatpak var/cache/apt root/.cache usr/share/alternix; do
        component_path="${BUILD_DIR}/chroot/${component}"
        if [[ -e "$component_path" ]]; then
            printf '  · %-26s ' "$component"
            du -sh "$component_path" 2>/dev/null | cut -f1 || true
        fi
    done
fi

# Do not repack the rootfs. The original single SquashFS produced by
# live-build is required for reliable live-boot on VirtualBox and tablets.
_verify_single_rootfs

# Verify both 32-bit UEFI entry points before calling this build successful.
# In particular, EFI/BOOT on the ISO is not what dd-written media loads;
# they read BOOTIA32.EFI from the embedded FAT boot image instead.
# An ISO which takes hours to unpack on a small tablet must never ship.
# Verify the actual squashfs header, not merely live-build's config values.
_step "Verifying installer root filesystem"
SQUASHFS="${BUILD_DIR}/binary/live/filesystem.squashfs"
[[ -s "$SQUASHFS" ]] || _die "No live/filesystem.squashfs in built ISO."
# Validate one normal SquashFS instead of the old split layer manifest.
# The single image may exceed 4 GiB in live-preview's raw hybrid ISO.
SQUASHFS_INFO="$(unsquashfs -s "$SQUASHFS" 2>&1)" || _die "Cannot inspect live squashfs header."
printf '%s\n' "$SQUASHFS_INFO" | grep -E 'Compression|Filesystem size' || true
if ! printf '%s\n' "$SQUASHFS_INFO" | grep -Eiq "^Compression[[:space:]]+${LB_COMPRESSION_CHOICE}([[:space:]]|$)"; then
    _die "ISO root filesystem uses unexpected compression; expected ${LB_COMPRESSION_CHOICE}."
fi
if [[ "$ALTERNIX_BUILD_MODE" == "live-preview" ]]; then
    [[ -s "${BUILD_DIR}/chroot/etc/alternix/de-baked" ]] || \
        _die "AlternixDE was not fully prebuilt for live-preview. See ${LB_LOG}"
    _ok "Live rootfs has the prebuilt desktop and uses ${LB_COMPRESSION_CHOICE}."
else
    [[ ! -e "${BUILD_DIR}/chroot/etc/alternix/de-baked" ]] || \
        _die "Net-install unexpectedly contains a prebuilt desktop marker."
    _ok "Net-install rootfs has the graphical installer and uses ${LB_COMPRESSION_CHOICE}."
fi

_step "Verifying 32-bit UEFI boot files"
EFI_TREE_FILE=$(find "${BUILD_DIR}/binary/EFI" -type f -iname bootia32.efi -print -quit 2>/dev/null)
[[ -n "$EFI_TREE_FILE" && -s "$EFI_TREE_FILE" ]] || \
    _die "32-bit UEFI loader missing from ISO filesystem (EFI/BOOT)."
EFI_IMG="${BUILD_DIR}/binary/boot/grub/efi.img"
[[ -s "$EFI_IMG" ]] || _die "EFI boot image missing — dd-written media will not boot."
if ! mdir -i "$EFI_IMG" ::/EFI/BOOT/BOOTIA32.EFI >/dev/null 2>&1; then
    _die "32-bit UEFI loader is absent from the embedded EFI boot partition."
fi
if ! mdir -i "$EFI_IMG" ::/EFI/BOOT/BOOTX64.EFI >/dev/null 2>&1; then
    _die "Rebuilding embedded EFI image lost the 64-bit UEFI loader."
fi
# Presence alone is insufficient: a stale live-build IA32 loader can remain
# inside efi.img if the replacement silently failed. Compare the file bytes.
EFI_VERIFY_TMP=$(mktemp -d)
if ! mcopy -o -i "$EFI_IMG" ::/EFI/BOOT/BOOTIA32.EFI "$EFI_VERIFY_TMP/bootia32.efi" >/dev/null 2>&1; then
    rm -rf "$EFI_VERIFY_TMP"
    _die "Cannot read BOOTIA32.EFI from the embedded EFI image."
fi
if ! cmp -s "$EFI_TREE_FILE" "$EFI_VERIFY_TMP/bootia32.efi"; then
    rm -rf "$EFI_VERIFY_TMP"
    _die "BOOTIA32.EFI inside efi.img differs from the GRUB loader in the ISO tree."
fi
rm -rf "$EFI_VERIFY_TMP"
_ok "IA32 GRUB matches in ISO tree and embedded EFI image."
EFI_STAGE_EXPECTED="$EFI_TREE_FILE"

# Visor checks include large files copied back from FAT32. Announce them
# before the first mcopy, otherwise the builder looks idle for minutes.
_step "Verifying 64-bit UEFI Visor boot files"
_info "Checking the x64 EFI loader, boot.conf, icons, kernel and initrd in the FAT32 image."
_info "Large initrd extraction can take several minutes; progress will appear every 15 seconds."

# x64 Visor remains the default on extracted FAT USB media.
# x64 is intentionally NOT changed to GRUB-first: on extracted FAT USB,
# BOOTX64.EFI must be Visor. Confirm it is the actual Visor executable.
# On raw/DD USB media the embedded FAT contains Visor plus its kernel,
# initrd and GRUB fallback. The firmware
# selects IA32 GRUB or the x64 loader using the EFI executable filename.
EFI_VISOR_PAYLOAD="${BUILD_DIR}/binary/EFI/visor/visor_x64.efi"
EFI_X64_TREE_FILE=$(find "${BUILD_DIR}/binary/EFI" -type f -iname bootx64.efi -print -quit 2>/dev/null)
if [[ -s "$EFI_VISOR_PAYLOAD" ]]; then
    [[ -n "$EFI_X64_TREE_FILE" && -s "$EFI_X64_TREE_FILE" ]] || \
        _die "Visor exists but BOOTX64.EFI is missing from the ISO tree."
    cmp -s "$EFI_VISOR_PAYLOAD" "$EFI_X64_TREE_FILE" || \
        _die "x64 BOOTX64.EFI does not match Visor; the wrong 64-bit boot menu would load."
    # Also verify the raw/DD boot FAT contains the same Visor EFI binary.
    VISOR_FAT_TMP=$(mktemp -d)
    VISOR_FAT_COPY="${VISOR_FAT_TMP}/BOOTX64.EFI"
    _info "Extracting BOOTX64.EFI (Visor) from the FAT32 image..."
    if ! _monitored_cmd "Reading Visor EFI loader" \
         mcopy -o -i "$EFI_IMG" ::/EFI/BOOT/BOOTX64.EFI "$VISOR_FAT_COPY"; then
        rm -rf "$VISOR_FAT_TMP"
        _die "Could not extract x64 loader from embedded FAT32 image (see the error above)."
    fi
    if ! cmp -s "$VISOR_FAT_COPY" "$EFI_VISOR_PAYLOAD"; then
        _info "Mismatch: expected Visor and embedded BOOTX64.EFI have different hashes:"
        sha256sum "$EFI_VISOR_PAYLOAD" "$VISOR_FAT_COPY" || true
        if [[ -s "${BUILD_DIR}/binary/EFI/BOOT/grubx64-alternix.efi" ]] && \
           cmp -s "$VISOR_FAT_COPY" "${BUILD_DIR}/binary/EFI/BOOT/grubx64-alternix.efi"; then
            _info "Embedded BOOTX64.EFI is the original GRUB loader, not Visor."
        fi
        rm -rf "$VISOR_FAT_TMP"
        _die "Extracted x64 loader does not match the expected Visor EFI executable."
    fi
    rm -rf "$VISOR_FAT_TMP"
    _ok "BOOTX64.EFI matches the Visor executable."
    for boot_file in EFI/visor/boot.conf EFI/visor/icons/linux.png EFI/visor/icons/unknown.png EFI/BOOT/grubx64-alternix.efi live/vmlinuz live/initrd.img; do
        if ! mdir -i "$EFI_IMG" "::/$boot_file" >/dev/null 2>&1; then
            _die "Embedded FAT boot image is missing $boot_file for x64 Visor."
        fi
    done
    # Presence is not enough: compare the config and large payload files.
    # A partial FAT copy must not produce an allegedly bootable ISO.
    # Check the actual FAT boot partition, not only the ISO9660 tree:
    # UEFI reads this partition directly on DD-written USB media.
    # Icon files are small; comparing their bytes costs negligible time.
    for entry in \
        "EFI/visor/boot.conf|${BUILD_DIR}/binary/EFI/visor/boot.conf" \
        "EFI/visor/icons/linux.png|${BUILD_DIR}/binary/EFI/visor/icons/linux.png" \
        "EFI/visor/icons/unknown.png|${BUILD_DIR}/binary/EFI/visor/icons/unknown.png" \
        "live/vmlinuz|${BUILD_DIR}/binary/live/vmlinuz" \
        "live/initrd.img|${BUILD_DIR}/binary/live/initrd.img"; do
        boot_file=${entry%%|*}
        expected=${entry#*|}
        if [[ ! -s "$expected" ]]; then
            # live-build writes versioned kernel/initrd files and the
            # 9999-fix-grub-kernel hook may not have created the aliases.
            for candidate in "$expected"-*; do
                [[ -s "$candidate" ]] && expected="$candidate"
            done
        fi
        [[ -s "$expected" ]] || _die "Missing expected ISO file for $boot_file"
        _info "Checking $boot_file ($(du -h "$expected" | cut -f1) expected)..."
        compare_tmp=$(mktemp -d)
        copied="${compare_tmp}/$(basename "$boot_file")"
        if ! _monitored_cmd "Reading $boot_file from FAT32" \
             mcopy -o -i "$EFI_IMG" "::/$boot_file" "$copied"; then
            rm -rf "$compare_tmp"
            _die "Cannot extract $boot_file from embedded FAT32 image (see the error above)."
        fi
        if ! _monitored_cmd "Byte-comparing $boot_file" cmp -s "$copied" "$expected"; then
            rm -rf "$compare_tmp"
            _die "Extracted $boot_file differs from the ISO filesystem."
        fi
        rm -rf "$compare_tmp"
        _ok "$boot_file matches the ISO filesystem."
    done
    _ok "64-bit UEFI: Visor, configuration, PNG icons, kernel and initrd verified in embedded FAT boot image."
else
    _info "WARNING: Visor build unavailable; x64 UEFI uses live-build GRUB fallback."
fi

# The ISO is amd64 even on an IA32 UEFI tablet. This requires kernel EFI
# mixed-mode support plus the handover entry used by i386-efi GRUB. Report
# incompatibility instead of mistaking a compiled GRUB binary for proof of boot.
_step "Checking 32-bit firmware / 64-bit kernel compatibility"
KCONFIG=$(find "${BUILD_DIR}/chroot/boot" -maxdepth 1 -name 'config-*' 2>/dev/null | sort -V | tail -1)
if [[ -n "$KCONFIG" && -f "$KCONFIG" ]]; then
    if grep -qx 'CONFIG_EFI_MIXED=y' "$KCONFIG" && \
       grep -qx 'CONFIG_EFI_HANDOVER_PROTOCOL=y' "$KCONFIG"; then
        _ok "Kernel supports 32-bit EFI firmware booting an amd64 kernel."
    else
        _info "WARNING: $KCONFIG lacks CONFIG_EFI_MIXED=y or EFI handover."
        _info "GRUB IA32 menu may open, but the 64-bit kernel may not start."
    fi
else
    _info "Kernel config not found; cannot verify EFI mixed-mode capability."
fi

# Post-build safety net: verify unversioned kernel exists in the binary tree
# (in case the binary hook did not run). If missing, add it and regenerate ISO.
BIN_LIVE="${BUILD_DIR}/binary/live"
if [[ -d "$BIN_LIVE" ]] && [[ ! -f "${BIN_LIVE}/vmlinuz" ]]; then
    _info "Hook missed — copying unversioned kernel into ISO tree..."
    VK=$(ls "${BIN_LIVE}"/vmlinuz-* 2>/dev/null | sort | tail -1)
    VI=$(ls "${BIN_LIVE}"/initrd.img-* 2>/dev/null | sort | tail -1)
    [[ -n "$VK" ]] && cp "$VK" "${BIN_LIVE}/vmlinuz"
    [[ -n "$VI" ]] && cp "$VI" "${BIN_LIVE}/initrd.img"
    # Rebuild the ISO image with the added files
    FOUND_ISO_TEMP=$(find "${BUILD_DIR}" -name "*.iso" 2>/dev/null | head -1)
    if [[ -n "$FOUND_ISO_TEMP" ]] && command -v xorriso &>/dev/null; then
        _info "Injecting unversioned kernel into existing ISO..."
        xorriso -boot_image any keep \
            -dev "$FOUND_ISO_TEMP" \
            -map "${BIN_LIVE}/vmlinuz" /live/vmlinuz \
            -map "${BIN_LIVE}/initrd.img" /live/initrd.img \
            2>&1 | grep -v "^xorriso :" || true
        _ok "Kernel injected into ISO."
    fi
fi

# live-build's hybrid partition tables are already correct. Finalise by
# verifying both loaders in the finished ISO using the exact Rock Ridge
# path spellings and byte-comparing the embedded FAT32 image.
_finalize_iso
