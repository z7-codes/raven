#!/usr/bin/env bash
# ============================================================
#  lib/ui.sh — Raven's UI layer (sourced by raven.sh)
#  Colors, banner/logo rendering, box-drawn menu, dependency
#  summary. Nothing here touches scan logic or output files.
#  Author: z7
# ============================================================

UI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGO_FILE="${UI_DIR}/../assets/logo.jpg"

# ---------- color capability detection ----------
# Honors NO_COLOR (https://no-color.org) and a --no-color flag,
# falls back cleanly when stdout isn't a terminal or tput is missing.
UI_USE_COLOR=1
for _a in "$@"; do [ "$_a" == "--no-color" ] && UI_USE_COLOR=0; done
[ -n "${NO_COLOR:-}" ] && UI_USE_COLOR=0
[ -t 1 ] || UI_USE_COLOR=0

UI_COLORS=8
if [ "$UI_USE_COLOR" -eq 1 ] && command -v tput >/dev/null 2>&1; then
    UI_COLORS=$(tput colors 2>/dev/null || echo 8)
fi

if [ "$UI_USE_COLOR" -eq 1 ]; then
    C_RESET="\e[0m"; C_BOLD="\e[1m"; C_DIM="\e[2m"
    if [ "$UI_COLORS" -ge 256 ]; then
        C_RED="\e[38;5;196m"; C_GREEN="\e[38;5;82m"; C_YELLOW="\e[38;5;214m"
        C_BLUE="\e[38;5;75m"; C_MAGENTA="\e[38;5;170m"; C_CYAN="\e[38;5;123m"
        C_ACCENT="\e[38;5;196m"   # logo crosshair red
        C_WHITE="\e[38;5;255m"
    else
        C_RED="\e[91m"; C_GREEN="\e[92m"; C_YELLOW="\e[93m"
        C_BLUE="\e[94m"; C_MAGENTA="\e[95m"; C_CYAN="\e[96m"
        C_ACCENT="\e[91m"; C_WHITE="\e[97m"
    fi
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
    C_ACCENT=""; C_WHITE=""
fi

# ---------- terminal width ----------
ui_cols() {
    local c
    if command -v tput >/dev/null 2>&1; then c=$(tput cols 2>/dev/null); fi
    [ -z "$c" ] && c=80
    echo "$c"
}

# ---------- cursor / screen helpers ----------
ui_hide_cursor() { [ "$UI_USE_COLOR" -eq 1 ] && printf '\e[?25l'; }
ui_show_cursor() { [ "$UI_USE_COLOR" -eq 1 ] && printf '\e[?25h'; }
# Always restore the cursor on exit, even if we were killed mid-animation.
trap ui_show_cursor EXIT

# ============================================================
#  DEPENDENCY SUMMARY (fast: command -v only, cached per run)
# ============================================================
UI_DEP_READY=0
UI_DEP_TOTAL=0
ui_refresh_dep_summary() {
    UI_DEP_TOTAL=0; UI_DEP_READY=0
    for tool in "${!TOOLS[@]}"; do
        UI_DEP_TOTAL=$((UI_DEP_TOTAL + 1))
        have "$tool" && UI_DEP_READY=$((UI_DEP_READY + 1))
    done
}

