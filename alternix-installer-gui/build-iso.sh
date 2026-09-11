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
OUTPUT_ISO="${SCRIPT_DIR}/alternix-installer.iso"

# ── Colours (minimal, build-time only) ───────────────────────────
_info()  { echo "  · $*"; }
_ok()    { echo "  ✓ $*"; }
_err()   { echo "  ✗ $*" >&2; }
_die()   { _err "$*"; exit 1; }
_step()  { echo ""; echo "  ══  $*  ══"; echo ""; }

# ── Root check ────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || _die "Run as root: sudo bash build-iso.sh"

# ── Dependencies ──────────────────────────────────────────────────
_step "Checking dependencies"

for dep in live-build debootstrap xorriso grub-pc-bin grub-efi-amd64-bin isolinux syslinux-utils; do
    if ! dpkg -l "$dep" &>/dev/null; then
        _info "Installing ${dep}..."
        apt-get install -y "$dep" &>/dev/null
    fi
done

# Install Devuan keyring so debootstrap can verify signatures
if ! dpkg -l devuan-keyring &>/dev/null; then
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
        ( cd "$probe_dir" && lb config --compression "$c" ) >/dev/null 2>&1 && rc=0
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
    COMPRESSION_ARG=(--compression "$LB_COMPRESSION_CHOICE")
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
    --mirror-bootstrap "http://deb.devuan.org/merged" \
    --mirror-binary "http://deb.devuan.org/merged" \
    --mirror-chroot-security "http://deb.devuan.org/merged" \
    --mirror-binary-security "http://deb.devuan.org/merged" \
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
    "${COMPRESSION_ARG[@]}" \
    --debootstrap-options "--variant=minbase --keyring=${DEVUAN_KEYRING}"

_ok "live-build configured."

# Override LB_INITSYSTEM — must be written to config/common after lb config runs.
# lb_chroot_live-packages reads LB_INITSYSTEM and installs live-config-${LB_INITSYSTEM}.
# Setting it to sysvinit installs live-config-sysvinit instead of live-config-systemd.
# Set LB_INITSYSTEM=none so live-build does not try to install live-config-systemd.
# We add live-config-sysvinit explicitly in our package list instead.
echo 'LB_INITSYSTEM="none"' >> config/common

# FORCE THE SQUASHFS COMPRESSION — DO NOT RELY ON THE lb config FLAG
# Passing --compression to lb config is accepted without error but does
# not always reach mksquashfs: a build configured with "gzip" still
# produced an xz-compressed squashfs. The same problem applies to
# LB_INITSYSTEM above, which is why that is written here too. Writing
# the value straight into config/binary is what actually takes effect.
#
# This matters because the target unpacks this squashfs during every
# install. xz decompresses at roughly a tenth the speed of gzip or
# zstd, so getting this wrong costs minutes on every machine.
if [[ -n "${LB_COMPRESSION_CHOICE}" ]]; then
    if grep -q '^LB_COMPRESSION=' config/binary 2>/dev/null; then
        sed -i "s|^LB_COMPRESSION=.*|LB_COMPRESSION=\"${LB_COMPRESSION_CHOICE}\"|" \
            config/binary
    else
        echo "LB_COMPRESSION=\"${LB_COMPRESSION_CHOICE}\"" >> config/binary
    fi
    _ok "Squashfs compression forced to ${LB_COMPRESSION_CHOICE} in config/binary."
    _info "Verify after the build: the mksquashfs summary should say"
    _info "\"${LB_COMPRESSION_CHOICE} compressed\", not \"xz compressed\"."
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

# ── Terminal / UI ─────────────────────────────────────────────────
tmux
ncurses-bin
xterm

