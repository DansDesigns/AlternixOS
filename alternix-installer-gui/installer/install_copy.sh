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

    local c
    for c in "${candidates[@]}"; do
        if [[ -f "$c" ]]; then
            ALTERNIX_SQUASHFS="$c"
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

    local img_bytes avail_bytes need_bytes
    img_bytes=$(unsquashfs -s "$ALTERNIX_SQUASHFS" 2>/dev/null | \
        awk '/Filesystem size/ {print $3}' | head -1)
    # unsquashfs reports the *compressed* size; the unpacked tree is
    # larger. 2.6x is a conservative multiplier for zstd at this ratio.
    if [[ -n "$img_bytes" ]]; then
        need_bytes=$(awk -v b="$img_bytes" 'BEGIN{printf "%.0f", b * 2.6}')
    else
        need_bytes=0
    fi
    avail_bytes=$(df -B1 --output=avail "$ALTERNIX_MOUNT" 2>/dev/null | tail -1)

    if [[ -n "$avail_bytes" && "$need_bytes" -gt 0 ]] 2>/dev/null; then
        if (( avail_bytes < need_bytes )); then
            die "Not enough space on the target: need about $(( need_bytes / 1048576 )) MB, have $(( avail_bytes / 1048576 )) MB."
        fi
    fi

    info "Image: ${ALTERNIX_SQUASHFS}"

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
    local rc=0
    if [[ "${ALTERNIX_UNATTENDED:-0}" -eq 1 ]]; then
        set -o pipefail
        unsquashfs -f -d "$ALTERNIX_MOUNT" -p "$jobs" "$ALTERNIX_SQUASHFS" 2>&1 | \
            tr '\r' '\n' | \
            awk '
                {
                    if (match($0, /[0-9]+%/)) {
                        pct = substr($0, RSTART, RLENGTH - 1)
                        if (pct != last) {
                            print "##COPY:" pct
                            fflush()
                            last = pct
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
        spin_start "Unpacking system image..."
        unsquashfs -f -d "$ALTERNIX_MOUNT" -p "$jobs" "$ALTERNIX_SQUASHFS" \
            >>"$ALTERNIX_LOG" 2>&1
        rc=$?
        spin_stop
    fi

    if [[ $rc -ne 0 ]]; then
        die "unsquashfs failed (exit ${rc}). The install medium may be damaged."
    fi

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
        >>"$ALTERNIX_LOG" 2>&1 || warn "Some live packages were not present."

    _copy_chroot "DEBIAN_FRONTEND=noninteractive apt-get autoremove -y" \
        >>"$ALTERNIX_LOG" 2>&1 || true

    # Belt and braces: the initramfs hooks sometimes survive a purge
    # when the package was installed by live-build rather than apt.
    rm -f "${ALTERNIX_MOUNT}/usr/share/initramfs-tools/hooks/live" \
          "${ALTERNIX_MOUNT}/usr/share/initramfs-tools/scripts/live" \
          "${ALTERNIX_MOUNT}/usr/share/initramfs-tools/scripts/live-premount"/* \
          2>/dev/null || true
    rm -rf "${ALTERNIX_MOUNT}/lib/live" 2>/dev/null || true

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

    # ── Remove the live user ──────────────────────────────────────
    # live-config creates this account with a blank password and
    # passwordless sudo. It must not reach the installed system.
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
        sed -i '/autologin/d' "${ALTERNIX_MOUNT}/etc/inittab" 2>/dev/null || true
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

# ── Regenerate the initramfs for real hardware ────────────────────
finalise_copy() {
    section "Finalising"

    # ORDERING — DO NOT REORDER
    # This must run AFTER configure_system has written /etc/fstab and
    # AFTER delive_target removed live-boot. The initramfs embeds the
    # root device and the resume device from fstab; building it any
    # earlier bakes in the live system's idea of where root lives.
    if [[ ! -s "${ALTERNIX_MOUNT}/etc/fstab" ]]; then
        err "/etc/fstab is empty — the target will not boot. Check _configure_fstab ran."
    fi

    local fs
    for fs in proc sys dev dev/pts; do
        mkdir -p "${ALTERNIX_MOUNT}/${fs}"
        mountpoint -q "${ALTERNIX_MOUNT}/${fs}" || \
            mount --bind "/${fs}" "${ALTERNIX_MOUNT}/${fs}" 2>/dev/null || true
    done

    info "Rebuilding initramfs..."
    if ! chroot "$ALTERNIX_MOUNT" /bin/bash -c \
            "update-initramfs -u -k all" >>"$ALTERNIX_LOG" 2>&1; then
        # -c creates one where -u found nothing to update, which happens
        # when the image was built without an initramfs for this kernel.
        chroot "$ALTERNIX_MOUNT" /bin/bash -c \
            "update-initramfs -c -k all" >>"$ALTERNIX_LOG" 2>&1 || \
            err "update-initramfs failed — the installed system may not boot."
    fi

    # Verify something was actually produced.
    if ! ls "${ALTERNIX_MOUNT}"/boot/initrd.img-* >/dev/null 2>&1; then
        err "No initramfs in /boot after update-initramfs. The target will not boot."
    fi

    for fs in dev/pts dev sys proc; do
        umount "${ALTERNIX_MOUNT}/${fs}" 2>/dev/null || true
    done

    ok "Initramfs rebuilt."
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
EOF

    info "Package unpacking tuned for install speed."
}

untune_target_dpkg() {
    rm -f "${ALTERNIX_MOUNT}/etc/dpkg/dpkg.cfg.d/01-alternix-install-speed" \
          "${ALTERNIX_MOUNT}/etc/apt/apt.conf.d/01-alternix-install-speed" \
          2>/dev/null || true
}
