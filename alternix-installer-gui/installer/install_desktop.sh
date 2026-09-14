#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# install_desktop.sh — Alternix Desktop Environment Installation
# ═══════════════════════════════════════════════════════════════

ALTERNIX_DESKTOP=""

# ── Desktop selection TUI ─────────────────────────────────────────
select_desktop() {
    # Already chosen by osm-install via /tmp/alternix-install.conf.
    if [[ -n "${ALTERNIX_DESKTOP:-}" ]]; then
        return 0
    fi

    section "Desktop Environment"

    echo -e "  ${W}Choose a desktop environment:${N}"
    echo ""
    echo -e "  ${T} 1${N}  ${W}Alternix${N}          ${D}Alternix native DE (from GitHub)${N}"
    echo -e "  ${T} 2${N}  ${W}XFCE${N}              ${D}Lightweight, traditional${N}"
    echo -e "  ${T} 3${N}  ${W}LXQt${N}              ${D}Lightweight Qt-based${N}"
    echo -e "  ${T} 4${N}  ${W}LXDE${N}              ${D}Very lightweight GTK2${N}"
    echo -e "  ${T} 5${N}  ${W}MATE${N}              ${D}Classic GNOME2 fork${N}"
    echo -e "  ${T} 6${N}  ${W}Openbox${N}           ${D}Minimal window manager only${N}"
    echo -e "  ${T} 7${N}  ${W}CLI only${N}          ${D}No desktop — terminal only${N}"
    echo ""

    while true; do
        echo -en "  ${W}Select${N} ${D}[1]${N}: "
        read -r choice
        case "$choice" in
            ""|1) ALTERNIX_DESKTOP="alternix" ;;
            2) ALTERNIX_DESKTOP="xfce" ;;
            3) ALTERNIX_DESKTOP="lxqt" ;;
            4) ALTERNIX_DESKTOP="lxde" ;;
            5) ALTERNIX_DESKTOP="mate" ;;
            6) ALTERNIX_DESKTOP="openbox" ;;
            7) ALTERNIX_DESKTOP="cli" ;;
            *) warn "Enter 1-7."; continue ;;
        esac
        break
    done

    echo ""
    case "$ALTERNIX_DESKTOP" in
        alternix) info "Alternix will be cloned from GitHub and built." ;;
        cli)      info "CLI only — no display server or desktop will be installed." ;;
        *)        info "$(echo $ALTERNIX_DESKTOP | tr '[:lower:]' '[:upper:]') will be installed from Devuan repos." ;;
    esac
    echo ""
    confirm "Install ${ALTERNIX_DESKTOP}?" || select_desktop
}

