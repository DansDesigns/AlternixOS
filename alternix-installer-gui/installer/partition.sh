#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# partition.sh — Alternix Installer Disk Partitioning
# Modes: guided (auto layout), manual (user-defined)
# ═══════════════════════════════════════════════════════════════

TARGET_DISK=""
PART_EFI=""
PART_BOOT=""
PART_ROOT=""
PART_SWAP=""
PART_HOME=""
USE_EFI=0
USE_SWAP=0
USE_HOME=0

# ── Detect EFI ───────────────────────────────────────────────────
detect_efi() {
    [[ -d /sys/firmware/efi ]] && USE_EFI=1 || USE_EFI=0
}

# ── List available disks ──────────────────────────────────────────
list_disks() {
    for dev in /sys/block/*; do
        local name size_bytes human model
        name=$(basename "$dev")
        case "$name" in
            loop*|ram*|sr*|fd*|dm-*|zram*|md*) continue ;;
        esac
        [[ -f "${dev}/size" ]] || continue
        size_bytes=$(cat "${dev}/size" 2>/dev/null || echo 0)
        [[ "$size_bytes" -gt 0 ]] 2>/dev/null || continue
        human=$(lsblk -dbn -o SIZE "/dev/${name}" 2>/dev/null |             awk '{s=$1; if(s>=1099511627776) printf "%.0fT",s/1099511627776;             else if(s>=1073741824) printf "%.0fG",s/1073741824;             else printf "%.0fM",s/1048576}')
        model=""
        for mpath in "${dev}/device/model" "${dev}/device/name"; do
            [[ -f "$mpath" ]] && model=$(tr -d "
" < "$mpath" | sed "s/  */ /g;s/^ //;s/ $//") && break
        done
        [[ -z "$model" ]] && model="Unknown"
        printf "/dev/%s\t%s\t%s\n" "$name" "$human" "$model"
    done
}

