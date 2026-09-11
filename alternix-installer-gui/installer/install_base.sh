#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# install_base.sh — Alternix Base System Installation
# Debootstraps Devuan, installs kernel, sets up OpenRC
# ═══════════════════════════════════════════════════════════════

ALTERNIX_MOUNT="/mnt/alternix"
DEVUAN_MIRROR="http://deb.devuan.org/merged"
DEVUAN_SUITE="excalibur"   # Devuan 5 (Debian 12 base)

install_base() {
    section "Base System"

    info "Installing Devuan ${DEVUAN_SUITE} base..."
    echo ""

    # Check debootstrap is available
    if ! command -v debootstrap &>/dev/null; then
        die "debootstrap not found. Cannot install base system."
    fi

    step 1 5 "Bootstrapping Devuan ${DEVUAN_SUITE}..."
    echo ""

    # Map HW_ARCH to Debian arch naming (x86_64 -> amd64)
    local deb_arch="$HW_ARCH"
    case "$HW_ARCH" in
        x86_64)  deb_arch="amd64" ;;
        aarch64) deb_arch="arm64" ;;
        armv7*)  deb_arch="armhf" ;;
    esac

    # Run debootstrap with --no-check-gpg to avoid keyring issues in the live env.
    # The installed system will have the correct devuan-keyring package.
    if ! debootstrap \
        --no-check-gpg \
        --arch="${deb_arch}" \
        --include="bash,ca-certificates,wget" \
        "$DEVUAN_SUITE" \
        "$ALTERNIX_MOUNT" \
        "$DEVUAN_MIRROR" ; then
        die "debootstrap failed."
    fi
    ok "Bootstrap complete."
    echo ""

    # Bind mounts for chroot
    _bind_mounts

    step 2 5 "Configuring apt sources..."
    _write_sources
    ok "Sources written."
    echo ""

    step 3 5 "Installing kernel and core packages..."
    _install_packages
    echo ""

    step 4 5 "Setting up OpenRC..."
    _setup_openrc
    ok "OpenRC configured."
    echo ""

    step 5 5 "Installing bootloader..."
    _install_bootloader
    echo ""

    ok "Base system installed."
}

_bind_mounts() {
    mount --bind /dev  "${ALTERNIX_MOUNT}/dev"
    mount --bind /proc "${ALTERNIX_MOUNT}/proc"
    mount --bind /sys  "${ALTERNIX_MOUNT}/sys"
    mount --bind /run  "${ALTERNIX_MOUNT}/run"  2>/dev/null || true
    # resolv.conf for chroot network access
    cp /etc/resolv.conf "${ALTERNIX_MOUNT}/etc/resolv.conf"
}

_unbind_mounts() {
    umount "${ALTERNIX_MOUNT}/dev"  2>/dev/null || true
    umount "${ALTERNIX_MOUNT}/proc" 2>/dev/null || true
    umount "${ALTERNIX_MOUNT}/sys"  2>/dev/null || true
    umount "${ALTERNIX_MOUNT}/run"  2>/dev/null || true
}

_write_sources() {
    cat > "${ALTERNIX_MOUNT}/etc/apt/sources.list" << EOF
deb ${DEVUAN_MIRROR} ${DEVUAN_SUITE} main contrib non-free non-free-firmware
deb ${DEVUAN_MIRROR} ${DEVUAN_SUITE}-security main contrib non-free non-free-firmware
deb ${DEVUAN_MIRROR} ${DEVUAN_SUITE}-updates main contrib non-free non-free-firmware
EOF
}

_chroot() {
    chroot "$ALTERNIX_MOUNT" /bin/bash -c "$*"
}