# ── Main desktop install entrypoint ──────────────────────────────
install_desktop() {
    # SAFETY NET — DO NOT REMOVE
    # If the desktop was somehow never selected, ask now rather than
    # silently skipping (a user must NEVER end up without a GUI).
    if [[ -z "${ALTERNIX_DESKTOP:-}" ]]; then
        warn "No desktop was selected earlier — choose one now."
        select_desktop
    fi

    echo ""
    echo -e "  ${T}═══════════════════════════════════════════${N}"
    echo -e "  ${W}  INSTALLING DESKTOP: ${ALTERNIX_DESKTOP}${N}"
    echo -e "  ${T}═══════════════════════════════════════════${N}"
    echo ""

    # CHROOT PREP — DO NOT REMOVE
    # Every desktop path needs /proc /sys /dev /dev/pts mounted
    # (bind of /dev is NOT recursive — pts must be bound separately)
    # and DNS via resolv.conf, for apt and git inside the chroot.
    for fs in proc sys dev dev/pts; do
        mkdir -p "${ALTERNIX_MOUNT}/${fs}"
        mount --bind "/${fs}" "${ALTERNIX_MOUNT}/${fs}" 2>/dev/null || true
    done
    cp /etc/resolv.conf "${ALTERNIX_MOUNT}/etc/resolv.conf" 2>/dev/null || true

    # ═══════════════════════════════════════════════════════════
    # CHROOT SERVICE FIX (desktop stage) — DO NOT REMOVE
    # Package post-install scripts (invoke-rc.d -> rc-service) still
    # fail inside the chroot at this stage — rc-service only exists
    # on a REAL boot. Any apt/nala install here (including inside
    # the Alternix installer, which runs under 'set -e') would abort
    # the entire desktop-install run on the very first package that
    # ships an init script. Divert invoke-rc.d for this whole stage;
    # restore it once the chosen desktop has finished installing.
    # ═══════════════════════════════════════════════════════════
    chroot "$ALTERNIX_MOUNT" dpkg-divert --local --rename --quiet \
        --add /usr/sbin/invoke-rc.d 2>/dev/null || true
    cat > "${ALTERNIX_MOUNT}/usr/sbin/invoke-rc.d" << 'RCEOF'
#!/bin/sh
exit 0
RCEOF
    chmod +x "${ALTERNIX_MOUNT}/usr/sbin/invoke-rc.d"
    cat > "${ALTERNIX_MOUNT}/usr/sbin/policy-rc.d" << 'PRCEOF'
#!/bin/sh
exit 101
PRCEOF
    chmod +x "${ALTERNIX_MOUNT}/usr/sbin/policy-rc.d"

    case "$ALTERNIX_DESKTOP" in
        alternix) _install_alternix ;;
        xfce)     _install_xfce ;;
        lxqt)     _install_lxqt ;;
        lxde)     _install_lxde ;;
        mate)     _install_mate ;;
        openbox)  _install_openbox ;;
        cli)      _install_cli ;;
        *)        err "Unknown desktop value: '${ALTERNIX_DESKTOP}'"
                  warn "Re-running desktop selection..."
                  select_desktop
                  install_desktop ;;
    esac

    # Repair anything left half-configured, then restore invoke-rc.d
    _chroot "dpkg --configure -a" 2>&1 | tee -a "$ALTERNIX_LOG" || true
    rm -f "${ALTERNIX_MOUNT}/usr/sbin/invoke-rc.d"
    chroot "$ALTERNIX_MOUNT" dpkg-divert --local --rename --quiet \
        --remove /usr/sbin/invoke-rc.d 2>/dev/null || true
    rm -f "${ALTERNIX_MOUNT}/usr/sbin/policy-rc.d"

    # Unmount chroot filesystems
    for fs in dev/pts dev sys proc; do
        umount "${ALTERNIX_MOUNT}/${fs}" 2>/dev/null || true
    done
}

# ── Shared X11 base ───────────────────────────────────────────────
_install_xbase() {
    info "Installing X11 base..."
    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends \
        xorg xserver-xorg xinit x11-utils x11-xserver-utils \
        xterm fonts-noto fonts-liberation \
        dbus-x11 at-spi2-core \
        2>&1" | tee -a "$ALTERNIX_LOG" | while IFS= read -r l; do
            [[ "$l" == *"Setting up"* ]] && echo -e "  ${D}${l}${N}"
        done
    ok "X11 base installed."
}

_chroot() {
    chroot "$ALTERNIX_MOUNT" /bin/bash -c "$*"
}