# ── X server (graphical installer + AlternixDE live session) ─────
# XLIBRE CONFLICT — READ BEFORE ADDING xserver-xorg-core HERE
# install-alternix_devuan.sh adds the XLibre repo and installs XLibre,
# which is a fork of the X server and REPLACES xserver-xorg-core. If
# both are pulled in, apt has to resolve that conflict during the ISO
# build and the loser is whichever it decides. Only the pieces XLibre
# does not itself provide are listed here; hook 0080 installs the
# server. If you drop AlternixDE from the image, xserver-xorg-core
# must be added back or there will be no X at all.
xinit
x11-xserver-utils
x11-utils
xinput
# INPUT DRIVERS COME FROM XLIBRE — DO NOT ADD THE XORG ONES BACK
# AlternixDE installs xlibre, which replaces xserver-xorg-core and
# brings its own xserver-xlibre-input-* drivers. Listing
# xserver-xorg-input-libinput or -evdev here puts two packages that
# replace each other into the same install, which is what apt was
# being asked to resolve when the desktop package install failed.

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
# REQUIRED BY THE ALTERNIXDE BUILD — DO NOT REMOVE
# install-alternix_devuan.sh calls sudo 134 times. Without this
# package every one of them fails with 'command not found', even
# though the hook already runs as root.
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

_ok "Package lists written."

# ── Copy installer scripts ────────────────────────────────────────
_step "Embedding installer scripts"

mkdir -p config/includes.chroot/installer
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

# ── AlternixDE build hook ─────────────────────────────────────────
# COPY INSTALL — this is what makes the 5-minute install possible.
# The desktop is compiled ONCE here, at ISO build time, instead of
# 41 serial g++ runs on the target CPU during every install.
_step "Configuring AlternixDE build hook"

cat > config/hooks/normal/0080-alternix-de.hook.chroot << 'HOOKEOF'
#!/bin/bash
# Build AlternixDE into the live chroot. Because the live squashfs IS
# the system copied onto the target, everything built here lands on the
# installed machine as a plain file copy.
set -e

DE_REPO="${ALTERNIXDE_REPO:-https://github.com/DansDesigns/AlternixDE}"

# CLONE PATH IS NOT ARBITRARY — DO NOT CHANGE
# install-alternix_devuan.sh hardcodes ALT_ROOT="$HOME/Alternix" and
# exits immediately if that directory is absent. It also reads
# ~/Alternix/installers, ~/Alternix/configs and ~/Alternix/update by
# the same absolute path. The repo must be cloned to exactly this
# location, not a temporary directory.
export HOME=/root
DE_DIR="${HOME}/Alternix"
BUILD_LOG=/tmp/alternixde-build.log

echo "  · Cloning AlternixDE into ${DE_DIR}..."
rm -rf "$DE_DIR"
if ! git clone --depth 1 "$DE_REPO" "$DE_DIR" >>"$BUILD_LOG" 2>&1; then
    echo "  x AlternixDE clone failed:"
    tail -20 "$BUILD_LOG" | sed 's/^/      /'
    exit 1
fi

cd "$DE_DIR"

if [ ! -f install-alternix_devuan.sh ]; then
    echo "  x install-alternix_devuan.sh not found in the repo root."
    exit 1
fi

# CRLF STRIP — DO NOT REMOVE
# A carriage return on the shebang line makes the kernel look for an
# interpreter literally named "bash\r", which fails with a bare
# "no such file or directory" that points at nothing useful.
sed -i 's/\r$//' install-alternix_devuan.sh
chmod +x install-alternix_devuan.sh

# ANSWERING THE PROMPTS — DO NOT SIMPLIFY
# The script asks three times: username (line 34), telephony choice
# (line 176) and restart-or-continue (line 1207). It also runs under
# `set -e`, so a bare `read` returning non-zero at EOF kills it
# instantly with exit 1 and no error message at all.
#
# "2" is Skip for telephony and Continue for the final prompt, and
# `yes` never ends, so there is no EOF to trip `set -e`.
#
# `{ echo root; yes 2; }` answers the username once and then feeds "2"
# to everything after it — "2" being Skip for telephony. The stream
# never ends, so no EOF spin. `timeout` is the backstop in case a
# future prompt rejects "2" and loops anyway.
export TARGET_USER="root"
export DEBIAN_FRONTEND=noninteractive
# `clear` on line 3 of that script fails under TERM=dumb or an unset
# TERM, and `set -e` on line 2 then kills it with no output.
export TERM=xterm