# ── Disk selection TUI ────────────────────────────────────────────
select_disk() {
    section "Disk Selection"

    echo -e "  ${W}Available disks:${N}"
    echo ""

    # Detect which disk the live ISO booted from
    local live_disk=""
    local _root_dev
    _root_dev=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
    if [[ -n "$_root_dev" ]]; then
        live_disk=$(lsblk -no PKNAME "$_root_dev" 2>/dev/null | head -1)
        [[ -n "$live_disk" ]] && live_disk="/dev/${live_disk}"
    fi

    local disks=()
    local sizes=()
    local models=()
    while IFS=$'\t' read -r dev size model; do
        disks+=("$dev")
        sizes+=("$size")
        models+=("$model")
    done < <(list_disks)

    if [[ ${#disks[@]} -eq 0 ]]; then
        die "No disks found."
    fi

    [[ -n "$live_disk" ]] && warn "Live USB detected on ${live_disk} — do not install to this disk."
    echo ""

    local i
    for (( i=0; i<${#disks[@]}; i++ )); do
        local tag=""
        [[ "${disks[$i]}" == "$live_disk" ]] && tag="  ← live USB"
        printf "  ${T}%2d${N}  %-12s  %-8s  %s%s\n" \
            $(( i+1 )) "${disks[$i]}" "${sizes[$i]}" "${models[$i]}" "$tag"
    done
    echo ""
    echo ""

    while true; do
        echo -en "  ${W}Select target disk${N}: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           (( choice >= 1 && choice <= ${#disks[@]} )); then
            TARGET_DISK="${disks[$((choice-1))]}"
            break
        fi
        warn "Invalid selection."
    done

    echo ""
    warn "ALL DATA ON ${TARGET_DISK} WILL BE DESTROYED."
    echo ""
    if ! confirm "Continue with ${TARGET_DISK}?"; then
        select_disk
    fi
}

# ── Partition mode selection ──────────────────────────────────────
select_partition_mode() {
    section "Partitioning"

    echo -e "  ${W}Partitioning mode:${N}"
    echo ""
    echo -e "  ${T}1${N}  ${W}Guided${N}      — Automatic layout (recommended)"
    echo -e "  ${T}2${N}  ${W}Manual${N}       — Define your own partitions"
    echo ""

    while true; do
        echo -en "  ${W}Select mode${N}: "
        read -r choice
        case "$choice" in
            1) partition_guided; return ;;
            2) partition_manual; return ;;
            *) warn "Enter 1 or 2." ;;
        esac
    done
}

# ── Guided partitioning ───────────────────────────────────────────
partition_guided() {
    section "Guided Partitioning"

    local disk_size_mb
    disk_size_mb=$(lsblk -b -d -o SIZE --noheadings "$TARGET_DISK" | \
        awk '{printf "%d", $1/1024/1024}')

    info "Disk: ${TARGET_DISK}  (${disk_size_mb} MB)"
    echo ""

    # Swap option
    if [[ "${ALTERNIX_UNATTENDED:-0}" -eq 1 ]]; then
        swap_mb="${SWAP_MB:-0}"
        [[ "${USE_SWAP:-0}" -eq 1 ]] || swap_mb=0
    elif confirm "Create a swap partition?"; then
        USE_SWAP=1
        echo -en "  ${W}Swap size in MB${N} ${D}[2048]${N}: "
        read -r swap_mb
        [[ -z "$swap_mb" ]] && swap_mb=2048
    fi

    # Separate /home option — ENTER defaults to no
    local home_ans
    if [[ "${ALTERNIX_UNATTENDED:-0}" -ne 1 ]]; then
        echo -en "  ${W}Create a separate /home partition?${N} ${D}[y/N] (default is no)${N} "
        read -r home_ans
        if [[ "$home_ans" =~ ^[yY] ]]; then
            USE_HOME=1
        fi
    fi

    echo ""
    echo -e "  ${W}Planned layout:${N}"
    echo ""

    if [[ $USE_EFI -eq 1 ]]; then
        echo -e "  ${D}·${N}  ${T}512 MB${N}   EFI System Partition  (FAT32)"
    fi
    echo -e "  ${D}·${N}  ${T}512 MB${N}   /boot                 (ext4)"
    if [[ $USE_SWAP -eq 1 ]]; then
        echo -e "  ${D}·${N}  ${T}${swap_mb} MB${N}  swap"
    fi
    if [[ $USE_HOME -eq 1 ]]; then
        echo -e "  ${D}·${N}  ${T}30 GB${N}    /  (root)              (ext4)"
        echo -e "  ${D}·${N}  ${T}rest${N}     /home                  (ext4)"
    else
        echo -e "  ${D}·${N}  ${T}rest${N}     /  (root)              (ext4)"
    fi
    echo ""

    if [[ "${ALTERNIX_UNATTENDED:-0}" -ne 1 ]]; then
        confirm "Apply this layout?" || { partition_guided; return; }
    fi

    _do_guided_partition "$swap_mb"
}

_do_guided_partition() {
    local swap_mb="${1:-0}"

    info "Wiping existing partition table on ${TARGET_DISK}..."
    wipefs -a "$TARGET_DISK" &>/dev/null
    dd if=/dev/zero of="$TARGET_DISK" bs=1M count=10 &>/dev/null

    if [[ $USE_EFI -eq 1 ]]; then
        parted -s "$TARGET_DISK" mklabel gpt
    else
        parted -s "$TARGET_DISK" mklabel msdos
    fi

    local start=1  # MB
    local part_n=1

    # EFI
    if [[ $USE_EFI -eq 1 ]]; then
        parted -s "$TARGET_DISK" mkpart primary fat32 "${start}MiB" "513MiB"
        parted -s "$TARGET_DISK" set $part_n esp on
        PART_EFI="${TARGET_DISK}${part_n}"
        start=513
        (( part_n++ ))
    fi

    # /boot
    local boot_end=$(( start + 512 ))
    parted -s "$TARGET_DISK" mkpart primary ext4 "${start}MiB" "${boot_end}MiB"
    if [[ $USE_EFI -eq 0 ]]; then
        parted -s "$TARGET_DISK" set $part_n boot on
    fi
    PART_BOOT="${TARGET_DISK}${part_n}"
    start=$boot_end
    (( part_n++ ))

    # swap
    if [[ $USE_SWAP -eq 1 ]]; then
        local swap_end=$(( start + swap_mb ))
        parted -s "$TARGET_DISK" mkpart primary linux-swap "${start}MiB" "${swap_end}MiB"
        PART_SWAP="${TARGET_DISK}${part_n}"
        start=$swap_end
        (( part_n++ ))
    fi

    # root (and optionally home)
    if [[ $USE_HOME -eq 1 ]]; then
        local root_end=$(( start + 30720 ))  # 30 GB
        parted -s "$TARGET_DISK" mkpart primary ext4 "${start}MiB" "${root_end}MiB"
        PART_ROOT="${TARGET_DISK}${part_n}"
        start=$root_end
        (( part_n++ ))
        parted -s "$TARGET_DISK" mkpart primary ext4 "${start}MiB" "100%"
        PART_HOME="${TARGET_DISK}${part_n}"
    else
        parted -s "$TARGET_DISK" mkpart primary ext4 "${start}MiB" "100%"
        PART_ROOT="${TARGET_DISK}${part_n}"
    fi

    # NVMe AND eMMC (mmcblk) — and loop devices — use p1/p2 suffix
    # notation, not plain concatenation. eMMC is the common storage on
    # Atom-based tablets (ElitePad, Linx 810b, etc.) — without this,
    # PART_ROOT etc. point at a device node that doesn't exist, mkfs/mount
    # silently fail, and the install ends up writing into the live
    # overlay's tmpfs instead of the real disk. DO NOT REMOVE.
    if [[ "$TARGET_DISK" == *"nvme"* || "$TARGET_DISK" == *"mmcblk"* || "$TARGET_DISK" == *"loop"* ]]; then
        [[ -n "$PART_EFI"  ]] && PART_EFI="${TARGET_DISK}p${PART_EFI##${TARGET_DISK}}"
        [[ -n "$PART_BOOT" ]] && PART_BOOT="${TARGET_DISK}p${PART_BOOT##${TARGET_DISK}}"
        [[ -n "$PART_SWAP" ]] && PART_SWAP="${TARGET_DISK}p${PART_SWAP##${TARGET_DISK}}"
        [[ -n "$PART_ROOT" ]] && PART_ROOT="${TARGET_DISK}p${PART_ROOT##${TARGET_DISK}}"
        [[ -n "$PART_HOME" ]] && PART_HOME="${TARGET_DISK}p${PART_HOME##${TARGET_DISK}}"
    fi

    sleep 1
    partprobe "$TARGET_DISK" 2>/dev/null || true

    _format_partitions
}

# ── Manual partitioning ───────────────────────────────────────────
partition_manual() {
    section "Manual Partitioning"

    warn "Manual mode: you are responsible for creating valid partitions."
    info "Use cfdisk or parted in another TTY (Alt+F2), then return here."
    echo ""

    if confirm "Open cfdisk now?"; then
        cfdisk "$TARGET_DISK"
    fi

    echo ""
    info "Current partition table:"
    lsblk "$TARGET_DISK"
    echo ""

    # Ask user to assign each mount point
    local parts=()
    while IFS= read -r p; do
        parts+=("$p")
    done < <(lsblk -o NAME,SIZE --noheadings "$TARGET_DISK" | \
        tail -n +2 | awk '{print "/dev/"$1}' | sed 's/[[:space:]]//g')

    echo -e "  ${W}Assign partitions:${N}"
    echo ""

    local p
    for p in "${parts[@]}"; do
        local size
        size=$(lsblk -d -o SIZE --noheadings "$p" 2>/dev/null || echo "?")
        echo -e "  ${T}${p}${N}  (${size})"
        echo -e "  ${D}Roles: root / boot / efi / swap / home / skip${N}"
        echo -en "  ${W}Role${N}: "
        read -r role
        case "$role" in
            root)  PART_ROOT="$p" ;;
            boot)  PART_BOOT="$p" ;;
            efi)   PART_EFI="$p"; USE_EFI=1 ;;
            swap)  PART_SWAP="$p"; USE_SWAP=1 ;;
            home)  PART_HOME="$p"; USE_HOME=1 ;;
            skip)  ;;
            *)     warn "Unknown role, skipping ${p}." ;;
        esac
        echo ""
    done

    if [[ -z "$PART_ROOT" ]]; then
        die "No root partition assigned."
    fi

    _format_partitions
}