# ============================================================
#  LOGO / BANNER — Metasploit/Fluxion-style: big block wordmark
#  + a "=[ ... ]" stat block underneath. Two-tone red->magenta
#  gradient on the wordmark, dim stat lines below it.
# ============================================================
ui_wordmark_big() {
    # Row-by-row color gradient (red -> magenta) across the block
    # letters, same trick msfconsole/fluxion-style banners use to
    # avoid a flat, one-color wall of text.
    local l1 l2 l3 l4 l5 l6
    l1=' ██████╗  █████╗ ██╗   ██╗███████╗███╗   ██╗'
    l2=' ██╔══██╗██╔══██╗██║   ██║██╔════╝████╗  ██║'
    l3=' ██████╔╝███████║██║   ██║█████╗  ██╔██╗ ██║'
    l4=' ██╔══██╗██╔══██║╚██╗ ██╔╝██╔══╝  ██║╚██╗██║'
    l5=' ██║  ██║██║  ██║ ╚████╔╝ ███████╗██║ ╚████║'
    l6=' ╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═══╝'

    if [ "$UI_USE_COLOR" -eq 1 ] && [ "$UI_COLORS" -ge 256 ]; then
        echo -e "\e[38;5;196m${l1}${C_RESET}"
        echo -e "\e[38;5;197m${l2}${C_RESET}"
        echo -e "\e[38;5;198m${l3}${C_RESET}"
        echo -e "\e[38;5;163m${l4}${C_RESET}"
        echo -e "\e[38;5;128m${l5}${C_RESET}"
        echo -e "\e[38;5;93m${l6}${C_RESET}"
    else
        echo -e "${C_RED}${l1}${C_RESET}"
        echo -e "${C_RED}${l2}${C_RESET}"
        echo -e "${C_MAGENTA}${l3}${C_RESET}"
        echo -e "${C_MAGENTA}${l4}${C_RESET}"
        echo -e "${C_MAGENTA}${l5}${C_RESET}"
        echo -e "${C_MAGENTA}${l6}${C_RESET}"
    fi
}

ui_stat_block() {
    local tgt="${TARGET:-none selected}"
    printf "${C_DIM}       =[ ${C_RESET}${C_BOLD}raven v${VERSION}${C_RESET}${C_DIM}%*s]${C_RESET}\n" 38 ""
    echo -e "${C_DIM}+ -- --=[${C_RESET} recon & assessment orchestrator ${C_DIM}— by z7${C_RESET}"
    echo -e "${C_DIM}+ -- --=[${C_RESET} ${C_GREEN}${UI_DEP_READY}${C_RESET}${C_DIM}/${C_RESET}${UI_DEP_TOTAL} tools ready ${C_DIM}(option 10 to verify)${C_RESET}"
    echo -e "${C_DIM}+ -- --=[${C_RESET} target: ${C_GREEN}${tgt}${C_RESET}"
}

# Full big wordmark on wide terminals; a single compact line on
# narrow ones (<54 cols, where the block letters would wrap/break).
ui_render_logo() {
    local cols; cols=$(ui_cols)
    if [ "$cols" -lt 54 ]; then
        echo -e "${C_ACCENT}${C_BOLD}RAVEN${C_RESET} v${VERSION} — recon orchestrator — ${C_DIM}by z7${C_RESET}"
        echo -e "${C_DIM}target: ${C_GREEN}${TARGET:-none selected}${C_RESET}"
        return
    fi
    ui_wordmark_big
    echo
    ui_stat_block
}

ui_info_bar() {
    local cols; cols=$(ui_cols)
    local u d
    u="$(whoami 2>/dev/null)@$(hostname 2>/dev/null)"
    d=$(date '+%d %b %Y %H:%M')
    [ "$cols" -lt 54 ] && return
    echo -e "${C_DIM}────────────────────────────────────────────────────────────────${C_RESET}"
    echo -e "${C_DIM}user:${C_RESET} ${u}   ${C_DIM}date:${C_RESET} ${d}"
}

ui_banner() {
    ui_render_logo
    ui_info_bar
    [ -n "${TARGET:-}" ] && ui_alert_dashboard
    echo
}