echo "  · Building AlternixDE (this takes a while; output -> ${BUILD_LOG})"

set +e
{ echo "root"; yes 2; } | \
    timeout 7200 bash install-alternix_devuan.sh >>"$BUILD_LOG" 2>&1
DE_RC=$?
set -e

if [ "$DE_RC" -ne 0 ]; then
    if [ "$DE_RC" -eq 124 ]; then
        echo "  x AlternixDE build timed out after 2 hours (likely stuck on a prompt)."
    else
        echo "  x AlternixDE build failed (exit ${DE_RC})."
    fi
    echo "  ---- last 40 lines of the build log ----"
    tail -40 "$BUILD_LOG" | sed 's/^/      /'

    # DIAGNOSTICS — nala renders dependency failures as a Python
    # traceback with the package list truncated ("... +71"), which does
    # not say which dependency is unsatisfiable. Plain apt prints a
    # readable explanation, so ask it directly and record the answer.
    echo "  ---- apt dependency state ----"
    apt-get check 2>&1 | tail -20 | sed 's/^/      /'
    # PER-PACKAGE BISECT
    # nala marks all ~76 packages at once and reports the failure
    # against whichever it touched first, which is alacritty purely
    # because the list is alphabetical. alacritty installs fine on its
    # own, so the real culprit is elsewhere in the list. Testing each
    # package separately is the only way to name it.
    echo "  ---- testing each package individually ----"
    # Anchor on a line ENDING in a backslash: the script has four other
    # "nala install" lines, and matching the first one picks up
    # "ca-certificates curl" from line 116 instead of the real list.
    _PKGS=$(sed 's/\r$//' "${DE_DIR}/install-alternix_devuan.sh" 2>/dev/null \
            | awk '/nala install -y[[:space:]]*\\$/{f=1} f{print; if ($0 !~ /\\$/) exit}' \
            | sed 's/.*nala install -y//' | tr -d '\\' | tr ' ' '\n' \
            | grep -v '^$' | sort -u)

    if [ -z "$_PKGS" ]; then
        echo "      (could not extract the package list from the script)"
    else
        _N=0; _BAD=0
        for _p in $_PKGS; do
            _N=$((_N + 1))
            if ! apt-get install -s -y "$_p" >/dev/null 2>&1; then
                _BAD=$((_BAD + 1))
                echo "      CANNOT INSTALL: ${_p}"
                apt-get install -s -y "$_p" 2>&1 | grep -iE "^E:|Depends|Conflicts" \
                    | head -5 | sed 's/^/          /'
            fi
        done
        echo "      checked ${_N} packages, ${_BAD} cannot be installed on their own"
        if [ "$_BAD" -eq 0 ]; then
            echo "      All install individually, so the fault is a conflict"
            echo "      between two of them rather than a missing package."
        fi
    fi

    echo "  ---- packages not in state ii ----"
    dpkg -l 2>/dev/null | awk 'NR>5 && $1 != "ii" {print $1, $2}' \
        | head -20 | sed 's/^/      /' 

    # NON-FATAL BY DEFAULT — DELIBERATE
    # The primary deliverable is the graphical installer. Failing the
    # whole ISO build because the desktop could not be baked in would
    # block that for a problem that has a working fallback: without a
    # baked desktop, install.sh simply builds AlternixDE on the target
    # the way it always did. Slower, but it installs.
    #
    # Set ALTERNIXDE_REQUIRED=1 in the environment to make this fatal
    # once the dependency problem is solved.
    if [ "${ALTERNIXDE_REQUIRED:-0}" = "1" ]; then
        echo "  x ALTERNIXDE_REQUIRED=1 — failing the build."
        exit 1
    fi

    # MARKER — DO NOT REMOVE
    # install.sh checks for this. Without it the copy install would
    # skip install_desktop on the assumption the image already has
    # AlternixDE, and produce a system with no desktop at all.
    mkdir -p /etc/alternix
    echo "AlternixDE was not baked into this image." > /etc/alternix/de-missing
    date >> /etc/alternix/de-missing

    # Stash it even on failure — this is exactly the case where
    # install_desktop.sh has to build the desktop on the target, so
    # having the repository already present saves the second clone.
    mkdir -p /usr/share/alternix
    rm -rf /usr/share/alternix/AlternixDE
    cp -a "$DE_DIR" /usr/share/alternix/AlternixDE
    echo "  ! Repository stashed at /usr/share/alternix/AlternixDE"

    echo "  ! Continuing without a baked desktop."
    echo "  ! Installs will build AlternixDE on the target instead."
    cd /
    rm -rf "$DE_DIR"
    exit 0
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