# ── Alternix ──────────────────────────────────────────────────────
_install_alternix() {
    section "Installing Alternix Desktop"

    step 1 3 "Installing git in the target system..."
    # GIT IN TARGET — DO NOT REMOVE
    # git exists in the live env (seL4 uses it) but the Alternix clone
    # runs INSIDE the chroot, so the target needs its own git.
    _chroot "apt-get update -qq" 2>&1 | tee -a "$ALTERNIX_LOG" || true
    _chroot "apt-get install -y git ca-certificates" 2>&1 | tee -a "$ALTERNIX_LOG"
    # (test the binary directly — 'command -v' is a shell builtin and
    #  cannot be exec'd by chroot)
    if [[ ! -x "${ALTERNIX_MOUNT}/usr/bin/git" && ! -x "${ALTERNIX_MOUNT}/bin/git" ]]; then
        err "git could not be installed in the target — cannot clone Alternix."
        err "apt output above shows why (check sources/network)."
        return 1
    fi
    ok "git present in target."

    # ═══════════════════════════════════════════════════════════
    # USE THE COPY ALREADY IN THE IMAGE IF THERE IS ONE
    # Hook 0080 clones AlternixDE at ISO build time and leaves it at
    # /usr/share/alternix/AlternixDE. Because the squashfs is what gets
    # copied onto the target, that directory is already on the target
    # disk. Cloning again from GitHub duplicates a download that has
    # already happened and makes the install fail if the network is
    # down at this point. Copy locally, and only clone as a fallback
    # for ISOs built before this existed.
    # ═══════════════════════════════════════════════════════════
    local _stashed="/usr/share/alternix/AlternixDE"
    local _cloned=0

    if chroot "$ALTERNIX_MOUNT" test -d "${_stashed}/.git" 2>/dev/null || \
       chroot "$ALTERNIX_MOUNT" test -f "${_stashed}/install-alternix_devuan.sh" 2>/dev/null; then
        step 2 3 "Using AlternixDE from the system image..."
        if chroot "$ALTERNIX_MOUNT" cp -a "$_stashed" \
            "/home/${ALTERNIX_USERNAME}/Alternix" 2>&1 | tee -a "$ALTERNIX_LOG"; then
            chroot "$ALTERNIX_MOUNT" chown -R \
                "${ALTERNIX_USERNAME}:${ALTERNIX_USERNAME}" \
                "/home/${ALTERNIX_USERNAME}/Alternix" 2>/dev/null || true
            ok "Alternix copied from image (no download needed)."
            _cloned=1
        else
            warn "Copy from image failed — falling back to cloning."
        fi
    fi

    if [[ $_cloned -eq 0 ]]; then
    step 2 3 "Cloning Alternix repository..."
    if chroot "$ALTERNIX_MOUNT" git clone --depth=1 \
        https://github.com/DansDesigns/AlternixDE.git \
        "/home/${ALTERNIX_USERNAME}/Alternix" \
        2>&1 | tee -a "$ALTERNIX_LOG"; then
        ok "Alternix cloned."
    else
        err "Failed to clone Alternix — check network."
        return 1
    fi
    fi   # end: copy-from-image else clone
    _chroot "chown -R ${ALTERNIX_USERNAME}:${ALTERNIX_USERNAME} /home/${ALTERNIX_USERNAME}/Alternix"

    # osm-sudo: make the GUI pattern-auth wrapper available system-wide,
    # and export SUDO_ASKPASS so apps using 'sudo -A' get the GUI prompt.
    if [[ -f "/home/${ALTERNIX_USERNAME}/Alternix/osm-sudo" ]] || \
       [[ -f "${ALTERNIX_MOUNT}/home/${ALTERNIX_USERNAME}/Alternix/osm-sudo" ]]; then
        local osm_src="${ALTERNIX_MOUNT}/home/${ALTERNIX_USERNAME}/Alternix/osm-sudo"
        [[ -f "$osm_src" ]] || osm_src="/home/${ALTERNIX_USERNAME}/Alternix/osm-sudo"
        tr -d '\r' < "$osm_src" > "${ALTERNIX_MOUNT}/usr/local/bin/osm-sudo"
        chmod +x "${ALTERNIX_MOUNT}/usr/local/bin/osm-sudo"
        cat > "${ALTERNIX_MOUNT}/etc/profile.d/osm-sudo.sh" << 'OSMEOF'
# Alternix GUI sudo: apps calling "sudo -A" get the osm-lock pattern prompt
export SUDO_ASKPASS=/usr/local/bin/osm-sudo
OSMEOF
        ok "osm-sudo installed to /usr/local/bin (CRLF stripped)."
    fi

    step 3 3 "Running the Alternix installer..."
    echo ""

    # ═══════════════════════════════════════════════════════════
    # DEBCONF PRESEED — DO NOT REMOVE
    # keyboard-configuration / console-setup pop broken TUIs inside
    # the chroot. Pre-answer them from the locale chosen in the
    # Alternix installer, and export DEBIAN_FRONTEND=noninteractive
    # for the run (env only — the Alternix script is NOT modified).
    # ═══════════════════════════════════════════════════════════
    local kb_layout
    case "${ALTERNIX_LOCALE:-en_GB.UTF-8}" in
        en_GB*) kb_layout="gb" ;;
        en_US*) kb_layout="us" ;;
        de_DE*) kb_layout="de" ;;
        fr_FR*) kb_layout="fr" ;;
        *)      kb_layout="us" ;;
    esac

    chroot "$ALTERNIX_MOUNT" debconf-set-selections << DEBEOF
keyboard-configuration  keyboard-configuration/xkb-keymap       select  ${kb_layout}
keyboard-configuration  keyboard-configuration/layoutcode       string  ${kb_layout}
keyboard-configuration  keyboard-configuration/variant          select  ${kb_layout}
keyboard-configuration  keyboard-configuration/model            select  pc105
console-setup           console-setup/charmap47                 select  UTF-8
console-setup           console-setup/codeset47                 select  Guess optimal character set
DEBEOF

    # Write the keyboard config file directly too
    cat > "${ALTERNIX_MOUNT}/etc/default/keyboard" << KBEOF
