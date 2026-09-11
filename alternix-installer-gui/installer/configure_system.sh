#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# configure_system.sh — Alternix System Configuration
# hostname, locale, timezone, user, fstab, sudoers, network
# ═══════════════════════════════════════════════════════════════

ALTERNIX_HOSTNAME=""
ALTERNIX_LOCALE=""
ALTERNIX_TIMEZONE=""
ALTERNIX_USERNAME=""
ALTERNIX_PASSWORD=""

gather_user_config() {
    section "User Account"

    prompt_input ALTERNIX_USERNAME "Username"
    while [[ ! "$ALTERNIX_USERNAME" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; do
        warn "Invalid username. Use lowercase letters, numbers, _ or -."
        prompt_input ALTERNIX_USERNAME "Username"
    done

    local pass1 pass2
    while true; do
        prompt_password pass1 "Password"
        prompt_password pass2 "Confirm password"
        if [[ "$pass1" == "$pass2" ]]; then
            ALTERNIX_PASSWORD="$pass1"
            break
        fi
        warn "Passwords do not match."
    done

    section "System"

    prompt_input ALTERNIX_HOSTNAME "Hostname" "alternix"
    while [[ ! "$ALTERNIX_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; do
        warn "Invalid hostname."
        prompt_input ALTERNIX_HOSTNAME "Hostname" "alternix"
    done

    _select_timezone
    _select_locale
}


_select_timezone() {
    echo ""
    echo -e "  ${W}Timezone${N}"
    echo ""
    echo -e "  ${T} 1${N}  Europe/London"
    echo -e "  ${T} 2${N}  Europe/Paris"
    echo -e "  ${T} 3${N}  Europe/Berlin"
    echo -e "  ${T} 4${N}  America/New_York"
    echo -e "  ${T} 5${N}  America/Los_Angeles"
    echo -e "  ${T} 6${N}  Asia/Tokyo"
    echo -e "  ${T} 7${N}  Australia/Sydney"
    echo -e "  ${T} m${N}  Enter manually"
    echo ""

    local tz_map=("Europe/London" "Europe/Paris" "Europe/Berlin"
                  "America/New_York" "America/Los_Angeles"
                  "Asia/Tokyo" "Australia/Sydney")

    while true; do
        echo -en "  ${W}Select timezone${N}: "
        read -r choice
        if [[ "$choice" == "m" || "$choice" == "M" ]]; then
            prompt_input ALTERNIX_TIMEZONE "Timezone (e.g. Europe/London)" "UTC"
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#tz_map[@]} )); then
            ALTERNIX_TIMEZONE="${tz_map[$((choice-1))]}"
            break
        fi
        warn "Invalid selection."
    done
}

_select_locale() {
    echo ""
    echo -e "  ${W}Locale${N}"
    echo ""
    echo -e "  ${T}1${N}  en_GB.UTF-8"
    echo -e "  ${T}2${N}  en_US.UTF-8"
    echo -e "  ${T}3${N}  de_DE.UTF-8"
    echo -e "  ${T}4${N}  fr_FR.UTF-8"
    echo -e "  ${T}m${N}  Enter manually"
    echo ""

    local loc_map=("en_GB.UTF-8" "en_US.UTF-8" "de_DE.UTF-8" "fr_FR.UTF-8")

    while true; do
        echo -en "  ${W}Select locale${N}: "
        read -r choice
        if [[ "$choice" == "m" || "$choice" == "M" ]]; then
            prompt_input ALTERNIX_LOCALE "Locale" "en_GB.UTF-8"
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#loc_map[@]} )); then
            ALTERNIX_LOCALE="${loc_map[$((choice-1))]}"
            break
        fi
        warn "Invalid selection."
    done
}

configure_system() {
    section "Configuring System"

    _configure_hostname
    _configure_console_font
    _configure_locale
    _configure_timezone
    _configure_user
    _configure_sudoers
    _configure_apt_sources
    _configure_network
    _configure_fstab
    _configure_shell_prompt
    _install_extra_packages

    ok "System configured."
}

_chroot() {
    chroot "$ALTERNIX_MOUNT" /bin/bash -c "$*"
}

# SERVICE ENABLE/DISABLE — DO NOT REMOVE OR SIMPLIFY
# Two compounding bugs fixed here:
#  1) The Devuan/Debian network-manager package's init script is
#     /etc/init.d/network-manager (lowercase, hyphenated) — NOT
#     "NetworkManager" (that's the systemd unit name). rc-update was
#     being told to manage a service name that doesn't exist, so it
#     silently did nothing even under a genuinely-running OpenRC.
#  2) This installer installs BOTH sysvinit-core and openrc, so
#     rc-update (OpenRC-only) may not exist at all on a given
#     machine's actual init. Try both tools; whichever exists wins.
# Defined at top level (not nested in a function) so it's available
# regardless of which function calls it first.
_svc_enable() {
    local svc="$1"
    _chroot "command -v rc-update >/dev/null 2>&1 && rc-update add ${svc} default; \
             command -v update-rc.d >/dev/null 2>&1 && update-rc.d ${svc} defaults; \
             true" &>/dev/null
}
_svc_disable() {
    local svc="$1"
    _chroot "command -v rc-update >/dev/null 2>&1 && rc-update del ${svc} default; \
             command -v update-rc.d >/dev/null 2>&1 && update-rc.d -f ${svc} remove; \
             true" &>/dev/null
}

_configure_hostname() {
    echo "$ALTERNIX_HOSTNAME" > "${ALTERNIX_MOUNT}/etc/hostname"
    cat > "${ALTERNIX_MOUNT}/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   ${ALTERNIX_HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF
    ok "Hostname: ${ALTERNIX_HOSTNAME}"
}

_configure_console_font() {
    # Chosen up front in select_font_size (Stage 1, ui.sh) — carry the
    # same choice into the installed system's console-setup config.
    [[ -z "${ALTERNIX_FONT_FACE:-}" ]] && return 0
    local cs="${ALTERNIX_MOUNT}/etc/default/console-setup"
    [[ -f "$cs" ]] || return 0
    sed -i "s/^FONTFACE=.*/FONTFACE=\"${ALTERNIX_FONT_FACE}\"/" "$cs" 2>/dev/null || true
    sed -i "s/^FONTSIZE=.*/FONTSIZE=\"${ALTERNIX_FONT_SIZE}\"/" "$cs" 2>/dev/null || true
    ok "Console font (${ALTERNIX_FONT_FACE} ${ALTERNIX_FONT_SIZE}) applied to installed system."
}

_configure_locale() {
    sed -i "s/^# *${ALTERNIX_LOCALE}/${ALTERNIX_LOCALE}/" \
        "${ALTERNIX_MOUNT}/etc/locale.gen" 2>/dev/null || \
        echo "${ALTERNIX_LOCALE} UTF-8" >> "${ALTERNIX_MOUNT}/etc/locale.gen"
    _chroot "locale-gen" &>/dev/null
    echo "LANG=${ALTERNIX_LOCALE}" > "${ALTERNIX_MOUNT}/etc/locale.conf"
    ok "Locale: ${ALTERNIX_LOCALE}"
}

_configure_timezone() {
    ln -sf "/usr/share/zoneinfo/${ALTERNIX_TIMEZONE}" \
        "${ALTERNIX_MOUNT}/etc/localtime"
    echo "$ALTERNIX_TIMEZONE" > "${ALTERNIX_MOUNT}/etc/timezone"
    _chroot "dpkg-reconfigure -f noninteractive tzdata" &>/dev/null
    ok "Timezone: ${ALTERNIX_TIMEZONE}"
}

_configure_user() {
    info "Creating user: ${ALTERNIX_USERNAME}"

    # ═══════════════════════════════════════════════════════════
    # USER CREATION FIX — DO NOT REMOVE
    # useradd -G fails ENTIRELY if any listed group is missing
    # (e.g. 'sudo' before the sudo package is installed).
    # Create the user plain first, then add groups one by one.
    # ═══════════════════════════════════════════════════════════
    _chroot "apt-get install -y sudo" 2>&1 | tee -a "$ALTERNIX_LOG" || true

    _chroot "useradd -m -s /bin/bash '${ALTERNIX_USERNAME}'" \
        2>&1 | tee -a "$ALTERNIX_LOG" || true

    # Verify the user now exists — hard stop if not
    if ! chroot "$ALTERNIX_MOUNT" id "${ALTERNIX_USERNAME}" &>/dev/null; then
        err "useradd FAILED — user '${ALTERNIX_USERNAME}' does not exist!"
        return 1
    fi
    ok "User account created."

    # Add groups individually; skip any that don't exist
    for grp in audio video cdrom plugdev netdev sudo dialout bluetooth input render; do
        if chroot "$ALTERNIX_MOUNT" getent group "$grp" &>/dev/null; then
            _chroot "usermod -aG $grp '${ALTERNIX_USERNAME}'" 2>>"$ALTERNIX_LOG" || true
        fi
    done

    # ═══════════════════════════════════════════════════════════
    # PASSWORD FIX — DO NOT REMOVE
    # Hash MUST be generated INSIDE the chroot: the live env has no
    # openssl (minbase) and python3.13 removed the crypt module.
    # The target system always has openssl (via ca-certificates).
    # usermod -p writes the hash to shadow with no escaping issues.
    # ═══════════════════════════════════════════════════════════
    info "Setting password for ${ALTERNIX_USERNAME}..."

    local hash
    hash=$(printf '%s' "${ALTERNIX_PASSWORD}" | \
        chroot "$ALTERNIX_MOUNT" openssl passwd -6 -stdin 2>/dev/null)

    if [[ -z "$hash" ]]; then
        err "openssl in target failed — installing it..."
        _chroot "apt-get install -y openssl" 2>&1 | tee -a "$ALTERNIX_LOG"
        hash=$(printf '%s' "${ALTERNIX_PASSWORD}" | \
            chroot "$ALTERNIX_MOUNT" openssl passwd -6 -stdin 2>/dev/null)
    fi

    if [[ -z "$hash" ]]; then
        err "CANNOT GENERATE PASSWORD HASH — login will fail!"
        err "Fix manually after install: chroot ${ALTERNIX_MOUNT} passwd ${ALTERNIX_USERNAME}"
        return 1
    fi

    chroot "$ALTERNIX_MOUNT" usermod -p "$hash" "${ALTERNIX_USERNAME}" \
        2>&1 | tee -a "$ALTERNIX_LOG"
    chroot "$ALTERNIX_MOUNT" usermod -p "$hash" root \
        2>&1 | tee -a "$ALTERNIX_LOG"

    # Verify the hash actually landed in shadow
    local shadow_entry
    shadow_entry=$(grep "^${ALTERNIX_USERNAME}:" "${ALTERNIX_MOUNT}/etc/shadow" 2>/dev/null | cut -d: -f2)
    if [[ "$shadow_entry" == "$hash" ]]; then
        ok "Password verified in /etc/shadow for ${ALTERNIX_USERNAME}."
    elif [[ -z "$shadow_entry" || "$shadow_entry" == "!" || "$shadow_entry" == "*" ]]; then
        err "PASSWORD NOT SET in shadow — login will fail!"
        return 1
    else
        warn "Shadow entry differs from generated hash — verify login after boot."
    fi

    ok "User ${ALTERNIX_USERNAME} ready."
}

_configure_sudoers() {
    # Ensure sudo package is installed
    _chroot "apt-get install -y sudo" &>/dev/null || true

    # SUDOERS ORDERING — DO NOT REMOVE
    # File named 10-alternix-<user> so it sorts BEFORE any desktop-written
    # rules (e.g. Alternix's alternix-nopasswd). Sudo applies the LAST
    # matching rule, so desktop policies override this baseline instead
    # of being silently overridden by it.
    echo "${ALTERNIX_USERNAME} ALL=(ALL:ALL) ALL" > \
        "${ALTERNIX_MOUNT}/etc/sudoers.d/10-alternix-${ALTERNIX_USERNAME}"
    chmod 440 "${ALTERNIX_MOUNT}/etc/sudoers.d/10-alternix-${ALTERNIX_USERNAME}"

    # Verify sudoers.d is included in main sudoers
    if ! grep -q "includedir.*sudoers.d" "${ALTERNIX_MOUNT}/etc/sudoers" 2>/dev/null; then
        echo "@includedir /etc/sudoers.d" >> "${ALTERNIX_MOUNT}/etc/sudoers"
    fi

    ok "sudo configured for ${ALTERNIX_USERNAME}."
}

_configure_apt_sources() {
    # Write correct Devuan apt sources for the installed system
    cat > "${ALTERNIX_MOUNT}/etc/apt/sources.list" << EOF
deb http://deb.devuan.org/merged excalibur main contrib non-free non-free-firmware
deb http://deb.devuan.org/merged excalibur-security main contrib non-free non-free-firmware
deb http://deb.devuan.org/merged excalibur-updates main contrib non-free non-free-firmware
EOF

    # Install Devuan keyring in target system
    if [[ -f /usr/share/keyrings/devuan-archive-keyring.gpg ]]; then
        mkdir -p "${ALTERNIX_MOUNT}/usr/share/keyrings"
        cp /usr/share/keyrings/devuan-archive-keyring.gpg \
            "${ALTERNIX_MOUNT}/usr/share/keyrings/"
    fi

    ok "APT sources configured."
}

_configure_network() {
    # Copy wpa_supplicant config from live env to installed system
    # so WiFi auto-connects on boot
    local wpa_src="/etc/wpa_supplicant/wpa_supplicant.conf"
    local wpa_dst="${ALTERNIX_MOUNT}/etc/wpa_supplicant/wpa_supplicant.conf"

    mkdir -p "${ALTERNIX_MOUNT}/etc/wpa_supplicant"

    if [[ -f "$wpa_src" ]]; then
        cp "$wpa_src" "$wpa_dst"
        chmod 600 "$wpa_dst"
        ok "WiFi config transferred."
    else
        # Check for per-interface configs
        local found=0
        for f in /etc/wpa_supplicant/wpa_supplicant-*.conf; do
            [[ -f "$f" ]] && cp "$f" "${ALTERNIX_MOUNT}/etc/wpa_supplicant/" && found=1
        done
        [[ $found -eq 1 ]] && ok "WiFi config transferred." || \
            info "No wpa_supplicant config found — WiFi will need manual setup."
    fi

    # ═══════════════════════════════════════════════════════════
    # NETWORKMANAGER OWNS NETWORKING — DO NOT REMOVE
    # /etc/network/interfaces holds ONLY loopback. Any eth/wlan entry
    # here (a) makes the dhcpcd initscript print "failed!" at boot and
    # (b) makes NetworkManager IGNORE those interfaces entirely.
    # WiFi carryover is a proper NM connection profile written below.
    # ═══════════════════════════════════════════════════════════
    cat > "${ALTERNIX_MOUNT}/etc/network/interfaces" << 'EOF'
# Alternix: networking is managed by NetworkManager.
# Do not add interfaces here — NM ignores any listed below.
auto lo
iface lo inet loopback
EOF

    # Convert install-time WiFi credentials into an NM connection profile
    local wpa_conf="/etc/wpa_supplicant/wpa_supplicant.conf"
    if [[ -f "$wpa_conf" ]]; then
        local nm_ssid nm_psk
        nm_ssid=$(grep -m1 -oP '(?<=ssid=").*(?=")' "$wpa_conf" 2>/dev/null)
        # wpa_passphrase writes the 64-hex PSK on the psk= line; NM accepts it
        nm_psk=$(grep -m1 -E '^\s*psk=[0-9a-f]{64}' "$wpa_conf" 2>/dev/null | sed 's/.*psk=//')
        [[ -z "$nm_psk" ]] &&             nm_psk=$(grep -m1 -oP '(?<=psk=").*(?=")' "$wpa_conf" 2>/dev/null)
        if [[ -n "$nm_ssid" ]]; then
            mkdir -p "${ALTERNIX_MOUNT}/etc/NetworkManager/system-connections"
            cat > "${ALTERNIX_MOUNT}/etc/NetworkManager/system-connections/${nm_ssid}.nmconnection" << NMEOF
[connection]
id=${nm_ssid}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${nm_ssid}

[wifi-security]
key-mgmt=wpa-psk
psk=${nm_psk}

[ipv4]
method=auto

[ipv6]
method=auto
NMEOF
            chmod 600 "${ALTERNIX_MOUNT}/etc/NetworkManager/system-connections/${nm_ssid}.nmconnection"
            ok "WiFi '${nm_ssid}' saved as NetworkManager profile (auto-connect)."
        fi
    fi

    # Write dhcpcd config for WiFi auto-connect
    cat > "${ALTERNIX_MOUNT}/etc/dhcpcd.conf" << 'EOF'
# Alternix dhcpcd config
hostname
clientid
persistent
option rapid_commit
option domain_name_servers, domain_name, domain_search, host_name
option classless_static_routes
option interface_mtu
require dhcp_server_identifier
slaac private
EOF

    # Keep the installed system's clock correct (broken RTCs like Miix 520)
    _chroot "apt-get install -y ntpsec-ntpdate" 2>>"$ALTERNIX_LOG" ||         _chroot "apt-get install -y ntpdate" 2>>"$ALTERNIX_LOG" || true
    hwclock --systohc 2>/dev/null || true

    # SERVICE ENABLE/DISABLE — see _svc_enable/_svc_disable near _chroot()
    _svc_disable "dhcpcd"
    _svc_disable "wpasupplicant"
    _svc_enable  "network-manager"

    ok "Network configured."
}

_configure_fstab() {
    local fstab="${ALTERNIX_MOUNT}/etc/fstab"
    echo "# Alternix fstab" > "$fstab"
    echo "" >> "$fstab"

    local root_uuid
    root_uuid=$(blkid -s UUID -o value "$PART_ROOT")
    echo "UUID=${root_uuid}  /  ext4  errors=remount-ro  0  1" >> "$fstab"

    if [[ -n "$PART_BOOT" ]]; then
        local boot_uuid
        boot_uuid=$(blkid -s UUID -o value "$PART_BOOT")
        echo "UUID=${boot_uuid}  /boot  ext4  defaults  0  2" >> "$fstab"
    fi

    if [[ -n "$PART_EFI" ]]; then
        local efi_uuid
        efi_uuid=$(blkid -s UUID -o value "$PART_EFI")
        echo "UUID=${efi_uuid}  /boot/efi  vfat  umask=0077  0  1" >> "$fstab"
    fi

    if [[ -n "${PART_SWAP:-}" ]]; then
        local swap_uuid
        swap_uuid=$(blkid -s UUID -o value "$PART_SWAP")
        echo "UUID=${swap_uuid}  none  swap  sw  0  0" >> "$fstab"
    fi

    if [[ -n "${PART_HOME:-}" ]]; then
        local home_uuid
        home_uuid=$(blkid -s UUID -o value "$PART_HOME")
        echo "UUID=${home_uuid}  /home  ext4  defaults  0  2" >> "$fstab"
    fi

    echo "tmpfs  /tmp  tmpfs  defaults,nosuid,nodev  0  0" >> "$fstab"
    ok "fstab written."
}

_configure_shell_prompt() {
    # Set a clean prompt: dan@alternix: (no ~$)
    cat > "${ALTERNIX_MOUNT}/etc/profile.d/alternix-prompt.sh" << 'EOF'
# Alternix shell prompt
export PS1="\u@\h: "
export HISTSIZE=10000
export HISTFILESIZE=10000
EOF
    ok "Shell prompt configured."
}

_install_extra_packages() {
    section "Installing Extra Packages"

    info "Installing nala, fastfetch, wifi tools..."

    # Bind mounts for chroot network access
    # (bind of /dev is NOT recursive — /dev/pts needs its own bind,
    #  otherwise apt logs "Can not write log (Is /dev/pts mounted?)")
    mount --bind /proc    "${ALTERNIX_MOUNT}/proc"    2>/dev/null || true
    mount --bind /sys     "${ALTERNIX_MOUNT}/sys"     2>/dev/null || true
    mount --bind /dev     "${ALTERNIX_MOUNT}/dev"     2>/dev/null || true
    mount --bind /dev/pts "${ALTERNIX_MOUNT}/dev/pts" 2>/dev/null || true
    cp /etc/resolv.conf "${ALTERNIX_MOUNT}/etc/resolv.conf" 2>/dev/null || true

    _chroot "apt-get update -qq" 2>&1 | tee -a "$ALTERNIX_LOG" || true

    # Install nala (better apt frontend)
    _chroot "apt-get install -y nala" 2>&1 | tee -a "$ALTERNIX_LOG" || \
        warn "nala not available — using apt."

    # Install fastfetch
    _chroot "apt-get install -y fastfetch" 2>&1 | tee -a "$ALTERNIX_LOG" || \
        warn "fastfetch install reported an error — check log."

    # Install wifi TUI tools (nmtui ships inside network-manager)
    _chroot "apt-get install -y --no-install-recommends \
        network-manager \
        wpasupplicant dhcpcd5 wireless-tools iw" \
        2>&1 | tee -a "$ALTERNIX_LOG" || true

    # Enable NetworkManager for easy wifi management
    _svc_enable "network-manager"

    # Unmount
    umount "${ALTERNIX_MOUNT}/dev/pts" 2>/dev/null || true
    umount "${ALTERNIX_MOUNT}/dev"     2>/dev/null || true
    umount "${ALTERNIX_MOUNT}/sys"     2>/dev/null || true
    umount "${ALTERNIX_MOUNT}/proc"    2>/dev/null || true

    # Repair any packages left half-configured, then restore invoke-rc.d
    _chroot "dpkg --configure -a" 2>&1 | tee -a "$ALTERNIX_LOG" || true

    # CHROOT SERVICE FIX cleanup — restore the real invoke-rc.d
    rm -f "${ALTERNIX_MOUNT}/usr/sbin/invoke-rc.d"
    chroot "$ALTERNIX_MOUNT" dpkg-divert --local --rename --quiet \
        --remove /usr/sbin/invoke-rc.d 2>/dev/null || true
    rm -f "${ALTERNIX_MOUNT}/usr/sbin/policy-rc.d"

    ok "Extra packages installed."

    # Write a wifi TUI script to the installed system
    _write_wifi_tui
}

_write_wifi_tui() {
    cat > "${ALTERNIX_MOUNT}/usr/local/bin/wifi" << 'WIFIEOF'
#!/bin/bash
# Alternix WiFi TUI — type 'wifi' to manage connections
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'
C='\033[0;36m'; W='\033[1;37m'; D='\033[0;37m'; N='\033[0m'

# Use nmtui if available (best option)
if command -v nmtui &>/dev/null; then
    nmtui
    exit 0
fi

# Fallback: manual wpa_supplicant TUI
clear
echo -e "${C}Alternix WiFi${N}"
echo ""

IFACE=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | head -1)
if [[ -z "$IFACE" ]]; then
    echo -e "${R}No WiFi interface found.${N}"
    exit 1
fi

echo -e "  Interface: ${W}${IFACE}${N}"
echo ""
echo -e "  Scanning..."
ip link set "$IFACE" up 2>/dev/null
sleep 1

mapfile -t SSIDS < <(iw dev "$IFACE" scan 2>/dev/null | \
    grep -oP '(?<=SSID: ).+' | grep -v '^$' | sort -u)

if [[ ${#SSIDS[@]} -eq 0 ]]; then
    echo -e "${Y}No networks found. Try again?${N}"
    exit 1
fi

echo -e "  ${W}Available networks:${N}"
echo ""
for i in "${!SSIDS[@]}"; do
    printf "  ${C}%2d${N}  %s\n" $((i+1)) "${SSIDS[$i]}"
done
echo ""

while true; do
    echo -en "  ${W}Select network (or q to quit)${N}: "
    read -r choice
    [[ "$choice" == "q" ]] && exit 0
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#SSIDS[@]} )); then
        SSID="${SSIDS[$((choice-1))]}"
        break
    fi
done

echo -en "  ${W}Password (blank if open)${N}: "
read -rs PASS; echo ""

WPA_CONF=$(mktemp /tmp/wpa.XXXXXX.conf)
if [[ -z "$PASS" ]]; then
    cat > "$WPA_CONF" << EOF
network={
    ssid="${SSID}"
    key_mgmt=NONE
}
EOF
else
    wpa_passphrase "$SSID" "$PASS" > "$WPA_CONF" 2>/dev/null
fi

pkill -f "wpa_supplicant.*${IFACE}" 2>/dev/null; sleep 0.5
wpa_supplicant -B -i "$IFACE" -c "$WPA_CONF" &>/dev/null
sleep 3
dhcpcd "$IFACE" &>/dev/null || dhclient "$IFACE" &>/dev/null || true
rm -f "$WPA_CONF"

if ping -c1 -W3 8.8.8.8 &>/dev/null; then
    echo -e "  ${G}Connected to '${SSID}'${N}"
else
    echo -e "  ${R}Could not connect to '${SSID}'${N}"
fi
WIFIEOF
    chmod +x "${ALTERNIX_MOUNT}/usr/local/bin/wifi"
    ok "wifi command installed — type 'wifi' to connect."
}