# KEEP THE REPOSITORY IN THE IMAGE — DO NOT DELETE IT
# It was previously removed here, which meant install_desktop.sh had to
# clone the same repository a second time on the target machine. Since
# the live squashfs IS what gets copied onto the target, stashing it
# here makes it available at install time for the cost of a few MB.
#
# The bigger gain is not the seconds saved cloning: it removes the
# install's dependency on GitHub being reachable at that moment.
mkdir -p /usr/share/alternix
rm -rf /usr/share/alternix/AlternixDE
cp -a "$DE_DIR" /usr/share/alternix/AlternixDE
echo "  + Repository stashed at /usr/share/alternix/AlternixDE"

cd /
rm -rf "$DE_DIR"
rm -f "$BUILD_LOG"
echo "  + AlternixDE built into image."
HOOKEOF
chmod +x config/hooks/normal/0080-alternix-de.hook.chroot

_ok "AlternixDE hook written."

# ── osm-install build hook ────────────────────────────────────────
_step "Configuring installer build hook"

cat > config/hooks/normal/0090-osm-install.hook.chroot << 'HOOKEOF'
#!/bin/bash
# Compile the graphical installer inside the chroot, where Qt5 dev
# is present. Building here rather than on the host guarantees the
# binary matches the runtime libraries it will actually link against.
set -e

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