XKBMODEL="pc105"
XKBLAYOUT="${kb_layout}"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
KBEOF

    info "Keyboard preseeded: ${kb_layout} (from ${ALTERNIX_LOCALE})"
    info "The Alternix installer will now run. Answer its prompts when asked."
    echo ""

    # ═══════════════════════════════════════════════════════════
    # STDIN FOR THE UNATTENDED RUN — ORDER MATTERS, DO NOT SIMPLIFY
    # Under the graphical installer stdin is a closed pipe. The
    # AlternixDE script has `set -e` on line 2, and a bare `read`
    # returns non-zero at EOF, so an unfed prompt kills it instantly
    # with exit 1 and no output at all.
    #
    # It reads stdin at four points, and they want different answers.
    # Feeding "2" to everything (which is what an earlier version did)
    # force-skipped telephony and broke auto-cpufreq:
    #
    #   line   34  username                 -> the real username
    #   line  176  telephony [1/2]          -> the user's choice
    #   line 1181  ./auto-cpufreq-installer -> "i" for install
    #
    # On that third one, the upstream installer prompts
    #   "Select a key [I]nstall/[R]emove or press ctrl+c to quit:"
    # and its dispatch is:
    #   case $answer in I|i) ...;; R|r) ...;;
    #     *) echo "Unknown key, aborting ..."; exit 1 ;;
    # so any other answer makes it exit 1, which `set -e` in the
    # AlternixDE script turns into the whole desktop build dying.
    # Feeding "i" here is a workaround. The proper fix is upstream in
    # install-alternix_devuan.sh: that installer accepts --install as
    # an argument and then never reads stdin at all.
    #   line 1211  restart or continue      -> ALWAYS "2"
    #
    # That last one must never be answered "1". Option 1 runs
    # `sudo reboot` immediately, which would restart the machine in the
    # middle of the install, before the bootloader has been written.
    #
    # `yes 2` on the end keeps the stream alive so there is never a
    # second EOF, and harmlessly re-answers the final prompt if
    # auto-cpufreq consumed fewer lines than expected.
    # ═══════════════════════════════════════════════════════════
    local _tele="${ALTERNIX_TELEPHONY:-2}"
    local alt_exit=0
    local _alt_de_log="/tmp/alternix-de-target.log"
    : > "$_alt_de_log"

    # SUDO HOSTNAME RESOLUTION
    # gethostname() inside a chroot returns the LIVE system's hostname,
    # not the one configure_system wrote into the target. The target's
    # /etc/hosts has no entry for it, so every one of the 134 sudo
    # calls in the AlternixDE script prints
    #   sudo: unable to resolve host <name>: Name or service not known
    # and waits on the lookup first. Adding the live hostname to the
    # target's hosts file for the duration silences it and removes the
    # per-call delay. The line is taken out again afterwards so the
    # installed system is not left with a stray entry.
    local _live_host _hosts_patched=0
    _live_host=$(hostname 2>/dev/null || echo "")
    if [[ -n "$_live_host" ]] && \
       ! grep -qw "$_live_host" "${ALTERNIX_MOUNT}/etc/hosts" 2>/dev/null; then
        echo "127.0.1.1 ${_live_host}" >> "${ALTERNIX_MOUNT}/etc/hosts"
        _hosts_patched=1
        info "Added '${_live_host}' to the target hosts file for the build."
    fi

    # PRE-FLIGHT — the script exiting 1 with no output means it never
    # reached its own banner, so the fault is in getting to it rather
    # than inside it. Record exactly what is present before running.
    {
        echo "=== pre-flight for install-alternix_devuan.sh ==="
        echo "-- target dir listing --"
        chroot "$ALTERNIX_MOUNT" /bin/bash -c \
            "ls -la /home/${ALTERNIX_USERNAME}/Alternix 2>&1 | head -30"
        echo "-- installer script --"
        chroot "$ALTERNIX_MOUNT" /bin/bash -c \
            "ls -l /home/${ALTERNIX_USERNAME}/Alternix/install-alternix_devuan.sh 2>&1"
        echo "-- first line (shebang; a stray CR here breaks exec) --"
        chroot "$ALTERNIX_MOUNT" /bin/bash -c \
            "head -1 /home/${ALTERNIX_USERNAME}/Alternix/install-alternix_devuan.sh 2>&1 | cat -A"
        echo "-- interpreters --"
        chroot "$ALTERNIX_MOUNT" /bin/bash -c \
            "ls -l /bin/bash /usr/bin/env 2>&1"
        echo "-- syntax check --"
        chroot "$ALTERNIX_MOUNT" /bin/bash -c \
            "bash -n /home/${ALTERNIX_USERNAME}/Alternix/install-alternix_devuan.sh 2>&1 | head -10"
        echo "=== end pre-flight ==="
    } >> "$_alt_de_log" 2>&1

    # CRLF GUARD
    # The repository may carry CRLF line endings. A carriage return on
    # the shebang line makes the kernel look for an interpreter called
    # "bash\r", which fails with a bare "no such file or directory" and
    # no output whatsoever — exactly the symptom being chased here.
    chroot "$ALTERNIX_MOUNT" /bin/bash -c \
        "sed -i 's/\r$//' /home/${ALTERNIX_USERNAME}/Alternix/install-alternix_devuan.sh" \
        >> "$_alt_de_log" 2>&1 || true
    if [[ "${ALTERNIX_UNATTENDED:-0}" -eq 1 ]]; then
        chroot "$ALTERNIX_MOUNT" /usr/bin/env \
            DEBIAN_FRONTEND=noninteractive \
            DEBCONF_NONINTERACTIVE_SEEN=true \
            TARGET_USER="${ALTERNIX_USERNAME}" \
            HOME="/home/${ALTERNIX_USERNAME}" \
            TERM=xterm \
            /bin/bash -c \
            "cd /home/${ALTERNIX_USERNAME}/Alternix && \
             bash install-alternix_devuan.sh" \
            < <({ echo "${ALTERNIX_USERNAME}"; echo "${_tele}"; echo "i"; yes 2; }) \
            2>&1 | tee -a "$_alt_de_log"
        # PIPESTATUS, not $? — $? here is tee's exit code, which is
        # always 0 and would report every failed build as a success.
        alt_exit=${PIPESTATUS[0]}
    else
        # Run interactively — direct terminal, no pipes, so prompts work.
        # DEBIAN_FRONTEND=noninteractive stops debconf TUIs opening.
        chroot "$ALTERNIX_MOUNT" /usr/bin/env \
            DEBIAN_FRONTEND=noninteractive \
            DEBCONF_NONINTERACTIVE_SEEN=true \
            HOME="/home/${ALTERNIX_USERNAME}" \
            /bin/bash -c \
            "cd /home/${ALTERNIX_USERNAME}/Alternix && \
             bash install-alternix_devuan.sh"
        alt_exit=$?
    fi

    # ═══════════════════════════════════════════════════════════
    # HOME OWNERSHIP FIX — DO NOT REMOVE
    # The Alternix installer runs as root in the chroot, leaving
    # root-owned files in the user's home (.cache, .config, .local,
    # .Xauthority). Rootless X then cannot write its log and startx
    # fails with "Permission denied". Re-own the whole home dir.
    # ═══════════════════════════════════════════════════════════
    info "Fixing home directory ownership..."
    _chroot "chown -R ${ALTERNIX_USERNAME}:${ALTERNIX_USERNAME} /home/${ALTERNIX_USERNAME}"
    # Pre-create the rootless-Xorg log dir so first startx succeeds
    mkdir -p "${ALTERNIX_MOUNT}/home/${ALTERNIX_USERNAME}/.local/share/xorg" \
             "${ALTERNIX_MOUNT}/home/${ALTERNIX_USERNAME}/.cache"
    _chroot "chown -R ${ALTERNIX_USERNAME}:${ALTERNIX_USERNAME} /home/${ALTERNIX_USERNAME}/.local /home/${ALTERNIX_USERNAME}/.cache"
    ok "Home ownership corrected."

    # Verify nmcli made it in (network-manager can fail silently earlier)
    if [[ ! -x "${ALTERNIX_MOUNT}/usr/bin/nmcli" ]]; then
        warn "nmcli missing — installing network-manager..."
        _chroot "apt-get install -y network-manager" 2>&1 | tee -a "$ALTERNIX_LOG" || \
            warn "network-manager install failed — 'wifi' falls back to wpa_supplicant."
    fi

    # ═══════════════════════════════════════════════════════════
    # ENABLE dbus + NetworkManager AT BOOT — DO NOT REMOVE
    # network-manager gets installed above (or in install_base), but
    # neither it nor dbus were ever added to an OpenRC runlevel anywhere
    # in this installer. Without rc-update, neither daemon starts at
    # boot, so nmcli has nothing to talk to and every nmcli query
    # returns empty output on stdout (its actual error goes to stderr,
    # which osm-wifi's runCmd() doesn't capture) — this is the real
    # cause of osm-wifi's "nmcli returned nothing" diagnostic, on every
    # install, not just this hardware.
    # ═══════════════════════════════════════════════════════════
    _svc_enable "dbus"
    _svc_enable "network-manager"

    # ═══════════════════════════════════════════════════════════
    # SESSION + AUTOLOGIN — DO NOT REMOVE
    # Without ~/.xinitrc startx runs the default session (twm/xterm,
    # not installed) and X exits immediately with "terminated
    # successfully". Alternix runs on qtile.
    # ═══════════════════════════════════════════════════════════
    cat > "${ALTERNIX_MOUNT}/home/${ALTERNIX_USERNAME}/.xinitrc" << 'XEOF'