_install_packages() {
    # ═══════════════════════════════════════════════════════════
    # CHROOT SERVICE FIX — DO NOT REMOVE
    # Package post-install scripts call invoke-rc.d → rc-service,
    # which fails inside the chroot and breaks packages (e.g. sudo).
    # Divert invoke-rc.d to a no-op stub for the whole install;
    # configure_system restores the original at the end.
    # ═══════════════════════════════════════════════════════════
    chroot "$ALTERNIX_MOUNT" dpkg-divert --local --rename --quiet         --add /usr/sbin/invoke-rc.d 2>/dev/null || true
    cat > "${ALTERNIX_MOUNT}/usr/sbin/invoke-rc.d" << 'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${ALTERNIX_MOUNT}/usr/sbin/invoke-rc.d"

    # Prevent services starting in chroot
    cat > "${ALTERNIX_MOUNT}/usr/sbin/policy-rc.d" << 'EOF'
#!/bin/sh
exit 101
EOF
    chmod +x "${ALTERNIX_MOUNT}/usr/sbin/policy-rc.d"

    cat > "${ALTERNIX_MOUNT}/usr/bin/systemctl" << 'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "${ALTERNIX_MOUNT}/usr/bin/systemctl"

    step 3 5 "Installing kernel..."
    echo ""

    # Update apt inside chroot first
    _chroot "apt-get update -qq" 2>&1 | tee -a "$ALTERNIX_LOG"

    # Install kernel FIRST and separately — most critical package
    info "Installing linux-image-amd64..."
    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y linux-image-amd64 initramfs-tools" \
        2>&1 | tee -a "$ALTERNIX_LOG" | while IFS= read -r line; do
            echo -e "  ${D}${line}${N}"
        done

    # Verify kernel installed
    if ls "${ALTERNIX_MOUNT}/boot/vmlinuz-"* &>/dev/null 2>&1; then
        local kver
        kver=$(ls "${ALTERNIX_MOUNT}/boot/vmlinuz-"* | sed -n '$p' | xargs basename)
        ok "Kernel installed: ${kver}"
    else
        err "Kernel NOT installed — apt-get failed. Check network and apt sources."
        err "Log: ${ALTERNIX_LOG}"
        return 1
    fi

    step 3 5 "Installing core packages..."
    echo ""

    # Core packages
    local pkgs=(
        "openrc" "sysvinit-utils" "elogind" "libpam-elogind"
        "grub-pc" "grub-efi-amd64" "os-prober"
        "bash" "coreutils" "util-linux" "procps" "psmisc"
        "findutils" "grep" "sed" "gawk"
        "iproute2" "iputils-ping" "wget" "curl"
        "iw" "wireless-tools" "wpasupplicant" "dhcpcd5" "rfkill"
        "firmware-iwlwifi" "firmware-realtek" "firmware-atheros"
        "firmware-brcm80211" "bluez-firmware" "firmware-intel-sound"
        "e2fsprogs" "dosfstools" "parted"
        "ca-certificates" "locales" "tzdata"
        "sudo" "openssh-client" "nano" "htop" "pciutils"
    )

    if [[ "$HW_ARCH" == "aarch64" ]]; then
        pkgs=("${pkgs[@]/grub-pc/}")
        pkgs=("${pkgs[@]/grub-efi-amd64/grub-efi-arm64}")
    fi

    local apt_ok=0
    for attempt in 1 2; do
        _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
            --no-install-recommends ${pkgs[*]}" \
            2>&1 | tee -a "$ALTERNIX_LOG" | while IFS= read -r line; do
                [[ "$line" == *"Unpacking"* || "$line" == *"Setting up"* ]] && \
                    echo -e "  ${D}${line}${N}"
            done
        # PIPESTATUS[0] is apt-get's real exit code — the pipeline's own
        # $? would just be the while-loop's, which is not what we want.
        if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
            apt_ok=1
            break
        fi
        warn "apt-get install failed (attempt ${attempt}/2) — see ${ALTERNIX_LOG}"
        [[ $attempt -eq 1 ]] && warn "Retrying once (known mirror flakiness)..."
    done

    if [[ $apt_ok -eq 1 ]]; then
        ok "Core packages installed."
    else
        err "Core packages FAILED to install after 2 attempts — check ${ALTERNIX_LOG}"
    fi

    # WIFI FIRMWARE VERIFICATION — DO NOT REMOVE
    # apt can report success while an individual package's files still
    # fail to extract (mirror hiccup, disk quirk, etc.) — this exact
    # failure mode has hit both an ath10k (Qualcomm) machine and a brcm
    # (Broadcom) machine on this project, on different installs, with
    # apt reporting success both times. Rather than a blind check across
    # every vendor's directory, use the hardware actually detected
    # (detect_network_hardware, called from detect_hardware earlier) to
    # verify — and if needed, specifically retry — the ONE package this
    # machine actually needs.
    if [[ "$HW_WIFI_CHIP" != "none" && -n "$HW_WIFI_CHIP" ]]; then
        info "Detected WiFi: ${HW_WIFI_DESC} (${HW_WIFI_CHIP})"
        local fw_missing=0
        case "$HW_WIFI_CHIP" in
            ath10k)  [[ -d "${ALTERNIX_MOUNT}/lib/firmware/ath10k" ]] || fw_missing=1 ;;
            brcm)    [[ -d "${ALTERNIX_MOUNT}/lib/firmware/brcm"   ]] || fw_missing=1 ;;
            iwlwifi) ls "${ALTERNIX_MOUNT}"/lib/firmware/iwlwifi-*.ucode &>/dev/null || fw_missing=1 ;;
            realtek) [[ -d "${ALTERNIX_MOUNT}/lib/firmware/rtlwifi" || -d "${ALTERNIX_MOUNT}/lib/firmware/rtw88" ]] || fw_missing=1 ;;
        esac

        if [[ $fw_missing -eq 1 ]]; then
            warn "Firmware for detected WiFi (${HW_WIFI_CHIP}) is missing — retrying ${HW_WIFI_FIRMWARE_PKGS[*]}..."
            _chroot "DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y ${HW_WIFI_FIRMWARE_PKGS[*]}" \
                2>&1 | tee -a "$ALTERNIX_LOG" >/dev/null
            case "$HW_WIFI_CHIP" in
                ath10k)  [[ -d "${ALTERNIX_MOUNT}/lib/firmware/ath10k" ]] && fw_missing=0 ;;
                brcm)    [[ -d "${ALTERNIX_MOUNT}/lib/firmware/brcm"   ]] && fw_missing=0 ;;
                iwlwifi) ls "${ALTERNIX_MOUNT}"/lib/firmware/iwlwifi-*.ucode &>/dev/null && fw_missing=0 ;;
                realtek) { [[ -d "${ALTERNIX_MOUNT}/lib/firmware/rtlwifi" ]] || [[ -d "${ALTERNIX_MOUNT}/lib/firmware/rtw88" ]]; } && fw_missing=0 ;;
            esac
            if [[ $fw_missing -eq 1 ]]; then
                err "Still missing after retry — WiFi will not work on this hardware without ${HW_WIFI_FIRMWARE_PKGS[*]}. Check ${ALTERNIX_LOG}."
            else
                ok "Firmware for ${HW_WIFI_CHIP} confirmed present after retry."
            fi
        else
            ok "Firmware for ${HW_WIFI_CHIP} confirmed present."
        fi
    else
        info "No WiFi hardware detected — skipping WiFi firmware verification."
    fi

    # Show /boot contents for verification
    info "/boot contents:"
    ls "${ALTERNIX_MOUNT}/boot/" 2>/dev/null | while IFS= read -r f; do info "  ${f}"; done
}