# ── Format partitions ─────────────────────────────────────────────
_format_partitions() {
    section "Formatting"

    if [[ -n "$PART_EFI" ]]; then
        spin_start "Formatting EFI  (${PART_EFI})..."
        mkfs.fat -F32 "$PART_EFI" &>/dev/null
        spin_stop; ok "EFI formatted."
    fi

    if [[ -n "$PART_BOOT" ]]; then
        spin_start "Formatting /boot (${PART_BOOT})..."
        mkfs.ext4 -F "$PART_BOOT" &>/dev/null
        spin_stop; ok "/boot formatted."
    fi

    spin_start "Formatting /     (${PART_ROOT})..."
    if ! mkfs.ext4 -F "$PART_ROOT" &>/dev/null; then
        spin_stop
        die "Failed to format root partition ${PART_ROOT} — does that device exist? (check partition naming for this disk type)"
    fi
    spin_stop; ok "/ formatted."

    if [[ -n "$PART_SWAP" ]]; then
        spin_start "Formatting swap  (${PART_SWAP})..."
        mkswap "$PART_SWAP" &>/dev/null
        spin_stop; ok "swap formatted."
    fi

    if [[ -n "$PART_HOME" ]]; then
        spin_start "Formatting /home (${PART_HOME})..."
        mkfs.ext4 -F "$PART_HOME" &>/dev/null
        spin_stop; ok "/home formatted."
    fi
}