#!/bin/sh
exec qtile start
XEOF
    chmod +x "${ALTERNIX_MOUNT}/home/${ALTERNIX_USERNAME}/.xinitrc"
    _chroot "chown ${ALTERNIX_USERNAME}:${ALTERNIX_USERNAME} /home/${ALTERNIX_USERNAME}/.xinitrc"
    ok ".xinitrc written (qtile)."

    # Autologin on tty1 → auto-startx (user never touches a terminal)
    _write_autologin "startx"

    # Remove the temporary hosts entry added above.
    if [[ $_hosts_patched -eq 1 ]]; then
        sed -i "/^127\.0\.1\.1 ${_live_host}\$/d" \
            "${ALTERNIX_MOUNT}/etc/hosts" 2>/dev/null || true
    fi

    if [[ $alt_exit -eq 0 ]]; then
        ok "Alternix installed — system will boot into the desktop."
    else
        # ONE error, not two. The follow-up line is guidance, not a
        # second failure, and counting it inflated the error total.
        err "Alternix installer exited with code ${alt_exit}."

        # The script dies silently when a command fails under `set -e`,
        # so echo the tail of its own output here or there is nothing
        # to go on but the exit code.
        warn "Diagnostics and last output from the AlternixDE installer:"
        tail -60 "$_alt_de_log" | while IFS= read -r l; do
            echo "      ${l}"
        done
        warn "The full log is saved to the USB stick at the end of the install."
    fi
}

