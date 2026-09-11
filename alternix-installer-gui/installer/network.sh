#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# network.sh — Alternix Installer Network Setup
# Handles ethernet (auto DHCP) and WiFi (TUI scan + connect)
# ═══════════════════════════════════════════════════════════════

# ── Load network drivers ──────────────────────────────────────────
net_load_drivers() {
    # Common wired NIC drivers
    for mod in e1000e r8169 r8168 igb ixgbe tg3 forcedeth atl1c; do
        modprobe "$mod" 2>/dev/null || true
    done
    # Common WiFi drivers (Intel, Atheros, Broadcom, Realtek)
    for mod in iwlwifi iwlmvm ath9k ath9k_htc ath10k_pci brcmsmac brcmfmac \
               rtl8192ce rtw88_pcie rtw88_8822be iwlegacy; do
        modprobe "$mod" 2>/dev/null || true
    done
    sleep 2

    # If a WiFi PCI device exists but no wlan interface appeared,
    # the driver may have probed before firmware — reload it once.
    if ! ls /sys/class/net/*/wireless &>/dev/null 2>&1 && \
       ! ls /sys/class/net/*/phy80211 &>/dev/null 2>&1; then
        if lspci 2>/dev/null | grep -qi "network\|wireless"; then
            modprobe -r iwlwifi 2>/dev/null || true
            sleep 1
            modprobe iwlwifi 2>/dev/null || true
            sleep 3
        fi
    fi
}

# ── Detect all network interfaces ────────────────────────────────
net_list_interfaces() {
    local ifaces=()
    while IFS= read -r iface; do
        [[ "$iface" == "lo" ]] && continue
        ifaces+=("$iface")
    done < <(ls /sys/class/net/)
    printf '%s\n' "${ifaces[@]}"
}

net_is_wireless() {
    local iface="$1"
    [[ -d "/sys/class/net/${iface}/wireless" ]] || \
    [[ -d "/sys/class/net/${iface}/phy80211" ]]
}

net_is_connected() {
    ping -c1 -W3 8.8.8.8 &>/dev/null
}

