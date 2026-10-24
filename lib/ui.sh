#!/usr/bin/env bash
# ============================================================
#  lib/ui.sh — Raven's UI layer (sourced by raven.sh)
#  Colors, banner/logo rendering, box-drawn menu, dependency
#  summary. Nothing here touches scan logic or output files.
#  Author: z7
# ============================================================

# ---------- color capability detection ----------
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
        C_ACCENT="\e[38;5;196m"; C_WHITE="\e[38;5;255m"
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

# ---------- terminal width (re-read every call -> resize-aware) ----------
ui_cols() {
    local c
    if command -v tput >/dev/null 2>&1; then c=$(tput cols 2>/dev/null); fi
    [ -z "$c" ] && c=80
    echo "$c"
}
UI_NARROW_THRESHOLD=60   # one shared threshold for logo AND menu -> no mismatch

# ---------- cursor / screen helpers ----------
ui_hide_cursor() { [ "$UI_USE_COLOR" -eq 1 ] && printf '\e[?25l'; }
ui_show_cursor() { [ "$UI_USE_COLOR" -eq 1 ] && printf '\e[?25h'; }
trap ui_show_cursor EXIT

# ---------- ANSI-aware width helpers (fixes the box-border bug) ----------
# Measuring with bash's ${#s} is NOT reliable here: it counts bytes,
# not Unicode codepoints, whenever the shell's locale isn't UTF-8 (the
# box-drawing/▸ characters are 3-byte UTF-8; a POSIX/C locale — common
# on minimal installs — makes ${#s} overcount and breaks the border).
# Fix: force LC_ALL=C byte counting explicitly, then subtract UTF-8
# CONTINUATION bytes (0x80-0xBF) so the result is the true codepoint
# count regardless of the system's actual locale setting.
ui_strip_ansi() { printf '%s' "$1" | sed -E $'s/\x1b\\[[0-9;]*m//g'; }
ui_visible_len() {
    local s byte_len cont_bytes
    s=$(ui_strip_ansi "$1")
    byte_len=$(LC_ALL=C printf '%s' "$s" | LC_ALL=C wc -c)
    cont_bytes=$(LC_ALL=C printf '%s' "$s" | LC_ALL=C grep -o $'[\x80-\xBF]' 2>/dev/null | LC_ALL=C wc -l)
    printf '%s' "$((byte_len - cont_bytes))"
}