# ── XFCE ──────────────────────────────────────────────────────────
_install_xfce() {
    step 1 2 "Installing XFCE..."
    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        xfce4 xfce4-goodies lightdm lightdm-gtk-greeter \
        xorg dbus-x11 fonts-noto \
        2>&1" | tee -a "$ALTERNIX_LOG" | while IFS= read -r l; do
            [[ "$l" == *"Setting up"* ]] && echo -e "  ${D}${l}${N}"
        done

    step 2 2 "Enabling display manager..."
    _chroot "rc-update add lightdm default" &>/dev/null || true
    ok "XFCE installed."
}

# ── LXQt ──────────────────────────────────────────────────────────
_install_lxqt() {
    step 1 2 "Installing LXQt..."
    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        lxqt sddm xorg dbus-x11 fonts-noto \
        2>&1" | tee -a "$ALTERNIX_LOG" | while IFS= read -r l; do
            [[ "$l" == *"Setting up"* ]] && echo -e "  ${D}${l}${N}"
        done

    step 2 2 "Enabling display manager..."
    _chroot "rc-update add sddm default" &>/dev/null || true
    ok "LXQt installed."
}

# ── LXDE ──────────────────────────────────────────────────────────
_install_lxde() {
    step 1 2 "Installing LXDE..."
    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        lxde lightdm lightdm-gtk-greeter \
        xorg dbus-x11 fonts-noto \
        2>&1" | tee -a "$ALTERNIX_LOG" | while IFS= read -r l; do
            [[ "$l" == *"Setting up"* ]] && echo -e "  ${D}${l}${N}"
        done

    step 2 2 "Enabling display manager..."
    _chroot "rc-update add lightdm default" &>/dev/null || true
    ok "LXDE installed."
}