# ── Clock sync — DO NOT REMOVE ────────────────────────────────────
# A wrong hardware clock breaks every TLS connection (git clones fail
# with "certificate error") and apt ("Release file not valid yet").
net_sync_clock() {
    local http_date
    http_date=$(wget -qS --spider http://deb.devuan.org 2>&1 |         grep -i '^  *Date:' | sed -n '1p' | sed 's/^ *Date: *//')
    if [[ -n "$http_date" ]]; then
        if date -u -s "$http_date" &>/dev/null; then
            ok "Clock synced: $(date)"
            hwclock --systohc 2>/dev/null || true
        else
            warn "Could not parse network time: ${http_date}"
        fi
    else
        warn "Could not fetch network time — TLS may fail if clock is wrong."
    fi
}


# ── DHCP via whatever client is available ────────────────────────
net_dhcp() {
    local iface="$1"
    if command -v dhcpcd &>/dev/null; then
        dhcpcd -t 15 -w "$iface" &>/dev/null && return 0
    fi
    if command -v dhclient &>/dev/null; then
        dhclient -v "$iface" &>/dev/null && return 0
    fi
    if command -v udhcpc &>/dev/null; then
        udhcpc -i "$iface" -t 10 -T 3 -n &>/dev/null && return 0
    fi
    warn "No DHCP client found (tried dhcpcd, dhclient, udhcpc)."
    return 1
}

# ── Ethernet: bring up and DHCP ───────────────────────────────────
net_setup_ethernet() {
    local iface="$1"
    info "Bringing up ${iface}..."
    ip link set "$iface" up 2>/dev/null
    sleep 1
    spin_start "Requesting DHCP lease on ${iface}..."
    net_dhcp "$iface"
    spin_stop
    if net_is_connected; then
        ok "Connected via ${iface}."
        return 0
    else
        warn "DHCP completed but no internet reachable on ${iface}."
        return 1
    fi
}

# ── WiFi: scan and TUI selection ─────────────────────────────────
net_wifi_scan() {
    local iface="$1"
    ip link set "$iface" up 2>/dev/null
    sleep 2

    if command -v iw &>/dev/null; then
        iw dev "$iface" scan 2>/dev/null | grep -E "^\s+SSID:" | \
            sed 's/.*SSID: //' | grep -v '^$' | sort -u
    elif command -v iwlist &>/dev/null; then
        iwlist "$iface" scan 2>/dev/null | grep -E "ESSID:" | \
            sed 's/.*ESSID:"\(.*\)"/\1/' | grep -v '^$' | sort -u
    fi
}

net_wifi_tui() {
    local iface="$1"

    section "WiFi Setup"
    info "Scanning for networks on ${iface}..."
    echo ""

    spin_start "Scanning..."
    local raw_networks
    raw_networks=$(net_wifi_scan "$iface")
    spin_stop

    if [[ -z "$raw_networks" ]]; then
        warn "No networks found. Make sure WiFi is not blocked (check rfkill)."
        echo ""
        if confirm "Try scanning again?"; then
            net_wifi_tui "$iface"
            return $?
        fi
        return 1
    fi

    local networks=()
    while IFS= read -r ssid; do
        [[ -n "$ssid" ]] && networks+=("$ssid")
    done <<< "$raw_networks"

    echo -e "  ${W}Available networks:${N}"
    echo ""
    local i
    for (( i=0; i<${#networks[@]}; i++ )); do
        printf "  ${T}%2d${N}  %s\n" $(( i+1 )) "${networks[$i]}"
    done
    echo ""
    echo -e "  ${D}Enter number to connect, or 'm' to enter SSID manually.${N}"
    echo ""

    local choice ssid
    while true; do
        echo -en "  ${W}Select network${N}: "
        read -r choice
        if [[ "$choice" == "m" || "$choice" == "M" ]]; then
            prompt_input ssid "Enter SSID"
            break
        elif [[ "$choice" =~ ^[0-9]+$ ]] && \
             (( choice >= 1 && choice <= ${#networks[@]} )); then
            ssid="${networks[$((choice-1))]}"
            break
        else
            warn "Invalid selection."
        fi
    done

    echo -en "  ${W}Password${N} ${D}(leave blank if open)${N}: "
    read -rs wifi_pass
    echo ""

    info "Connecting to '${ssid}'..."
    spin_start "Authenticating..."

    local connect_ok=1
    if command -v wpa_supplicant &>/dev/null; then
        local wpa_conf
        wpa_conf=$(mktemp /tmp/wpa.XXXXXX.conf)
        if [[ -z "$wifi_pass" ]]; then
            cat > "$wpa_conf" << EOF
network={
    ssid="${ssid}"
    key_mgmt=NONE
}
EOF
        else
            wpa_passphrase "$ssid" "$wifi_pass" > "$wpa_conf" 2>/dev/null
        fi

        pkill -f "wpa_supplicant.*${iface}" 2>/dev/null
        sleep 0.5

        wpa_supplicant -B -i "$iface" -c "$wpa_conf" &>/dev/null
        sleep 4

        net_dhcp "$iface"
        if net_is_connected; then
            connect_ok=0
            # POWERSAVE OFF — DO NOT REMOVE
            # WiFi powersave causes mid-download stalls (debootstrap
            # hanging on "Retrieving..."). Disable for the install.
            iw dev "$iface" set power_save off 2>/dev/null || true
            # WIFI CARRYOVER — DO NOT REMOVE
            # Persist credentials so configure_system.sh can copy them
            # to the installed system for auto-reconnect on boot.
            mkdir -p /etc/wpa_supplicant
            {
                echo "ctrl_interface=/run/wpa_supplicant"
                echo "update_config=1"
                cat "$wpa_conf"
            } > /etc/wpa_supplicant/wpa_supplicant.conf
            chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
        fi
        rm -f "$wpa_conf"
    else
        spin_stop
        die "wpa_supplicant not found. Cannot connect to WiFi."
    fi

    spin_stop

    if [[ $connect_ok -eq 0 ]]; then
        ok "Connected to '${ssid}'."
        return 0
    else
        err "Failed to connect to '${ssid}'."
        echo ""
        if confirm "Try a different network?"; then
            net_wifi_tui "$iface"
            return $?
        fi
        return 1
    fi
}

# ── Main network setup entrypoint ────────────────────────────────
setup_network() {
    section "Network"

    if net_is_connected; then
        ok "Already connected to the internet."
        return 0
    fi

    info "Loading network drivers..."
    net_load_drivers

    if net_is_connected; then
        ok "Connected after loading drivers."
        return 0
    fi

    # Detect available interfaces
    local all_ifaces=() eth_ifaces=() wifi_ifaces=()
    while IFS= read -r iface; do all_ifaces+=("$iface"); done < <(net_list_interfaces)

    if [[ ${#all_ifaces[@]} -eq 0 ]]; then
        die "No network interfaces found."
    fi

    for iface in "${all_ifaces[@]}"; do
        if net_is_wireless "$iface"; then
            wifi_ifaces+=("$iface")
        else
            eth_ifaces+=("$iface")
        fi
    done

    # Diagnose: WiFi hardware present but no interface = missing firmware
    if [[ ${#wifi_ifaces[@]} -eq 0 ]] && \
       lspci 2>/dev/null | grep -qi "network\|wireless"; then
        warn "WiFi hardware detected but no interface appeared."
        warn "Likely missing firmware in this live image:"
        dmesg 2>/dev/null | grep -i "firmware" | grep -iv "loaded\|loading" | \
            sed -n '1,4p' | while IFS= read -r l; do warn "  $l"; done
        info "Rebuild the ISO with firmware packages, or use ethernet/USB tethering."
        echo ""
    fi

    # Ask user — no auto timeout
    echo -e "  ${W}How would you like to connect?${N}"
    echo ""
    [[ ${#eth_ifaces[@]} -gt 0 ]] && \
        echo -e "  ${T}1${N}  Ethernet   ${D}(${eth_ifaces[*]})${N}"
    [[ ${#wifi_ifaces[@]} -gt 0 ]] && \
        echo -e "  ${T}2${N}  WiFi       ${D}(${wifi_ifaces[*]})${N}"
    echo -e "  ${T}3${N}  Manual static IP"
    echo -e "  ${T}4${N}  Skip network"
    echo ""

    while true; do
        echo -en "  ${W}Select${N}: "
        read -r net_choice
        case "$net_choice" in
            1)
                [[ ${#eth_ifaces[@]} -eq 0 ]] && { warn "No ethernet found."; continue; }
                for iface in "${eth_ifaces[@]}"; do
                    net_setup_ethernet "$iface" && return 0
                done
                err "Ethernet failed."
                confirm "Try WiFi instead?" && net_choice=2 || die "Network failed."
                ;;&
            2)
                [[ ${#wifi_ifaces[@]} -eq 0 ]] && { warn "No WiFi found."; continue; }
                if command -v rfkill &>/dev/null; then
                    local blocked
                    blocked=$(rfkill list 2>/dev/null | grep -ic "soft blocked: yes")
                    blocked=${blocked:-0}
                    if [[ $blocked -gt 0 ]]; then
                        warn "WiFi is soft-blocked."
                        confirm "Unblock?" && { rfkill unblock wifi; sleep 1; }
                    fi
                fi
                local wifi_iface="${wifi_ifaces[0]}"
                if [[ ${#wifi_ifaces[@]} -gt 1 ]]; then
                    local i
                    for (( i=0; i<${#wifi_ifaces[@]}; i++ )); do
                        printf "  ${T}%d${N}  %s\n" $(( i+1 )) "${wifi_ifaces[$i]}"
                    done
                    echo ""
                    while true; do
                        echo -en "  ${W}Select interface${N}: "
                        read -r choice
                        [[ "$choice" =~ ^[0-9]+$ ]] && \
                        (( choice >= 1 && choice <= ${#wifi_ifaces[@]} )) && \
                            { wifi_iface="${wifi_ifaces[$((choice-1))]}"; break; }
                        warn "Invalid."
                    done
                fi
                net_wifi_tui "$wifi_iface" && return 0
                die "WiFi failed."
                ;;
            3) net_manual_setup; return $? ;;
            4) warn "Skipping network — some steps may fail."; return 0 ;;
            *) warn "Enter 1-4." ;;
        esac
    done
}


# ── Manual static IP fallback ─────────────────────────────────────
net_manual_setup() {
    section "Manual Network Configuration"

    local ifaces=()
    while IFS= read -r iface; do
        ifaces+=("$iface")
    done < <(net_list_interfaces)

    echo -e "  ${W}Available interfaces:${N}"
    local i
    for (( i=0; i<${#ifaces[@]}; i++ )); do
        printf "  ${T}%d${N}  %s\n" $(( i+1 )) "${ifaces[$i]}"
    done
    echo ""

    local iface
    while true; do
        echo -en "  ${W}Select interface${N}: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           (( choice >= 1 && choice <= ${#ifaces[@]} )); then
            iface="${ifaces[$((choice-1))]}"
            break
        fi
        warn "Invalid selection."
    done

    local ip gw dns
    prompt_input ip  "IP address (e.g. 192.168.1.50/24)"
    prompt_input gw  "Gateway    (e.g. 192.168.1.1)"
    prompt_input dns "DNS server (e.g. 1.1.1.1)" "1.1.1.1"

    ip link set "$iface" up
    ip addr flush dev "$iface"
    ip addr add "$ip" dev "$iface"
    ip route add default via "$gw"
    echo "nameserver $dns" > /etc/resolv.conf

    sleep 1
    if net_is_connected; then
        ok "Manual network configured on ${iface}."
        return 0
    else
        err "Still no internet. Check your settings."
        return 1
    fi
}