ui_alert_dashboard() {
    [ -z "${TARGET_DIR:-}" ] && return
    local db="${TARGET_DIR}/report/alerts.db"
    [ -s "$db" ] || return
    local crit high med low info_c
    crit=$(grep -c "^Critical|" "$db" 2>/dev/null || echo 0)
    high=$(grep -c "^High|" "$db" 2>/dev/null || echo 0)
    med=$(grep -c "^Medium|" "$db" 2>/dev/null || echo 0)
    low=$(grep -c "^Low|" "$db" 2>/dev/null || echo 0)
    info_c=$(grep -c "^Info|" "$db" 2>/dev/null || echo 0)
    echo -e "${C_DIM}alerts:${C_RESET} ${C_RED}${crit} Crit${C_RESET} ${C_RED}${high} High${C_RESET} ${C_YELLOW}${med} Med${C_RESET} ${C_BLUE}${low} Low${C_RESET} ${C_DIM}${info_c} Info${C_RESET}"
}

# ============================================================
#  MAIN MENU — grouped sections, footer hints
# ============================================================
ui_main_menu() {
    local cols; cols=$(ui_cols)
    local w=56
    [ "$cols" -lt 60 ] && w=$((cols - 2))

    echo -e "${C_MAGENTA}┌─ RAVEN ── MAIN MENU $(printf '─%.0s' $(seq 1 $((w - 22))))┐${C_RESET}"
    echo -e "${C_MAGENTA}│${C_RESET}"
    echo -e "${C_MAGENTA}│${C_RESET}  ${C_BOLD}RECON${C_RESET}"
    echo -e "${C_MAGENTA}│${C_RESET}   ${C_CYAN}1${C_RESET}  ▸ Target selection"
    echo -e "${C_MAGENTA}│${C_RESET}   ${C_CYAN}2${C_RESET}  ▸ Passive recon      ${C_DIM}(parallel)${C_RESET}"
    echo -e "${C_MAGENTA}│${C_RESET}   ${C_CYAN}3${C_RESET}  ▸ Active recon       ${C_DIM}(parallel)${C_RESET}"
    echo -e "${C_MAGENTA}│${C_RESET}"
    echo -e "${C_MAGENTA}│${C_RESET}  ${C_BOLD}SCANNING${C_RESET}"
    echo -e "${C_MAGENTA}│${C_RESET}   ${C_CYAN}4${C_RESET}  ▸ Deep network scan"
    echo -e "${C_MAGENTA}│${C_RESET}   ${C_CYAN}5${C_RESET}  ▸ Vulnerability scan ${C_DIM}(parallel)${C_RESET}"
    echo -e "${C_MAGENTA}│${C_RESET}   ${C_CYAN}6${C_RESET}  ▸ Packet capture"
    echo -e "${C_MAGENTA}│${C_RESET}   ${C_CYAN}7${C_RESET}  ▸ Full auto          ${C_DIM}(background tmux)${C_RESET}"
    echo -e "${C_MAGENTA}│${C_RESET}"
    echo -e "${C_MAGENTA}│${C_RESET}  ${C_BOLD}REPORTING${C_RESET}"
    echo -e "${C_MAGENTA}│${C_RESET}   ${C_CYAN}8${C_RESET}  ▸ Show results"
    echo -e "${C_MAGENTA}│${C_RESET}  ${C_CYAN}11${C_RESET}  ▸ Generate report    ${C_DIM}(HTML+CSV+JSON)${C_RESET}"
    echo -e "${C_MAGENTA}│${C_RESET}"
    echo -e "${C_MAGENTA}│${C_RESET}  ${C_BOLD}SYSTEM${C_RESET}"
    echo -e "${C_MAGENTA}│${C_RESET}   ${C_CYAN}9${C_RESET} Plugins   ${C_CYAN}10${C_RESET} Dependencies   ${C_CYAN}12${C_RESET} Options"
    echo -e "${C_MAGENTA}│${C_RESET}  ${C_CYAN}13${C_RESET} Help      ${C_CYAN}14${C_RESET} Exit"
    echo -e "${C_MAGENTA}│${C_RESET}"
    echo -e "${C_MAGENTA}└$(printf '─%.0s' $(seq 1 $w))┘${C_RESET}"
    echo -e "${C_DIM}  Enter a number · Ctrl+C to interrupt a running step · 13 for help${C_RESET}"
}