# ── MATE ──────────────────────────────────────────────────────────
_install_mate() {
    step 1 2 "Installing MATE..."
    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        mate-desktop-environment lightdm lightdm-gtk-greeter \
        xorg dbus-x11 fonts-noto \
        2>&1" | tee -a "$ALTERNIX_LOG" | while IFS= read -r l; do
            [[ "$l" == *"Setting up"* ]] && echo -e "  ${D}${l}${N}"
        done

    step 2 2 "Enabling display manager..."
    _chroot "rc-update add lightdm default" &>/dev/null || true
    ok "MATE installed."
}

# ── Openbox ───────────────────────────────────────────────────────
_install_openbox() {
    step 1 2 "Installing Openbox..."
    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        openbox obconf obmenu \
        xorg dbus-x11 fonts-noto \
        tint2 nitrogen rofi dunst \
        2>&1" | tee -a "$ALTERNIX_LOG" | while IFS= read -r l; do
            [[ "$l" == *"Setting up"* ]] && echo -e "  ${D}${l}${N}"
        done

    step 2 2 "Configuring Openbox autostart..."
    mkdir -p "${ALTERNIX_MOUNT}/home/${ALTERNIX_USERNAME}/.config/openbox"
    cat > "${ALTERNIX_MOUNT}/home/${ALTERNIX_USERNAME}/.xinitrc" << 'EOF'
#!/bin/sh
exec openbox-session
EOF
    chmod +x "${ALTERNIX_MOUNT}/home/${ALTERNIX_USERNAME}/.xinitrc"
    _chroot "chown -R ${ALTERNIX_USERNAME}:${ALTERNIX_USERNAME} /home/${ALTERNIX_USERNAME}"
    _write_autologin "startx"
    ok "Openbox installed."
}

# ── CLI only ──────────────────────────────────────────────────────
_install_cli() {
    info "CLI mode — no desktop installed."
    info "Install a desktop later with: apt-get install xfce4"

    # Nice CLI tools
    _chroot "DEBIAN_FRONTEND=noninteractive apt-get install -y \
        tmux mc ranger bat fd-find ripgrep \
        2>&1" | tee -a "$ALTERNIX_LOG" | while IFS= read -r l; do
            [[ "$l" == *"Setting up"* ]] && echo -e "  ${D}${l}${N}"
        done

    ok "CLI environment ready."
}

# ── Autologin helper ──────────────────────────────────────────────
_write_autologin() {
    local start_cmd="$1"

    # Write getty autologin for tty1
    mkdir -p "${ALTERNIX_MOUNT}/etc/inittab.d" 2>/dev/null || true

    # Patch inittab for autologin on tty1 (append the line if absent)
    local agetty_line="1:2345:respawn:/sbin/agetty --autologin ${ALTERNIX_USERNAME} --noclear tty1 38400 linux"
    if [[ -f "${ALTERNIX_MOUNT}/etc/inittab" ]]; then
        if grep -q "^1:.*tty1" "${ALTERNIX_MOUNT}/etc/inittab"; then
            sed -i "s|^1:.*tty1.*|${agetty_line}|" "${ALTERNIX_MOUNT}/etc/inittab"
        else
            echo "$agetty_line" >> "${ALTERNIX_MOUNT}/etc/inittab"
        fi
        if grep -q "autologin ${ALTERNIX_USERNAME}" "${ALTERNIX_MOUNT}/etc/inittab"; then
            ok "Autologin enabled for ${ALTERNIX_USERNAME} on tty1."
        else
            warn "Autologin patch did NOT land in /etc/inittab — check manually."
        fi
    else
        warn "/etc/inittab missing — autologin not configured."
    fi

    # Write .bash_profile to auto-startx on login
    cat > "${ALTERNIX_MOUNT}/home/${ALTERNIX_USERNAME}/.bash_profile" << EOF
# Auto-start desktop on tty1 login
if [[ -z "\$DISPLAY" ]] && [[ "\$(tty)" == "/dev/tty1" ]]; then
    ${start_cmd}
fi
EOF
    _chroot "chown ${ALTERNIX_USERNAME}:${ALTERNIX_USERNAME} /home/${ALTERNIX_USERNAME}/.bash_profile"
    ok "Autologin configured for ${ALTERNIX_USERNAME} → ${start_cmd}"
}