_setup_openrc() {
    # Remove policy-rc.d and systemctl stub
    rm -f "${ALTERNIX_MOUNT}/usr/sbin/policy-rc.d"
    rm -f "${ALTERNIX_MOUNT}/usr/bin/systemctl"

    # Enable essential services
    local services=(
        "bootmisc"
        "hostname"
        "hwclock"
        "keymaps"
        "localmount"
        "modules"
        "mount-ro"
        "net.lo"
        "netmount"
        "procfs"
        "root"
        "swap"
        "sysctl"
        "udev"
        "urandom"
    )

    for svc in "${services[@]}"; do
        _chroot "rc-update add ${svc} default 2>/dev/null || true"
    done

    # elogind
    _chroot "rc-update add elogind default 2>/dev/null || true"
}

# ── Visor UEFI boot manager ───────────────────────────────────────
# https://github.com/IO-ZetZor/Visor-BootManager
# Graphical UEFI boot manager. UEFI-only; BIOS systems keep GRUB.
# Visor ships no ext4 driver, so kernel+initrd are copied to the ESP
# under unversioned names, with a kernel hook to re-sync on updates.
_install_visor() {
    local esp="${ALTERNIX_MOUNT}/boot/efi"
    local root_uuid="$1"

    info "Installing Visor boot manager..."

    # Build deps (gcc/make/git already in the live ISO)
    apt-get install -y gnu-efi efibootmgr 2>>"$ALTERNIX_LOG" || true

    # Clone and build
    rm -rf /tmp/visor-build
    if ! git clone --depth=1 \
        https://github.com/IO-ZetZor/Visor-BootManager.git \
        /tmp/visor-build 2>&1 | tee -a "$ALTERNIX_LOG"; then
        warn "Visor clone failed."
        return 1
    fi

    if ! (cd /tmp/visor-build && make) 2>&1 | tee -a "$ALTERNIX_LOG"; then
        warn "Visor build failed."
        return 1
    fi

    [[ -f /tmp/visor-build/visor_x64.efi ]] || { warn "visor_x64.efi not produced."; return 1; }

    # Install binary + assets onto the ESP
    mkdir -p "${esp}/EFI/visor/icons" \
             "${esp}/EFI/visor/backgrounds" \
             "${esp}/EFI/visor/themes" \
             "${esp}/EFI/alternix" \
             "${esp}/EFI/BOOT"
    cp /tmp/visor-build/visor_x64.efi "${esp}/EFI/visor/"
    cp /tmp/visor-build/assets/icons/*.png "${esp}/EFI/visor/icons/" 2>/dev/null || true
    cp /tmp/visor-build/assets/backgrounds/*.png "${esp}/EFI/visor/backgrounds/" 2>/dev/null || true

    # Fallback path so firmware finds it without an NVRAM entry
    cp /tmp/visor-build/visor_x64.efi "${esp}/EFI/BOOT/BOOTX64.EFI"

    # Custom background from branding if present
    local bg_line=""
    for bg_src in /boot/grub/background.png \
                  "${INSTALLER_DIR}/../branding/grub-background.png"; do
        if [[ -f "$bg_src" ]]; then
            cp "$bg_src" "${esp}/EFI/visor/backgrounds/alternix.png"
            bg_line='background=\EFI\visor\backgrounds\alternix.png'
            break
        fi
    done

    # Copy kernel + initrd to ESP with UNVERSIONED names
    local kernel initrd
    kernel=$(ls "${ALTERNIX_MOUNT}/boot/vmlinuz-"* 2>/dev/null | sort | sed -n '$p')
    initrd=$(ls "${ALTERNIX_MOUNT}/boot/initrd.img-"* 2>/dev/null | sort | sed -n '$p')
    [[ -z "$kernel" || -z "$initrd" ]] && { warn "Kernel/initrd missing for Visor."; return 1; }
    cp "$kernel" "${esp}/EFI/alternix/vmlinuz"
    cp "$initrd" "${esp}/EFI/alternix/initrd.img"

    # Write boot.conf
    cat > "${esp}/EFI/visor/boot.conf" << VISOREOF
timeout=5
default=0
title=Alternix
${bg_line}

linux {
    name    = "Alternix"
    type    = linux
    icon    = \\EFI\\visor\\icons\\linux.png
    kernel  = \\EFI\\alternix\\vmlinuz
    initrd  = \\EFI\\alternix\\initrd.img
    cmdline = "root=UUID=${root_uuid} ro quiet"
}

linux {
    name    = "Alternix (recovery)"
    type    = linux
    icon    = \\EFI\\visor\\icons\\linux.png
    kernel  = \\EFI\\alternix\\vmlinuz
    initrd  = \\EFI\\alternix\\initrd.img
    cmdline = "root=UUID=${root_uuid} ro single"
}
VISOREOF

    # Register firmware boot entry
    if command -v efibootmgr &>/dev/null; then
        local esp_part disk part_num
        esp_part="${PART_EFI:-}"
        if [[ -n "$esp_part" ]]; then
            disk=$(echo "$esp_part" | sed 's/[0-9]*$//' | sed 's/p$//')
            part_num=$(echo "$esp_part" | grep -o '[0-9]*$')
            # REMOVE OLD ENTRIES FIRST — DO NOT SKIP
            # efibootmgr --create always adds a new entry, it never
            # replaces one. Reinstalling therefore left a stack of
            # identical entries in NVRAM, one per install. Delete any
            # previous Alternix or Visor entries before adding this one.
            local _old_entry
            while read -r _old_entry; do
                [[ -n "$_old_entry" ]] || continue
                info "Removing old UEFI entry Boot${_old_entry}"
                efibootmgr --delete-bootnum --bootnum "$_old_entry" \
                    >>"$ALTERNIX_LOG" 2>&1 || true
            done < <(efibootmgr 2>/dev/null | \
                     grep -iE '^Boot[0-9A-F]{4}\*? +(Alternix|Visor)\b' | \
                     sed -E 's/^Boot([0-9A-F]{4}).*/\1/')

            # The label is what the firmware boot menu shows the user,
            # so it names the operating system, not the boot manager.
            efibootmgr --create --disk "$disk" --part "$part_num" \
                --label "Alternix" --loader '\EFI\visor\visor_x64.efi' \
                2>&1 | tee -a "$ALTERNIX_LOG" || true
        fi
    fi

    # Kernel-update hook in target: re-sync kernel/initrd to ESP
    mkdir -p "${ALTERNIX_MOUNT}/etc/kernel/postinst.d"
    cat > "${ALTERNIX_MOUNT}/etc/kernel/postinst.d/zz-visor-sync" << 'HOOKEOF'
#!/bin/sh
# Sync newest kernel/initrd to the ESP for the Visor boot manager
ESP=/boot/efi
[ -d "$ESP/EFI/alternix" ] || exit 0
K=$(ls /boot/vmlinuz-* 2>/dev/null | sort | tail -1)
I=$(ls /boot/initrd.img-* 2>/dev/null | sort | tail -1)
[ -n "$K" ] && cp "$K" "$ESP/EFI/alternix/vmlinuz"
[ -n "$I" ] && cp "$I" "$ESP/EFI/alternix/initrd.img"
exit 0
HOOKEOF
    chmod +x "${ALTERNIX_MOUNT}/etc/kernel/postinst.d/zz-visor-sync"
    # initramfs updates too
    mkdir -p "${ALTERNIX_MOUNT}/etc/initramfs/post-update.d"
    cp "${ALTERNIX_MOUNT}/etc/kernel/postinst.d/zz-visor-sync" \
       "${ALTERNIX_MOUNT}/etc/initramfs/post-update.d/zz-visor-sync"

    rm -rf /tmp/visor-build
    ok "Visor installed — graphical boot menu on next start."
    return 0
}