# box_line "<content, colors ok>" <inner_width>
# Pads content (measured WITHOUT ansi codes) to inner_width and wraps
# it in "│ ... │". Top/bottom borders are generated from the SAME
# inner_width, so they can never drift apart by a character again.
box_line() {
    local content="$1" w="$2" vlen pad
    vlen=$(ui_visible_len "$content")
    pad=$((w - vlen))
    [ "$pad" -lt 0 ] && pad=0
    printf "${C_MAGENTA}│${C_RESET}%b%*s${C_MAGENTA}│${C_RESET}\n" "$content" "$pad" ""
}
box_top() {
    local label="$1" w="$2" llen dashes
    llen=$(ui_visible_len "$label")
    dashes=$((w - llen))
    [ "$dashes" -lt 0 ] && dashes=0
    printf "${C_MAGENTA}┌%b%s┐${C_RESET}\n" "$label" "$(printf '─%.0s' $(seq 1 "$dashes") 2>/dev/null)"
}
box_bottom() {
    local w="$1"
    printf "${C_MAGENTA}└%s┘${C_RESET}\n" "$(printf '─%.0s' $(seq 1 "$w") 2>/dev/null)"
}

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
#  LOGO / BANNER — capped at 8 lines total (6 wordmark + 2 info),
#  fits inside 80 columns, falls back to a single line under
#  UI_NARROW_THRESHOLD cols so it never wraps or gets cut off.
# ============================================================
# A literal crow silhouette doesn't hold up at terminal block-character
# resolution (tried it — reads as a blob, not a bird). The reticle/
# crosshair ring from the reference art DOES read cleanly in box-drawing
# characters, so that's what sits to the left of the wordmark, with the
# red "eye" dot as the one accent color tying back to the source logo.
ui_wordmark_big() {
    local crow=(
        '      │      '
        '   ╭──┼──╮   '
        '  ─┤     ├─  '
        '  ─┤  ●  ├─  '
        '   ╰──┼──╯   '
        '      │      '
    )
    local l1 l2 l3 l4 l5 l6
    l1=' ██████╗  █████╗ ██╗   ██╗███████╗███╗   ██╗'
    l2=' ██╔══██╗██╔══██╗██║   ██║██╔════╝████╗  ██║'
    l3=' ██████╔╝███████║██║   ██║█████╗  ██╔██╗ ██║'
    l4=' ██╔══██╗██╔══██║╚██╗ ██╔╝██╔══╝  ██║╚██╗██║'
    l5=' ██║  ██║██║  ██║ ╚████╔╝ ███████╗██║ ╚████║'
    l6=' ╚═╝  ╚═╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═══╝'

    local crow_color eye_color word_colors=()
    if [ "$UI_USE_COLOR" -eq 1 ] && [ "$UI_COLORS" -ge 256 ]; then
        crow_color="\e[38;5;95m"   # muted dark-red/grey ring
        eye_color="\e[38;5;196m"   # bright red eye accent
        word_colors=("\e[38;5;196m" "\e[38;5;197m" "\e[38;5;198m" "\e[38;5;163m" "\e[38;5;128m" "\e[38;5;93m")
    else
        crow_color="${C_DIM}"
        eye_color="${C_RED}"
        word_colors=("${C_RED}" "${C_RED}" "${C_MAGENTA}" "${C_MAGENTA}" "${C_MAGENTA}" "${C_MAGENTA}")
    fi

    local i wlines=("$l1" "$l2" "$l3" "$l4" "$l5" "$l6")
    for i in 0 1 2 3 4 5; do
        local crow_line="${crow[$i]}"
        if [ "$i" -eq 3 ]; then
            # Row with the eye: color just the ● glyph in the accent red,
            # the rest of the ring in the muted color.
            printf "${crow_color}%s${eye_color}%s${crow_color}%s${C_RESET}  %b${wlines[$i]}${C_RESET}\n" \
                "  ─┤  " "●" "  ├─  " "${word_colors[$i]}"
        else
            printf "${crow_color}%s${C_RESET}  %b${wlines[$i]}${C_RESET}\n" "$crow_line" "${word_colors[$i]}"
        fi
    done
}

# 3-line compact info block: tagline+version, the DISCOVER/ENUMERATE/
# ANALYZE/HUNT strapline, then target+deps (total logo height 6+3=9).
ui_stat_block() {
    local tgt="${TARGET:-none selected}"
    echo -e "${C_DIM}v${VERSION} · by z7 · recon & assessment orchestrator${C_RESET}"
    echo -e "${C_DIM}DISCOVER${C_RESET} / ${C_DIM}ENUMERATE${C_RESET} / ${C_DIM}ANALYZE${C_RESET} / ${C_DIM}HUNT${C_RESET}"
    echo -e "${C_DIM}target:${C_RESET} ${C_GREEN}${tgt}${C_RESET} ${C_DIM}·${C_RESET} ${C_GREEN}${UI_DEP_READY}${C_RESET}${C_DIM}/${C_RESET}${UI_DEP_TOTAL} ${C_DIM}tools ready${C_RESET}"
}

ui_render_logo() {
    local cols; cols=$(ui_cols)
    if [ "$cols" -lt "$UI_NARROW_THRESHOLD" ]; then
        echo -e "${C_ACCENT}${C_BOLD}RAVEN${C_RESET} v${VERSION} — recon orchestrator — ${C_DIM}by z7${C_RESET}"
        echo -e "${C_DIM}target: ${C_GREEN}${TARGET:-none selected}${C_RESET} ${C_DIM}·${C_RESET} ${UI_DEP_READY}/${UI_DEP_TOTAL} ready"
        return
    fi
    # (full 9-line logo below: 6-line crow+wordmark + 3-line stat block)
    ui_wordmark_big
    ui_stat_block
}

