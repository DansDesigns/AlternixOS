#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# install_copy.sh — Alternix rootfs copy installation
#
# Replaces install_base.sh + build_sel4.sh + install_desktop.sh in
# the fast install path. Instead of debootstrapping a base system
# over the network and compiling the desktop on the target CPU, it
# unpacks the prebuilt squashfs that shipped on the install medium.
#
# Downstream is unchanged: configure_system.sh personalises the
# result and install_base.sh's _install_bootloader installs grub.
#
# Public functions:
#   copy_rootfs      unpack the image onto the mounted target
#   delive_target    strip the live-boot machinery out of it
#   finalise_copy    regenerate the initramfs for real hardware
# ═══════════════════════════════════════════════════════════════

ALTERNIX_MOUNT="${ALTERNIX_MOUNT:-/mnt/alternix}"

# Set by _find_squashfs, consumed by copy_rootfs.
ALTERNIX_SQUASHFS=""
ALTERNIX_SQUASHFS_IMAGES=()

# ── Locate the rootfs image ───────────────────────────────────────
_find_squashfs() {
    # live-boot mounts the ISO at /run/live/medium. The other paths
    # cover older live-boot releases and a loop-mounted ISO during
    # development, so this works when testing outside a real boot.
    local candidates=(
        "/run/live/medium/live/filesystem.squashfs"
        "/lib/live/mount/medium/live/filesystem.squashfs"
        "/run/live/findiso/live/filesystem.squashfs"
        "/cdrom/live/filesystem.squashfs"
        "${ALTERNIX_SQUASHFS_OVERRIDE:-/nonexistent}"
    )

    local c dir module line name
    local -a names
    for c in "${candidates[@]}"; do
        if [[ -s "$c" ]]; then
            ALTERNIX_SQUASHFS="$c"
            ALTERNIX_SQUASHFS_IMAGES=("$c")
            dir="$(dirname "$c")"
            module="$dir/filesystem.module"
            if [[ -f "$module" ]]; then
                ALTERNIX_SQUASHFS_IMAGES=()
                # The builder writes one basename per line. Validate paths
                # and check all layers BEFORE allowing partitioning/erase.
                while IFS= read -r line || [[ -n "$line" ]]; do
                    line="${line%%#*}"
                    read -ra names <<< "$line"
                    for name in "${names[@]}"; do
                        [[ "$name" =~ ^filesystem(-[0-9]+)?\.squashfs$ ]] || return 1
                        [[ -s "$dir/$name" ]] || return 1
                        ALTERNIX_SQUASHFS_IMAGES+=("$dir/$name")
                    done
                done < "$module"
                (( ${#ALTERNIX_SQUASHFS_IMAGES[@]} > 0 )) || return 1
                [[ "${ALTERNIX_SQUASHFS_IMAGES[0]}" == "$c" ]] || return 1
            else
                # If additional layers somehow exist without their module
                # list, the live filesystem would be incomplete. Refuse it.
                if compgen -G "$dir/filesystem-[0-9]*.squashfs" >/dev/null; then
                    return 1
                fi
            fi
            return 0
        fi
    done
    return 1
}

# ── Unpack the image onto the target ──────────────────────────────
copy_rootfs() {
    section "Copying System"

    if ! _find_squashfs; then
        die "No rootfs image found on the installation medium. This ISO was not built with a copy-install image."
    fi

    if ! command -v unsquashfs &>/dev/null; then
        die "unsquashfs not found in the live environment. Add squashfs-tools to the ISO package list."
    fi

    # MOUNT CHECK — DO NOT REMOVE
    # Same reasoning as mount_partitions in partition.sh. If the target
    # is not a real mountpoint we would unpack several GB into the live
    # RAM overlay and die with "No space left on device" a long way from
    # the actual cause.
    if ! mountpoint -q "$ALTERNIX_MOUNT"; then
        die "${ALTERNIX_MOUNT} is not a mountpoint. Refusing to unpack into the live overlay."
    fi

    local img_bytes avail_bytes need_bytes image image_bytes
    img_bytes=0
    # All layers combine into ONE installed rootfs. Count every layer in
    # the free-space check rather than checking only filesystem.squashfs.
    # Use stat in BYTES: unsquashfs -s reports its size in Kbytes and
    # treating that number as bytes would undercount target space 1024x.
    for image in "${ALTERNIX_SQUASHFS_IMAGES[@]}"; do
        image_bytes=$(stat -c %s "$image") || die "Cannot measure squashfs image: $image"
        img_bytes=$((img_bytes + image_bytes))
    done
    # unsquashfs reports the compressed size; 2.6x is the conservative
    # preexisting sizing margin for the decompressed target filesystem.
    need_bytes=$(awk -v b="$img_bytes" 'BEGIN{printf "%.0f", b * 2.6}')
    avail_bytes=$(df -B1 --output=avail "$ALTERNIX_MOUNT" 2>/dev/null | tail -1)

    if [[ -n "$avail_bytes" && "$need_bytes" -gt 0 ]] 2>/dev/null; then
        if (( avail_bytes < need_bytes )); then
            die "Not enough space on the target: need about $(( need_bytes / 1048576 )) MB, have $(( avail_bytes / 1048576 )) MB."
        fi
    fi

    info "Rootfs: ${#ALTERNIX_SQUASHFS_IMAGES[@]} image layer(s), starting with ${ALTERNIX_SQUASHFS}"

    # Decompression is the bottleneck, so use every core. unsquashfs
    # already defaults to nproc, but be explicit — some builds default
    # to a single processor.
    local jobs
    jobs=$(nproc 2>/dev/null || echo 2)

    info "Unpacking with ${jobs} threads..."

    # -f  overwrite the (empty but existing) mountpoint
    # -d  destination
    # -p  processor count
    #
    # The percentage is scraped from unsquashfs's own counter so the
    # GUI can show real progress through the longest step of the
    # install. Under the TUI the tokens are simply not printed.
    #
    # AWK PORTABILITY — DO NOT REMOVE
    # Two-argument match() with RSTART/RLENGTH is POSIX. The
    # three-argument form that captures into an array is a gawk
    # extension, and Devuan's default awk is mawk, where it is a
    # syntax error. Keep this POSIX.
    #
    # unsquashfs redraws its progress bar with carriage returns and no
    # newline, so awk would see one enormous line and print nothing
    # until the unpack finished. tr converts CR to LF to break it up.
    local rc=0 layer_index=0 layer_count=${#ALTERNIX_SQUASHFS_IMAGES[@]}
    for image in "${ALTERNIX_SQUASHFS_IMAGES[@]}"; do
        info "Unpacking layer $((layer_index + 1))/${layer_count}: $(basename "$image")"
        if [[ "${ALTERNIX_UNATTENDED:-0}" -eq 1 ]]; then
            set -o pipefail
            unsquashfs -f -d "$ALTERNIX_MOUNT" -p "$jobs" "$image" 2>&1 | \
                tr '\r' '\n' | \
                awk -v i="$layer_index" -v total="$layer_count" '
                    {
                        if (match($0, /[0-9]+%/)) {
                            pct = substr($0, RSTART, RLENGTH - 1)
                            combined = int((i * 100 + pct) / total)
                            if (combined != last) {
                                print "##COPY:" combined
                                fflush()
                                last = combined
                            }
                            next
                        }
                        print
                        fflush()
                    }
                '
            rc=${PIPESTATUS[0]}
            set +o pipefail
        else
            spin_start "Unpacking system layer $((layer_index + 1))/${layer_count}..."
            if unsquashfs -f -d "$ALTERNIX_MOUNT" -p "$jobs" "$image" \
                    >>"$ALTERNIX_LOG" 2>&1; then
                rc=0
            else
                rc=$?
            fi
            spin_stop
        fi
        if [[ $rc -ne 0 ]]; then
            die "unsquashfs failed on $(basename "$image") (exit ${rc}). The install medium may be damaged."
        fi
        layer_index=$((layer_index + 1))
    done

    # Sanity check: a truncated unpack is worse than a failed one,
    # because everything after this point appears to work.
    local f
    for f in /bin/sh /sbin/init /etc/passwd /usr/bin/env; do
        if [[ ! -e "${ALTERNIX_MOUNT}${f}" ]]; then
            die "Unpacked system is incomplete (${f} missing). The install medium may be damaged."
        fi
    done

    ok "System copied."
}

# ── Strip the live-boot machinery ─────────────────────────────────
delive_target() {
    section "Preparing Installed System"

    # The image we just unpacked is the live system, so it still
    # believes it boots from a squashfs. Everything below undoes that.

    _copy_chroot() {
        chroot "$ALTERNIX_MOUNT" /bin/bash -c "$*"
    }

    # CHROOT SERVICE FIX — mirrors install_base.sh _install_packages.
    # Package removal scripts call invoke-rc.d → rc-service, which does
    # not exist in a chroot. configure_system restores the original.
    chroot "$ALTERNIX_MOUNT" dpkg-divert --local --rename --quiet \
        --add /usr/sbin/invoke-rc.d 2>/dev/null || true
    cat > "${ALTERNIX_MOUNT}/usr/sbin/invoke-rc.d" << 'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${ALTERNIX_MOUNT}/usr/sbin/invoke-rc.d"

    cat > "${ALTERNIX_MOUNT}/usr/sbin/policy-rc.d" << 'EOF'
#!/bin/sh
exit 101
EOF
    chmod +x "${ALTERNIX_MOUNT}/usr/sbin/policy-rc.d"

    # ── Remove the live packages ──────────────────────────────────
    # LIVE PACKAGE PURGE — DO NOT REMOVE
    # live-boot ships an initramfs hook that searches for a squashfs
    # at boot. If it survives into the installed system, the target
    # builds an initramfs that ignores root= and hangs at boot with
    # "Unable to find a medium containing a live file system".
    info "Removing live-boot packages..."
    _copy_chroot "DEBIAN_FRONTEND=noninteractive apt-get purge -y \
        live-boot live-boot-initramfs-tools live-config \
        live-config-sysvinit live-tools live-boot-doc live-config-doc" \
        >>"$ALTERNIX_LOG" 2>&1 || warn "Live package purge returned a nonzero status; checking it below."

    # A leftover live-boot initramfs hook makes the copied installation
    # search for a squashfs instead of mounting its root UUID.
    local live_pkg
    for live_pkg in live-boot live-boot-initramfs-tools; do
        if chroot "$ALTERNIX_MOUNT" dpkg-query -W -f='${Status}' "$live_pkg" 2>/dev/null | \
            grep -qx 'install ok installed'; then
            die "$live_pkg remains installed in target; cannot build a normal disk initramfs."
        fi
    done

    # The updater needs Nala on the installed system, not only in the
    # build-time Live environment. Prevent autoremove purging it.
    if chroot "$ALTERNIX_MOUNT" dpkg-query -W -f='${Status}' nala 2>/dev/null | \
            grep -qx 'install ok installed'; then
        chroot "$ALTERNIX_MOUNT" apt-mark manual nala >>"$ALTERNIX_LOG" 2>&1 || true
    fi
    _copy_chroot "DEBIAN_FRONTEND=noninteractive apt-get autoremove -y" \
        >>"$ALTERNIX_LOG" 2>&1 || true

    # Belt and braces: the initramfs hooks sometimes survive a purge
    # when the package was installed by live-build rather than apt.
    rm -f "${ALTERNIX_MOUNT}/usr/share/initramfs-tools/hooks/live" \
          "${ALTERNIX_MOUNT}/usr/share/initramfs-tools/scripts/live" \
          "${ALTERNIX_MOUNT}/usr/share/initramfs-tools/scripts/live-premount"/* \
          2>/dev/null || true
    rm -rf "${ALTERNIX_MOUNT}/lib/live" 2>/dev/null || true

    # ── Remove live-installer-only power-management restrictions ──
    # The ISO masks sleep targets and disables elogind suspension so that
    # an unattended installer cannot suspend halfway through disk writes.
    # The fast install copies the live squashfs, so discard ONLY our own
    # installer-specific masks/configuration from the installed OS.
    # Do not undo masks that another package/admin may have installed.
    info "Removing live-installer sleep restrictions from target..."
    local sleep_unit mask
    for sleep_unit in sleep.target suspend.target hibernate.target \
                      hybrid-sleep.target suspend-then-hibernate.target; do
        mask="${ALTERNIX_MOUNT}/etc/systemd/system/${sleep_unit}"
        if [[ -L "$mask" && "$(readlink "$mask")" == /dev/null ]]; then
            rm -f -- "$mask"
        fi
    done
    rm -f -- \
        "${ALTERNIX_MOUNT}/etc/elogind/sleep.conf.d/90-alternix-installer-awake.conf" \
        "${ALTERNIX_MOUNT}/etc/elogind/logind.conf.d/90-alternix-installer-awake.conf" \
        "${ALTERNIX_MOUNT}/etc/systemd/sleep.conf.d/90-alternix-installer-awake.conf"

    # ── Remove the installer itself ───────────────────────────────
    info "Removing installer..."
    rm -rf "${ALTERNIX_MOUNT}/installer" 2>/dev/null || true
    rm -f  "${ALTERNIX_MOUNT}/usr/local/bin/osm-install" \
           "${ALTERNIX_MOUNT}/usr/local/bin/alternix-net" \
           "${ALTERNIX_MOUNT}/usr/share/applications/osm-install.desktop" \
           2>/dev/null || true
    # The live session's X autostart launches the installer on boot.
    rm -f "${ALTERNIX_MOUNT}/root/.xinitrc.install" \
          "${ALTERNIX_MOUNT}/etc/alternix-live-installer" 2>/dev/null || true

    # Do not leave Live-only menu shortcuts, session launchers or an
    # autologin helper on the installed system. The target's normal
    # user/Qtile startup is configured later by configure_system.sh.
    rm -f "${ALTERNIX_MOUNT}/usr/share/applications/alternix-install.desktop" \
          "${ALTERNIX_MOUNT}/usr/local/bin/alternix-live-session" \
          "${ALTERNIX_MOUNT}/usr/local/bin/alternix-live-desktop" \
          "${ALTERNIX_MOUNT}/usr/local/bin/alternix-live-wallpaper" \
          "${ALTERNIX_MOUNT}/usr/local/bin/alternix-live-terminal" \
          "${ALTERNIX_MOUNT}/usr/local/bin/alternix-live-install" \
          "${ALTERNIX_MOUNT}/usr/local/sbin/alternix-tty-select" \
          "${ALTERNIX_MOUNT}/etc/sudoers.d/alternix-live-installer" \
          2>/dev/null || true

    # Restore the original desktop launcher files before installing the
    # system: the Live app launcher needs one user-local fallback entry,
    # while the installed account should use its original Alacritty entries.
    local entry
    for entry in htop fetch os-check-update; do
        if [[ -f "${ALTERNIX_MOUNT}/usr/share/alternix/live-original-launchers/${entry}.desktop" ]]; then
            mv -f -- "${ALTERNIX_MOUNT}/usr/share/alternix/live-original-launchers/${entry}.desktop" \
                   "${ALTERNIX_MOUNT}/usr/share/applications/${entry}.desktop"
        fi
    done
    rm -rf -- "${ALTERNIX_MOUNT}/usr/share/alternix/live-original-launchers"
    # The Live network grants must never remain on an installed machine.
    rm -f -- "${ALTERNIX_MOUNT}/etc/polkit-1/rules.d/49-alternix-live-network.rules" \
               "${ALTERNIX_MOUNT}/etc/sudoers.d/alternix-live-wifi-scan"

    # This is a root-owned, read-only Qtile venv copied only for the Live
    # desktop. Normal installed accounts use the system-wide Qtile binary.
    rm -rf -- "${ALTERNIX_MOUNT}/opt/alternix-live" 2>/dev/null || true

    # ── Remove the live user ──────────────────────────────────────
    # The prebuilt image includes a disposable, password-locked Live account.
    # It must not reach the installed system.
    local live_user
    for live_user in user live alternix-live; do
        if _copy_chroot "id -u ${live_user}" >/dev/null 2>&1; then
            info "Removing live user '${live_user}'..."
            _copy_chroot "deluser --remove-home ${live_user}" \
                >>"$ALTERNIX_LOG" 2>&1 || true
        fi
    done
    rm -f "${ALTERNIX_MOUNT}/etc/sudoers.d/live" \
          "${ALTERNIX_MOUNT}/etc/sudoers.d/live-config" \
          "${ALTERNIX_MOUNT}/etc/sudoers.d/alternix-live" 2>/dev/null || true

    # Live autologin in inittab must go, or the installed system logs
    # a now-deleted user straight in on tty1.
    if [[ -f "${ALTERNIX_MOUNT}/etc/inittab" ]]; then
        sed -i -e '/autologin/d' -e '/alternix-tty-select/d' \
            "${ALTERNIX_MOUNT}/etc/inittab" 2>/dev/null || true
    fi

    # ── Identity that must be unique per machine ──────────────────
    # A cloned machine-id makes every Alternix install look like the
    # same host to DHCP servers and elogind.
    : > "${ALTERNIX_MOUNT}/etc/machine-id"
    rm -f "${ALTERNIX_MOUNT}/var/lib/dbus/machine-id" 2>/dev/null || true

    # Shipping one set of SSH host keys in the image would give every
    # installation the same identity and the same private key.
    rm -f "${ALTERNIX_MOUNT}"/etc/ssh/ssh_host_*_key \
          "${ALTERNIX_MOUNT}"/etc/ssh/ssh_host_*_key.pub 2>/dev/null || true

    # Interface names baked at image build time will not match this
    # machine's hardware.
    rm -f "${ALTERNIX_MOUNT}/etc/udev/rules.d/70-persistent-net.rules" \
          "${ALTERNIX_MOUNT}/etc/udev/rules.d/75-persistent-net-generator.rules" \
          2>/dev/null || true

    # live-config replaces resolv.conf with its own; leave a normal
    # file behind for NetworkManager to manage.
    rm -f "${ALTERNIX_MOUNT}/etc/resolv.conf" 2>/dev/null || true
    : > "${ALTERNIX_MOUNT}/etc/resolv.conf"

    # ── Clean caches that only bloat the target ───────────────────
    rm -rf "${ALTERNIX_MOUNT}/var/cache/apt/archives"/*.deb 2>/dev/null || true
    rm -rf "${ALTERNIX_MOUNT}/var/lib/apt/lists"/* 2>/dev/null || true
    rm -rf "${ALTERNIX_MOUNT}/tmp"/* "${ALTERNIX_MOUNT}/var/tmp"/* 2>/dev/null || true

    ok "Live components removed."
}

# ── Personalise bundled user assets for installed account ──────
# The ISO build compiled AlternixDE as root. The system-wide binaries
# are already installed, but root's personal files only reach the new
# account through /etc/skel. Rewrite those old absolute build-account
# paths AFTER useradd -m (and BEFORE first installed boot).
personalise_prebuilt_home() {
    section "Installing Alternix user additions"

    local home="${ALTERNIX_MOUNT}/home/${ALTERNIX_USERNAME}"
    local relative
    for relative in \
        .alternix-prebuilt-home \
        .config/qtile/config.py \
        .config/Alternix/sounds \
        .local/share/applications/breakout.desktop \
        Pictures/wallpapers \
        extras/games/breakout.html; do
        [[ -e "$home/$relative" ]] || \
            die "Missing installed home asset: $relative (check /etc/skel in the ISO)."
    done
    [[ -x "${ALTERNIX_MOUNT}/usr/local/bin/osm-launcher" ]] || \
        die "The prebuilt osm-launcher binary is missing from the target."
    [[ -x "${ALTERNIX_MOUNT}/usr/local/bin/starship" ||
       -x "${ALTERNIX_MOUNT}/usr/bin/starship" ]] || \
        die "Starship was not copied into the target system."

    # Python3 is present in the prebuilt desktop and can update text
    # without touching PNGs, sounds, game resources or other binaries.
    python3 - "$home" "$ALTERNIX_USERNAME" <<'ALTUSERPATHPY' || \
        die "Could not personalise installed Alternix home paths."
import configparser
from pathlib import Path
import sys
home = Path(sys.argv[1])
name = sys.argv[2]
logical_home = '/home/' + name
rebase = {'/root/': logical_home + '/',
          '/home/alternix-live/': logical_home + '/',
          '/home/alternix-user/': logical_home + '/'}
suffixes = {'.conf', '.ini', '.desktop', '.py', '.sh', '.toml',
            '.json', '.cfg', '.yaml', '.yml', '.bashrc', '.profile',
            '.xinitrc'}
changed = 0
for folder in [home/'.config', home/'.local', home/'extras']:
    if not folder.is_dir():
        continue
    for p in folder.rglob('*'):
        if p.is_symlink() or not p.is_file() or p.suffix.lower() not in suffixes:
            continue
        if p.stat().st_size > 2_000_000:
            continue
        try:
            content = p.read_text(encoding='utf-8')
        except (UnicodeError, OSError):
            continue
        new = content
        for old, replacement in rebase.items():
            new = new.replace(old, replacement)
        if new != content:
            p.write_text(new, encoding='utf-8')
            changed += 1
# osm-paper-restore tests filesystem paths literally: the tilde in
# the user's original osm-paper.conf must be expanded for this account.
wallcfg = home/'.config/Alternix/osm-paper.conf'
if wallcfg.is_file():
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.read(wallcfg)
    if cfg.has_section('last'):
        path = cfg.get('last', 'wallpaper', fallback='').strip()
        if path.startswith('~/'):
            path = logical_home + '/' + path[2:]
        elif path.startswith('/root/'):
            path = logical_home + path[5:]
        cfg.set('last', 'wallpaper', path)
        with wallcfg.open('w') as stream:
            cfg.write(stream)
        if path.startswith(logical_home + '/'):
            installed_path = home / Path(path).relative_to(logical_home)
            if not installed_path.is_file():
                candidates = sorted(p for p in (home / 'Pictures/wallpapers').iterdir()
                    if p.is_file() and p.suffix.lower() in
                    {'.jpg', '.jpeg', '.png', '.bmp', '.webp'})
                if not candidates:
                    raise SystemExit('No wallpaper images in installed user home')
                path = logical_home + '/Pictures/wallpapers/' + candidates[0].name
                cfg.set('last', 'wallpaper', path)
                with wallcfg.open('w') as stream:
                    cfg.write(stream)
                print('  ! Missing selected wallpaper; using available image:', path)
print('  + Rebasing installed user config paths; updated files:', changed)
ALTUSERPATHPY

    # Ensure all inherited user assets belong to the installed user.
    chroot "$ALTERNIX_MOUNT" chown -R "${ALTERNIX_USERNAME}:${ALTERNIX_USERNAME}" \
        "/home/${ALTERNIX_USERNAME}" || die "Failed to assign installed home ownership."

    # Do not leave an ISO build marker in a real user's home directory.
    rm -f -- "$home/.alternix-prebuilt-home"
    ok "Prebuilt user assets installed for ${ALTERNIX_USERNAME}: sounds, wallpapers, Starship, games, icons, Qtile."
}

# ── Regenerate the initramfs for real hardware ────────────────────
finalise_copy() {
    section "Finalising"

    # ORDERING — DO NOT REORDER
    # This must run AFTER configure_system has written /etc/fstab and
    # AFTER delive_target removed live-boot. The initramfs embeds the
    # root device and the resume device from fstab; building it any
    # earlier bakes in the live system's idea of where root lives.
    if [[ ! -s "${ALTERNIX_MOUNT}/etc/fstab" ]]; then
        die "/etc/fstab is empty — the target will not boot. Check _configure_fstab ran."
    fi

    local fs
    for fs in proc sys dev dev/pts; do
        mkdir -p "${ALTERNIX_MOUNT}/${fs}"
        mountpoint -q "${ALTERNIX_MOUNT}/${fs}" || \
            mount --bind "/${fs}" "${ALTERNIX_MOUNT}/${fs}" 2>/dev/null || true
    done

    # Tablet-safe early userspace: include general storage modules and
    # common eMMC host drivers. Module existence is checked in the target
    # kernel tree to avoid warnings on kernels without a given driver.
    if [[ "${TARGET_DISK:-}" == /dev/mmcblk* ]]; then
        mkdir -p "${ALTERNIX_MOUNT}/etc/initramfs-tools"
        local initconf="${ALTERNIX_MOUNT}/etc/initramfs-tools/initramfs.conf"
        if [[ -f "$initconf" ]]; then
            if grep -q '^MODULES=' "$initconf"; then
                sed -i 's/^MODULES=.*/MODULES=most/' "$initconf"
            else
                echo 'MODULES=most' >> "$initconf"
            fi
        fi
        local module
        for module in mmc_block mmc_core sdhci sdhci_acpi sdhci_pci sdhci_pltfm; do
            if find "${ALTERNIX_MOUNT}/lib/modules" -type f \
                \( -name "${module}.ko" -o -name "${module}.ko.*" -o -name "${module//_/-}.ko*" \) \
                -print -quit 2>/dev/null | grep -q .; then
                grep -qx "$module" "${ALTERNIX_MOUNT}/etc/initramfs-tools/modules" 2>/dev/null || \
                    echo "$module" >> "${ALTERNIX_MOUNT}/etc/initramfs-tools/modules"
            fi
        done
    fi
    info "Rebuilding initramfs..."
    if ! chroot "$ALTERNIX_MOUNT" /bin/bash -c \
            "update-initramfs -u -k all" >>"$ALTERNIX_LOG" 2>&1; then
        # -c creates one where -u found nothing to update, which happens
        # when the image was built without an initramfs for this kernel.
        chroot "$ALTERNIX_MOUNT" /bin/bash -c \
            "update-initramfs -c -k all" >>"$ALTERNIX_LOG" 2>&1 || \
            die "update-initramfs failed; installation is not bootable."
    fi

    # Verify something was actually produced.
    if ! ls "${ALTERNIX_MOUNT}"/boot/initrd.img-* >/dev/null 2>&1; then
        die "No initramfs in /boot after update-initramfs. The target will not boot."
    fi

    for fs in dev/pts dev sys proc; do
        umount "${ALTERNIX_MOUNT}/${fs}" 2>/dev/null || true
    done

    # Make sure the actual kernel has a matching initramfs. An old
    # unrelated initrd alone must not count as a successful build.
    local kfile kversion
    for kfile in "${ALTERNIX_MOUNT}"/boot/vmlinuz-*; do
        [[ -f "$kfile" ]] || continue
        kversion="${kfile##*/vmlinuz-}"
        [[ -s "${ALTERNIX_MOUNT}/boot/initrd.img-${kversion}" ]] || \
            die "Kernel $kversion is missing its matching initramfs."
    done
    ok "Initramfs rebuilt and matched to installed kernels."
}

# ── dpkg tuning for the target ────────────────────────────────────
# dpkg calls fsync() after unpacking every single file. That is the
# right default for a running system and badly wrong for an install,
# where a failure means starting over anyway and there is nothing
# worth preserving. On eMMC and cheap SSDs, where random write IOPS
# are poor, this is most of the time spent "unpacking".
#
# Acquire::Languages "none" skips translation index downloads, which
# are pure overhead for an install.
#
# Both are undone by untune_target_dpkg before the install finishes,
# so the installed system keeps dpkg's safe defaults.
tune_target_dpkg() {
    mkdir -p "${ALTERNIX_MOUNT}/etc/dpkg/dpkg.cfg.d" \
             "${ALTERNIX_MOUNT}/etc/apt/apt.conf.d" 2>/dev/null || return 0

    cat > "${ALTERNIX_MOUNT}/etc/dpkg/dpkg.cfg.d/01-alternix-install-speed" << 'EOF'
# Temporary, removed at the end of the install by untune_target_dpkg.
force-unsafe-io
EOF

    cat > "${ALTERNIX_MOUNT}/etc/apt/apt.conf.d/01-alternix-install-speed" << 'EOF'
// Temporary, removed at the end of the install by untune_target_dpkg.
Acquire::Languages "none";
DPkg::Use-Pty "false";

// DOWNLOAD TIMEOUTS — the most likely reason an install appears to
// hang forever with no output. A stalled TCP connection to a mirror is
// far more likely behind a VM's NAT than on real hardware, and without
// a timeout the download waits indefinitely while printing nothing.
// That is indistinguishable from a crash. With these set, a stalled
// connection fails and is retried instead.
//
// APT reads these acquire settings, so this covers
// the AlternixDE package install as well as plain apt.
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::ftp::Timeout "30";
Acquire::Retries "3";
EOF

    info "Package unpacking tuned for install speed."
}

untune_target_dpkg() {
    rm -f "${ALTERNIX_MOUNT}/etc/dpkg/dpkg.cfg.d/01-alternix-install-speed" \
          "${ALTERNIX_MOUNT}/etc/apt/apt.conf.d/01-alternix-install-speed" \
          2>/dev/null || true
}