_install_bootloader() {
    section "Bootloader"

    # Re-detect EFI properly
    if [[ -d /sys/firmware/efi/efivars ]] && ls /sys/firmware/efi/efivars/ &>/dev/null 2>&1; then
        USE_EFI=1
        info "EFI system detected."
    else
        USE_EFI=0
        info "BIOS/Legacy system detected."
    fi

    info "Target disk: ${TARGET_DISK}"
    info "Boot mode:   $([ $USE_EFI -eq 1 ] && echo EFI || echo BIOS)"
    echo ""

    # Ensure grub-install is available
    if ! command -v grub-install &>/dev/null; then
        warn "grub-install not found — installing..."
        apt-get install -y grub2-common grub-pc-bin grub-efi-amd64-bin 2>>"$ALTERNIX_LOG" || true
    fi

    if ! command -v grub-install &>/dev/null; then
        err "grub-install not available. Cannot install bootloader."
        return 1
    fi

    info "grub-install path: $(which grub-install)"
    echo ""

    # Install grub
    # UEFI: Visor is the primary boot manager; GRUB-EFI is the fallback
    local visor_ok=0
    if [[ $USE_EFI -eq 1 ]]; then
        local _root_uuid
        _root_uuid=$(blkid -s UUID -o value "${PART_ROOT}")
        if _install_visor "$_root_uuid"; then
            visor_ok=1
            ok "Visor is the boot manager (GRUB config still written as backup)."
        else
            warn "Visor install failed — falling back to GRUB (EFI)."
        fi
    fi

    if [[ $USE_EFI -eq 1 && $visor_ok -eq 0 ]]; then
        info "Running grub-install (EFI)..."
        grub-install             --target=x86_64-efi             --efi-directory="${ALTERNIX_MOUNT}/boot/efi"             --boot-directory="${ALTERNIX_MOUNT}/boot"             --bootloader-id=Alternix             --recheck             --no-floppy             2>&1 | tee -a "$ALTERNIX_LOG"
        local exit1=${PIPESTATUS[0]}
        if [[ $exit1 -ne 0 ]]; then
            warn "EFI grub-install failed (${exit1}) — trying BIOS fallback."
            USE_EFI=0
        else
            ok "GRUB (EFI) installed."
            # Also install BIOS fallback MBR so machine boots even without EFI NVRAM entry
            info "Installing BIOS fallback MBR..."
            grub-install                 --target=i386-pc                 --boot-directory="${ALTERNIX_MOUNT}/boot"                 --recheck                 --no-floppy                 "${TARGET_DISK}"                 2>&1 | tee -a "$ALTERNIX_LOG" || true
            # Copy EFI bootloader to fallback path so UEFI finds it automatically
            local efi_boot="${ALTERNIX_MOUNT}/boot/efi/EFI/BOOT"
            local efi_alternix="${ALTERNIX_MOUNT}/boot/efi/EFI/Alternix"
            mkdir -p "$efi_boot"
            if [[ -f "${efi_alternix}/grubx64.efi" ]]; then
                cp "${efi_alternix}/grubx64.efi" "${efi_boot}/BOOTX64.EFI"
                ok "EFI fallback bootloader copied to EFI/BOOT/BOOTX64.EFI"
            fi
        fi
    fi

    if [[ $USE_EFI -eq 0 ]]; then
        info "Running grub-install (BIOS) on ${TARGET_DISK}..."
        grub-install \
            --target=i386-pc \
            --boot-directory="${ALTERNIX_MOUNT}/boot" \
            --recheck \
            --no-floppy \
            "${TARGET_DISK}" \
            2>&1 | tee -a "$ALTERNIX_LOG"
        local exit2=${PIPESTATUS[0]}
        if [[ $exit2 -ne 0 ]]; then
            err "BIOS grub-install failed (${exit2})."
            return 1
        fi
        ok "GRUB (BIOS) installed to ${TARGET_DISK}."
    fi

    # Mount filesystems needed by update-grub
    info "Mounting filesystems for update-grub..."
    for fs in proc sys dev dev/pts; do
        mkdir -p "${ALTERNIX_MOUNT}/${fs}"
        mount --bind "/${fs}" "${ALTERNIX_MOUNT}/${fs}" 2>/dev/null || true
    done

    info "Running update-grub..."
    _chroot "update-grub" 2>&1 | tee -a "$ALTERNIX_LOG"

    # Unmount
    for fs in dev/pts dev sys proc; do
        umount "${ALTERNIX_MOUNT}/${fs}" 2>/dev/null || true
    done

    # ═══════════════════════════════════════════════════════════
    # KERNEL BOOT FIX — DO NOT REMOVE
    # update-grub inside a chroot cannot detect a separate /boot
    # partition and writes wrong kernel paths. We ALWAYS overwrite
    # grub.cfg with a known-good config here.
    # ═══════════════════════════════════════════════════════════
    local kernel initrd root_uuid boot_uuid kernel_prefix
    kernel=$(ls "${ALTERNIX_MOUNT}/boot/vmlinuz-"* 2>/dev/null | sort | sed -n '$p' | xargs basename 2>/dev/null)
    initrd=$(ls "${ALTERNIX_MOUNT}/boot/initrd.img-"* 2>/dev/null | sort | sed -n '$p' | xargs basename 2>/dev/null)

    if [[ -z "$kernel" ]]; then
        err "NO KERNEL in ${ALTERNIX_MOUNT}/boot — system cannot boot!"
        err "Contents of /boot:"
        ls "${ALTERNIX_MOUNT}/boot/" | while IFS= read -r f; do err "  $f"; done
        return 1
    fi

    root_uuid=$(blkid -s UUID -o value "${PART_ROOT}")

    # Separate /boot partition: kernel lives at partition root, no /boot prefix
    if [[ -n "${PART_BOOT:-}" ]]; then
        boot_uuid=$(blkid -s UUID -o value "${PART_BOOT}")
        kernel_prefix=""
    else
        boot_uuid="$root_uuid"
        kernel_prefix="/boot"
    fi

    info "Writing grub.cfg  (kernel: ${kernel}, boot UUID: ${boot_uuid})"

    mkdir -p "${ALTERNIX_MOUNT}/boot/grub"

    # GRUB BACKGROUND — copy from live env (ISO embeds it) or branding dir
    for bg_src in /boot/grub/background.png \
                  "${INSTALLER_DIR}/../branding/grub-background.png" \
                  /branding/grub-background.png; do
        if [[ -f "$bg_src" ]]; then
            cp "$bg_src" "${ALTERNIX_MOUNT}/boot/grub/background.png"
            ok "GRUB background installed."
            break
        fi
    done
    cat > "${ALTERNIX_MOUNT}/boot/grub/grub.cfg" << GRUBEOF
set default=0
set timeout=5

insmod part_gpt
insmod part_msdos
insmod ext2

if [ -e \${prefix}/background.png ]; then
    insmod png
    background_image \${prefix}/background.png
fi

menuentry "Alternix" {
    search --no-floppy --fs-uuid --set=root ${boot_uuid}
    linux ${kernel_prefix}/${kernel} root=UUID=${root_uuid} ro quiet
    initrd ${kernel_prefix}/${initrd}
}

menuentry "Alternix (recovery)" {
    search --no-floppy --fs-uuid --set=root ${boot_uuid}
    linux ${kernel_prefix}/${kernel} root=UUID=${root_uuid} ro single
    initrd ${kernel_prefix}/${initrd}
}
GRUBEOF

    ok "grub.cfg written."
    info "Kernel line: linux ${kernel_prefix}/${kernel} root=UUID=${root_uuid}"

    ok "Bootloader installation complete."
    info "grub.cfg first lines:"
    head -8 "${ALTERNIX_MOUNT}/boot/grub/grub.cfg" | while IFS= read -r l; do
        echo "    $l"
    done
}

cleanup_mounts() {
    _unbind_mounts
}