# ── Mount partitions ──────────────────────────────────────────────
mount_partitions() {
    local mnt="${1:-/mnt/alternix}"

    section "Mounting"
    mkdir -p "$mnt"

    # MOUNT CHECK — DO NOT REMOVE
    # If this silently fails, ${mnt} stays a plain directory on the live
    # overlay (RAM), and everything installed after this point — base
    # system, desktop, seL4 — gets written into RAM instead of disk,
    # filling the overlay and failing with "No space left on device"
    # partway through, far from the real cause.
    if ! mount "$PART_ROOT" "$mnt"; then
        die "Failed to mount root partition ${PART_ROOT} at ${mnt}. Aborting before anything gets written to the live overlay."
    fi
    if ! mountpoint -q "$mnt"; then
        die "${mnt} does not appear to be a real mountpoint after mount — refusing to continue."
    fi
    ok "Mounted / → ${mnt}"

    if [[ -n "$PART_BOOT" ]]; then
        mkdir -p "${mnt}/boot"
        mount "$PART_BOOT" "${mnt}/boot"
        ok "Mounted /boot"
    fi

    if [[ -n "$PART_EFI" ]]; then
        mkdir -p "${mnt}/boot/efi"
        mount "$PART_EFI" "${mnt}/boot/efi"
        ok "Mounted /boot/efi"
    fi

    if [[ -n "$PART_HOME" ]]; then
        mkdir -p "${mnt}/home"
        mount "$PART_HOME" "${mnt}/home"
        ok "Mounted /home"
    fi

    if [[ -n "$PART_SWAP" ]]; then
        swapon "$PART_SWAP"
        ok "Swap enabled."
    fi
}

# ── Main disk setup entrypoint ────────────────────────────────────
setup_disk() {
    detect_efi

    if [[ $USE_EFI -eq 1 ]]; then
        info "EFI system detected."
    else
        info "BIOS/Legacy system detected."
    fi

    # UNATTENDED GUARDS — osm-install supplies these in
    # /tmp/alternix-install.conf. mount_partitions must still run.
    [[ -n "${TARGET_DISK:-}" ]] || select_disk
    if [[ -n "${PART_MODE:-}" ]]; then
        case "$PART_MODE" in
            guided) partition_guided ;;
            manual) partition_manual ;;
            *) die "Unknown PART_MODE: ${PART_MODE}" ;;
        esac
    else
        select_partition_mode
    fi
    mount_partitions /mnt/alternix
}
