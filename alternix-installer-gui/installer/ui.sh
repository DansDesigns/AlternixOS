#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# ui.sh — Alternix Installer UI helpers
# ═══════════════════════════════════════════════════════════════

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'
M='\033[0;35m'; C='\033[0;36m'; W='\033[1;37m'; D='\033[0;37m'
T='\033[0;36m'; N='\033[0m'

# ── Overall install progress ──────────────────────────────────────
INSTALL_TOTAL_STEPS=8
INSTALL_CURRENT_STEP=0
INSTALL_STEP_NAME=""

progress_set() {
    INSTALL_CURRENT_STEP=$1
    INSTALL_STEP_NAME="$2"
    # Machine-readable token for the graphical installer, which
    # parses stdout to drive its progress bar. Only emitted when
    # unattended, so the text installer looks exactly as before.
    if [[ "${ALTERNIX_UNATTENDED:-0}" -eq 1 ]]; then
        echo "##STEP:${1}:${2}"
    fi
}

_draw_overall_bar() {
    local width=34
    local filled=$(( INSTALL_CURRENT_STEP * width / INSTALL_TOTAL_STEPS ))
    local empty=$(( width - filled ))
    local bar="" i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty;  i++ )); do bar+="░"; done
    local pct=$(( INSTALL_CURRENT_STEP * 100 / INSTALL_TOTAL_STEPS ))
    echo -e "  ${T}[${bar}]${N} ${W}${pct}%${N}  ${D}${INSTALL_STEP_NAME:-starting...}${N}"
    echo ""
}

# ── Banner with live system specs ────────────────────────────────
# STATIC BANNER — DO NOT REMOVE
# The banner occupies the top 16 lines; an ANSI scroll region (ESC[17;Nr)
# confines all further console output BELOW it, so new text can never
# push the banner off-screen.
ALTERNIX_BANNER_LINES=16

banner() {
    # UNATTENDED GUARD
    # Under the graphical installer this is called a dozen times and
    # each call redraws the full ASCII header plus a clear-screen into
    # what the GUI shows as a plain log pane. The result is the same
    # ALTERNIX banner repeated over and over in the details box.
    if [[ "${ALTERNIX_UNATTENDED:-0}" -eq 1 ]]; then
        return 0
    fi
    # Do not clear screen if an error is currently displayed
    if [[ "${ALTERNIX_ERROR_SHOWN:-0}" -eq 1 ]]; then
        return 0
    fi
    # Reset any previous scroll region, then clear
    printf '\033[r'
    clear
    local cpu ram arch
    cpu=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | sed 's/.*: //' | sed 's/  */ /g' | cut -c1-36 || echo "Unknown")
    ram=$(awk '/MemTotal/{printf "%.0f MB",$2/1024}' /proc/meminfo 2>/dev/null || echo "?")
    arch=$(uname -m 2>/dev/null || echo "?")

    echo -e "${T}"
    echo "   █████╗ ██╗     ████████╗███████╗██████╗ ███╗   ██╗██╗██╗  ██╗"
    echo "  ██╔══██╗██║     ╚══██╔══╝██╔════╝██╔══██╗████╗  ██║██║╚██╗██╔╝"
    echo "  ███████║██║        ██║   █████╗  ██████╔╝██╔██╗ ██║██║ ╚███╔╝ "
    echo "  ██╔══██║██║        ██║   ██╔══╝  ██╔══██╗██║╚██╗██║██║ ██╔██╗ "
    echo "  ██║  ██║███████╗   ██║   ███████╗██║  ██║██║ ╚████║██║██╔╝ ██╗"
    echo "  ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝"
    echo -e "${N}"
    echo -e "  ${W}Alternix Installer v0.1${N}  ${D}One OS. Any machine.${N}"
    echo ""
    echo -e "  ${D}CPU   ${N}${W}${cpu}${N}"
    # Battery meter (laptops) — blank on desktops
    local bat_cap bat_stat bat_str=""
    bat_cap=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | sed -n 1p)
    bat_stat=$(cat /sys/class/power_supply/BAT*/status 2>/dev/null | sed -n 1p)
    if [[ -n "$bat_cap" ]]; then
        local bat_col="$G"
        (( bat_cap < 50 )) && bat_col="$Y"
        (( bat_cap < 20 )) && bat_col="$R"
        local bat_sym="▮"
        [[ "$bat_stat" == "Charging" ]] && bat_sym="⚡"
        bat_str="   ${D}Batt${N} ${bat_col}${bat_sym}${bat_cap}%${N}"
    fi
    echo -e "  ${D}RAM   ${N}${W}${ram}${N}   ${D}Arch${N} ${W}${arch}${N}${bat_str}"
    local _ec=${ALTERNIX_ERROR_COUNT:-0}
    if [[ $_ec -gt 0 ]]; then
        printf "  ${R}Errors Encountered: %02d${N}\n" "$_ec"
    else
        echo -e "  ${G}Errors Encountered: 00${N}"
    fi
    echo ""
    _draw_overall_bar

    # Lock the header: scrolling only happens below line ALTERNIX_BANNER_LINES
    local _rows
    _rows=$(stty size 2>/dev/null | cut -d' ' -f1)
    [[ -z "$_rows" || "$_rows" -le $(( ALTERNIX_BANNER_LINES + 4 )) ]] && _rows=24
    printf '\033[%d;%dr' $(( ALTERNIX_BANNER_LINES + 1 )) "$_rows"
    printf '\033[%d;1H' $(( ALTERNIX_BANNER_LINES + 1 ))
}