# X INPUT DRIVER CHECK
# The xorg input drivers are deliberately not in the package list,
# because xlibre replaces them and having both breaks the desktop
# package install. That means the ONLY source of input drivers is the
# xlibre install inside hook 0080. If that hook failed early, the ISO
# would boot into X with no working touchscreen, mouse or keyboard,
# and the graphical installer would be unusable with no clue why.
if ls /usr/lib/xorg/modules/input/*.so >/dev/null 2>&1; then
    echo "  + X input drivers present:"
    ls /usr/lib/xorg/modules/input/*.so 2>/dev/null \
        | xargs -n1 basename | sed 's/^/      /'
else
    echo "  x NO X INPUT DRIVERS FOUND."
    echo "  x The graphical installer will start but nothing will respond"
    echo "  x to touch, mouse or keyboard. This means the xlibre install"
    echo "  x in hook 0080 did not complete. Boot with alternix.tui=1 to"
    echo "  x use the text installer until this is fixed."
fi

# alternix-net resolves its own directory, so it stays in /installer
# alongside network.sh. Just make sure it is executable.
chmod +x /installer/alternix-net 2>/dev/null || true

echo "  + osm-install compiled."
HOOKEOF
chmod +x config/hooks/normal/0090-osm-install.hook.chroot

_ok "Installer build hook written."

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

_ok "Auto-launch configured."

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

# Use search to find the versioned kernel and initrd automatically
set default=0
set timeout=5

if background_image /boot/grub/background.png; then
    set color_normal=cyan/black
    set color_highlight=white/cyan
fi

# KERNEL PATH FIX — DO NOT REMOVE
# grub.cfg uses UNVERSIONED /live/vmlinuz and /live/initrd.img.
# The binary hook below copies the versioned kernel to these names,
# so kernel updates can never break the ISO boot.

menuentry "Install Alternix" {
    search --no-floppy --label --set=root Alternix-Installer
    linux  ($root)/live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer quiet
    initrd ($root)/live/initrd.img
}

menuentry "Install Alternix (text mode)" {
    search --no-floppy --label --set=root Alternix-Installer
    linux  ($root)/live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer alternix.tui=1 quiet
    initrd ($root)/live/initrd.img
}

menuentry "Install Alternix (nomodeset)" {
    search --no-floppy --label --set=root Alternix-Installer
    linux  ($root)/live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer nomodeset
    initrd ($root)/live/initrd.img
}

menuentry "Install Alternix (safe mode, text)" {
    search --no-floppy --label --set=root Alternix-Installer
    linux  ($root)/live/vmlinuz boot=live components live-config.username=root live-config.autologin=root pci=noaer alternix.tui=1 noapic noacpi nomodeset
    initrd ($root)/live/initrd.img
}
EOF

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

# ── Build ─────────────────────────────────────────────────────────
_step "Building ISO (this will take a while...)"

LB_LOG="${BUILD_DIR}/lb-build.log"
lb build 2>&1 | tee "$LB_LOG" | while IFS= read -r line; do
    echo "  ${line}"
done
# tee exits 0 — check the log for lb failure marker instead
if grep -qE "^E:|^lb build failed" "$LB_LOG" 2>/dev/null; then
    _die "live-build failed. Check ${LB_LOG}"
fi
# Also verify the ISO was actually produced
if [[ ! -f "${BUILD_DIR}/live-image-amd64.hybrid.iso" ]] &&    ! find "${BUILD_DIR}" -name "*.iso" | grep -q .; then
    _die "live-build produced no ISO. Check ${LB_LOG}"
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

# Post-process ISO for Rufus/Windows compatibility
_step "Making ISO Rufus-compatible"
FOUND_ISO_TEMP=$(find "${BUILD_DIR}" -name "*.iso" 2>/dev/null | head -1)
if [[ -n "$FOUND_ISO_TEMP" ]]; then
    if command -v isohybrid &>/dev/null; then
        isohybrid --uefi "$FOUND_ISO_TEMP" 2>/dev/null || \
            isohybrid "$FOUND_ISO_TEMP" 2>/dev/null || true
        _ok "isohybrid applied — Rufus compatible."
    else
        _info "isohybrid not found. Installing syslinux-utils..."
        apt-get install -y syslinux-utils &>/dev/null && \
            isohybrid --uefi "$FOUND_ISO_TEMP" 2>/dev/null || true
    fi
fi

# ── Copy output ───────────────────────────────────────────────────
_step "Finalising"

FOUND_ISO=$(find "${BUILD_DIR}" -name "*.hybrid.iso" | head -1)
if [[ -z "$FOUND_ISO" ]]; then
    FOUND_ISO=$(find "${BUILD_DIR}" -name "*.iso" | head -1)
fi

if [[ -z "$FOUND_ISO" ]]; then
    _die "ISO not found in build output."
fi

cp "$FOUND_ISO" "$OUTPUT_ISO"
_ok "ISO written: ${OUTPUT_ISO}"

SIZE=$(du -sh "$OUTPUT_ISO" | cut -f1)
echo ""
echo "  ══════════════════════════════════════════"
echo "  Alternix Installer ISO built successfully"
echo "  Output: ${OUTPUT_ISO}"
echo "  Size:   ${SIZE}"
echo "  ══════════════════════════════════════════"
echo ""
echo "  Write to USB:"
echo "    sudo dd if=${OUTPUT_ISO} of=/dev/sdX bs=4M status=progress"
echo "    sudo sync"
echo ""