ui_info_bar() {
    local cols; cols=$(ui_cols)
    [ "$cols" -lt "$UI_NARROW_THRESHOLD" ] && return
    local u d line w
    u="$(whoami 2>/dev/null)@$(hostname 2>/dev/null)"
    d=$(date '+%d %b %Y %H:%M')
    w=$((cols > 78 ? 78 : cols - 2))
    [ "$w" -lt 1 ] && w=1
    line=$(printf '─%.0s' $(seq 1 "$w") 2>/dev/null)
    echo -e "${C_DIM}${line}${C_RESET}"
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
#  MAIN MENU — width computed from tput cols, ANSI-stripped
#  before measuring (box_line/box_top/box_bottom above), so the
#  frame can't break or drift by a character. Falls back to a
#  flat, unboxed list under UI_NARROW_THRESHOLD.
# ============================================================
ui_main_menu() {
    local cols; cols=$(ui_cols)

    if [ "$cols" -lt "$UI_NARROW_THRESHOLD" ]; then
        cat <<EOF
RAVEN MAIN MENU
 RECON       1 Target   2 Passive   3 Active
 SCANNING    4 Deep scan  5 Vuln scan  6 Pcap  7 Full auto
 REPORTING   8 Results    11 Report
 SYSTEM      9 Plugins  10 Deps  12 Options  13 Help  14 Exit
EOF
        echo -e "${C_DIM}Enter a number · 13 for help${C_RESET}"
        return
    fi

    local w=56
    box_top " RAVEN ── MAIN MENU " "$w"
    box_line "" "$w"
    box_line "  ${C_BOLD}RECON${C_RESET}" "$w"
    box_line "   ${C_CYAN}1${C_RESET}  ▸ Target selection" "$w"
    box_line "   ${C_CYAN}2${C_RESET}  ▸ Passive recon      ${C_DIM}(parallel)${C_RESET}" "$w"
    box_line "   ${C_CYAN}3${C_RESET}  ▸ Active recon       ${C_DIM}(parallel)${C_RESET}" "$w"
    box_line "" "$w"
    box_line "  ${C_BOLD}SCANNING${C_RESET}" "$w"
    box_line "   ${C_CYAN}4${C_RESET}  ▸ Deep network scan" "$w"
    box_line "   ${C_CYAN}5${C_RESET}  ▸ Vulnerability scan ${C_DIM}(parallel)${C_RESET}" "$w"
    box_line "   ${C_CYAN}6${C_RESET}  ▸ Packet capture" "$w"
    box_line "   ${C_CYAN}7${C_RESET}  ▸ Full auto          ${C_DIM}(background tmux)${C_RESET}" "$w"
    box_line "" "$w"
    box_line "  ${C_BOLD}REPORTING${C_RESET}" "$w"
    box_line "   ${C_CYAN}8${C_RESET}  ▸ Show results" "$w"
    box_line "  ${C_CYAN}11${C_RESET}  ▸ Generate report    ${C_DIM}(HTML+CSV+JSON)${C_RESET}" "$w"
    box_line "" "$w"
    box_line "  ${C_BOLD}SYSTEM${C_RESET}" "$w"
    box_line "   ${C_CYAN}9${C_RESET} Plugins   ${C_CYAN}10${C_RESET} Dependencies   ${C_CYAN}12${C_RESET} Options" "$w"
    box_line "  ${C_CYAN}13${C_RESET} Help      ${C_CYAN}14${C_RESET} Exit" "$w"
    box_line "" "$w"
    box_bottom "$w"
    echo -e "${C_DIM}  Enter a number · Ctrl+C to interrupt a running step · 13 for help${C_RESET}"
}