section() {
    echo ""
    echo -e "  ${T}══  ${W}$1${T}  ══${N}"
    echo ""
}

info()  { echo -e "  ${D}·${N} $1"; }
ok()    { echo -e "  ${G}✓${N} $1"; }
warn()  { echo -e "  ${Y}!${N} $1"; }
err()   { ALTERNIX_ERROR_COUNT=$(( ${ALTERNIX_ERROR_COUNT:-0} + 1 )); echo -e "  ${R}✗${N} $1"; }
die()   { err "$1"; echo ""; exit 1; }

confirm() {
    local msg="${1:-Continue?}"
    while true; do
        echo -en "  ${W}${msg}${N} ${D}[y/n]${N} "
        read -r ans
        case "$ans" in
            [yY]*) return 0 ;;
            [nN]*) return 1 ;;
            *) warn "Please enter y or n." ;;
        esac
    done
}

prompt_input() {
    local -n _ref=$1
    local msg="$2" default="${3:-}" hint=""
    [[ -n "$default" ]] && hint=" ${D}[${default}]${N}"
    while true; do
        echo -en "  ${W}${msg}${N}${hint}: "
        read -r _ref
        [[ -z "$_ref" && -n "$default" ]] && _ref="$default"
        [[ -n "$_ref" ]] && return 0
        warn "Value required."
    done
}

prompt_password() {
    local -n _pref=$1
    local msg="$2"
    while true; do
        echo -en "  ${W}${msg}${N}: "
        read -rs _pref; echo ""
        [[ -n "$_pref" ]] && return 0
        warn "Password cannot be empty."
    done
}

SPIN_PID=""
spin_start() {
    local msg="$1"

    # UNATTENDED GUARD
    # The spinner redraws with carriage returns and never emits a
    # newline until spin_stop. The graphical installer reads the
    # installer's output line by line, so a spinner running for two
    # minutes at ten frames a second becomes a single line holding
    # about twelve hundred copies of the same message, which is then
    # dumped into the log pane in one go. Print the message once
    # instead and let the progress bar convey that work is happening.
    if [[ "${ALTERNIX_UNATTENDED:-0}" -eq 1 ]]; then
        echo "  ${msg}"
        SPIN_PID=""
        return 0
    fi

    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    ( local i=0
      while true; do
          echo -en "\r  ${T}${frames[$i]}${N}  ${msg}  "
          i=$(( (i+1) % 10 )); sleep 0.1
      done ) &
    SPIN_PID=$!; disown "$SPIN_PID"
}

spin_stop() {
    if [[ -n "$SPIN_PID" ]]; then
        kill "$SPIN_PID" 2>/dev/null
        wait "$SPIN_PID" 2>/dev/null
        SPIN_PID=""; echo -en "\r"
    fi
}

progress_bar() {
    local cur=$1 total=$2 label="${3:-}"
    local width=40
    local filled=$(( cur * width / total ))
    local empty=$(( width - filled ))
    local bar="" i
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    for (( i=0; i<empty;  i++ )); do bar+="░"; done
    local pct=$(( cur * 100 / total ))
    echo -en "\r  ${T}[${bar}]${N} ${W}${pct}%${N}  ${D}${label}${N}  "
}

# ── Console font size — asked first, applied live ──────────────────
select_font_size() {
    clear
    echo ""
    echo -e "  ${W}Console font size${N}"
    echo ""
    echo -e "  ${T}1${N}  Small   (8x16)"
    echo -e "  ${T}2${N}  Normal  (10x20)   ${D}default${N}"
    echo -e "  ${T}3${N}  Large   (16x32)"
    echo -e "  ${T}4${N}  Extra large (32x16, for HiDPI/touchscreens)"
    echo ""

    local font_map=("VGA" "Terminus10x20" "Ter-132n" "Ter-132b")
    # setfont-loadable names (available in kbd package, live env + target)
    local setfont_map=("default8x16" "Uni2-Terminus10x20" "Uni2-Terminus32x16" "Uni2-TerminusBold32x16")
    local console_setup_map=("VGA" "Terminus" "Terminus" "TerminusBold")
    local console_size_map=("16" "20" "32" "32")

    while true; do
        echo -en "  ${W}Select${N} ${D}[2]${N}: "
        read -r choice
        case "$choice" in ""|2) choice=2 ;; esac
        if [[ "$choice" =~ ^[1-4]$ ]]; then
            local idx=$(( choice - 1 ))
            ALTERNIX_FONT_SETFONT="${setfont_map[$idx]}"
            ALTERNIX_FONT_FACE="${console_setup_map[$idx]}"
            ALTERNIX_FONT_SIZE="${console_size_map[$idx]}"
            break
        fi
        warn "Enter 1-4."
    done

    # Apply immediately in the live console so the rest of the
    # installer is readable right away.
    setfont "$ALTERNIX_FONT_SETFONT" 2>/dev/null || true
    ok "Console font set."
}

step() { echo -e "  ${D}[${N}${W}$1${N}${D}/${W}$2${N}${D}]${N}  $3"; }

press_any_key() {
    echo ""
    echo -en "  ${D}Press any key to continue...${N}"
    read -rsn1; echo ""
}
