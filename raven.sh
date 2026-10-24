#!/usr/bin/env bash
# ============================================================
#  RAVEN — recon & assessment orchestrator
#  Author: z7
#  Console shows branded phase names + filtered findings only;
#  full command detail is logged (not printed) to raven.log.
# ============================================================

set -o pipefail

VERSION="0.5.0"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${BASE_DIR}/results"
SCOPE_FILE="${BASE_DIR}/scope.txt"
SESSION_FILE="${BASE_DIR}/.session"
PLUGIN_DIR="${BASE_DIR}/plugins"
LOG_FILE="${BASE_DIR}/raven.log"
CONFIG_FILE="${BASE_DIR}/raven.conf"

mkdir -p "$RESULTS_DIR" "$PLUGIN_DIR"
touch "$SCOPE_FILE" "$LOG_FILE"

have()  { command -v "$1" >/dev/null 2>&1; }

# ============================================================
#  WHITE-LABEL MODULE MAP — loaded from module_names.conf
#  Everywhere the user sees output (menu, progress, file names,
#  reports) uses MODULE_NAME/MODULE_SLUG, never the raw binary
#  name. raven.log and --debug mode are the only places the real
#  tool name is shown, for your own maintenance/troubleshooting.
# ============================================================
MODULE_CONF="${BASE_DIR}/module_names.conf"
declare -A MODULE_NAME=() MODULE_SLUG=() MODULE_REQUIRED=() MODULE_PHASE=()
# shellcheck disable=SC2034  # read by lib/ui.sh's ui_refresh_dep_summary, a separate sourced file ShellCheck can't see into
declare -A TOOLS=()   # tool -> phase label, derived from module_names.conf (kept for lib/ui.sh dep summary)

load_module_names() {
    [ -f "$MODULE_CONF" ] || { err "module_names.conf not found at $MODULE_CONF — branding map unavailable."; return 1; }
    local tool name slug req ph
    while IFS='|' read -r tool name slug req ph; do
        [[ -z "$tool" || "$tool" == \#* ]] && continue
        MODULE_NAME["$tool"]="$name"
        MODULE_SLUG["$tool"]="$slug"
        MODULE_REQUIRED["$tool"]="$req"
        MODULE_PHASE["$tool"]="$ph"
        TOOLS["$tool"]="$ph"
    done < "$MODULE_CONF"
}
load_module_names

# mname <tool>: branded display name (falls back to the raw tool
# name only if module_names.conf has no entry for it — e.g. a
# plugin author added a tool without updating the map).
mname() { echo "${MODULE_NAME[$1]:-$1}"; }
# mslug <tool>: the output-file base name for that module.
mslug() { echo "${MODULE_SLUG[$1]:-$1}"; }
# is_optional <tool>: true if module_names.conf marks it optional.
is_optional() { [ "${MODULE_REQUIRED[$1]:-required}" == "optional" ]; }

DEBUG=0
for _a in "$@"; do [ "$_a" == "--debug" ] && DEBUG=1; done

# ---------- UI layer (colors, banner, menu) ----------
# shellcheck source=lib/ui.sh
source "${BASE_DIR}/lib/ui.sh" "$@"
ui_refresh_dep_summary   # fast: command -v only, done once at startup

# ---------- logging (detailed, goes ONLY to file) ----------
log()   { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }

# ---------- console (branded, user-facing) ----------
info()  { echo -e "${C_CYAN}[*]${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
err()   { echo -e "${C_RED}[x]${C_RESET} $*"; }
phase() { echo -e "${C_MAGENTA}${C_BOLD}[RAVEN]${C_RESET} $*"; }
find_() { echo -e "${C_BLUE}  ->${C_RESET} $*"; }

pause() { echo; read -rp "$(echo -e "${C_DIM}Press ENTER to continue...${C_RESET}")" _; }

human_time() {
    local s=$1
    if [ "$s" -ge 60 ]; then printf "%dm %ds" $((s/60)) $((s%60)); else printf "%ds" "$s"; fi
}

banner() { ui_banner; }

# ============================================================
#  CONFIG — raven.conf lets you tune the underlying tools
#  without touching this script.
# ============================================================
load_config() {
    NMAP_PORTS_OPT="--top-ports 1000"
    NMAP_TIMING="-T4"
    MASSCAN_PORTS="1-65535"
    MASSCAN_RATE="1000"
    NUCLEI_OPTS="-silent"
    HTTPX_OPTS="-silent -title -status-code -tech-detect"
    DNS_RECORD_TYPES="A AAAA MX TXT NS SOA CNAME"
    PING_TIMEOUT="2"
    MAX_PARALLEL_JOBS="6"

    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        cat > "$CONFIG_FILE" <<EOF
# Raven configuration file — sourced as bash, so quote your values.
# Uncomment a line to override its default. Re-run raven.sh after editing.

#NMAP_PORTS_OPT="--top-ports 1000"     # or "-p-" for all 65535 ports
#NMAP_TIMING="-T4"                     # -T0 (slowest/stealthiest) .. -T5 (fastest)
#MASSCAN_PORTS="1-65535"
#MASSCAN_RATE="1000"                   # packets/sec
#NUCLEI_OPTS="-silent"                 # e.g. "-silent -severity critical,high"
#HTTPX_OPTS="-silent -title -status-code -tech-detect"
#DNS_RECORD_TYPES="A AAAA MX TXT NS SOA CNAME"
#PING_TIMEOUT="2"                      # seconds, used for the latency/ETA probe
#MAX_PARALLEL_JOBS="6"                 # cap on concurrent tools per phase
EOF
    fi
}

# ---------- interrupt handling ----------
INTERRUPTED=0
CURRENT_STEP_LABEL=""
ACTIVE_PIDS=()
on_interrupt() {
    INTERRUPTED=1
    if [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; then
        for pid in "${ACTIVE_PIDS[@]}"; do kill "$pid" 2>/dev/null; done
    fi
    echo
    warn "Interrupted during: ${CURRENT_STEP_LABEL:-current step}"
    warn "Partial output (if any) has been kept under: ${TARGET_DIR:-$RESULTS_DIR}"
    log "INTERRUPTED during: ${CURRENT_STEP_LABEL:-unknown}"
    echo
    read -rp "$(echo -e "${C_DIM}Set a new target now? [y/N]:${C_RESET} ")" newt
    if [[ "$newt" =~ ^[Yy]$ ]]; then
        INTERRUPTED=0
        target_selection
    else
        read -rp "$(echo -e "${C_DIM}Press ENTER to return to the main menu...${C_RESET}")" _
    fi
}
trap on_interrupt INT TERM

# Run a real command silently from the user's view: logs the actual
# command + its output to raven.log, shows the branded phase label +
# elapsed time on screen, writes raw output to $3 for parsing/report.
# Returns 130 if interrupted mid-step so callers can bail out cleanly.
run_step() {
    local label="$1" cmd="$2" outfile="$3"
    CURRENT_STEP_LABEL="$label"
    phase "$label..."
    log "CMD: $cmd"
    local t0 t1 elapsed
    t0=$(date +%s)
    # BUG FIX: stderr used to go ONLY to the shared raven.log with no
    # per-module attribution, so a failing module's own result file
    # gave no clue why. Write stderr to a companion "<file>.err" next
    # to the module's own output (kept SEPARATE from stdout on purpose
    # — merging them into the data file risks corrupting the exact
    # string matches other code greps for, e.g. SPF/severity parsing),
    # and echo it into raven.log too for a single audit trail.
    local errfile="${outfile}.err"
    eval "$cmd" > "$outfile" 2> "$errfile"
    local rc=$?
    t1=$(date +%s)
    elapsed=$((t1 - t0))
    log "EXIT($rc): $cmd (${elapsed}s)"
    if [ -s "$errfile" ]; then
        { echo "--- stderr for: $cmd ---"; cat "$errfile"; } >> "$LOG_FILE"
    else
        rm -f "$errfile"
    fi
    if [ "$INTERRUPTED" -eq 1 ]; then
        INTERRUPTED=0
        return 130
    fi
    [ -n "${TARGET_DIR:-}" ] && { MANIFEST_FILE="${TARGET_DIR}/report/modules.log"; mkdir -p "${TARGET_DIR}/report"
        manifest_log "${CURRENT_PHASE_LABEL:-Deep Scan}" "$label" "$([ "$rc" -eq 0 ] && echo ok || echo failed)" "${elapsed}s"; }
    if [ $rc -eq 0 ]; then
        ok "$label — done. ($(human_time "$elapsed"))"
    else
        warn "$label — finished with warnings in $(human_time "$elapsed")$( [ -f "$errfile" ] && echo " — see $(basename "$errfile")" ) (see raven.log)."
    fi
    return $rc
}

# ============================================================
#  PARALLEL JOB RUNNER — independent tools in one phase run
#  concurrently instead of one-after-another.
# ============================================================
JOB_LABELS=(); JOB_CMDS=(); JOB_OUTS=()
SKIPPED_SUMMARY=""
add_job()  { JOB_LABELS+=("$1"); JOB_CMDS+=("$2"); JOB_OUTS+=("$3"); }
add_skip() { SKIPPED_SUMMARY="${SKIPPED_SUMMARY:+$SKIPPED_SUMMARY, }$1"; }

# bar_chars <char> <count>: <count> repeats of <char>, correctly empty
# when count<=0 (see the printf-with-no-args note at its call site).
bar_chars() {
    local ch="$1" count="$2"
    [ "$count" -le 0 ] && return
    printf "%${count}s" '' | tr ' ' "$ch"
}

# run_jobs_parallel [phase_label]
# Live multi-line display: one overall progress bar + one status
# line per module (spinner + module name + elapsed), redrawn in
# place every tick — e.g.:
#   Active Recon [######----] 60% (3/5)
#     [+] Live Host Probe        00:38
#     [/] Web Fingerprint        00:12
#     [x] Subdomain Enumeration  00:05 (warnings)
MANIFEST_FILE=""
manifest_log() {
    # <timestamp>|<phase>|<module>|<status: ok/failed/skipped>|<elapsed>
    [ -n "$MANIFEST_FILE" ] && echo "$(date '+%Y-%m-%d %H:%M:%S')|$1|$2|$3|$4" >> "$MANIFEST_FILE"
}

run_jobs_parallel() {
    local phase_label="${1:-Modules}"
    local n="${#JOB_LABELS[@]}"
    MANIFEST_FILE="${TARGET_DIR}/report/modules.log"
    mkdir -p "${TARGET_DIR}/report"
    # Record skips even when there are zero actual jobs to run.
    if [ -n "${SKIPPED_SUMMARY:-}" ]; then
        IFS=',' read -ra _skipped <<< "$SKIPPED_SUMMARY"
        for _s in "${_skipped[@]}"; do manifest_log "$phase_label" "${_s# }" "skipped" "-"; done
    fi
    [ "$n" -eq 0 ] && return 0
    log "PARALLEL BATCH START ($n jobs) [$phase_label]"
    local t_phase_start; t_phase_start=$(date +%s)

    local tmpdir; tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/raven.XXXXXX")
    local -a tfiles=() pids=() statuses=()
    local i cap="${MAX_PARALLEL_JOBS:-6}"
    local running=0

    for i in "${!JOB_LABELS[@]}"; do
        local tfile="${tmpdir}/job_${i}.time"
        tfiles+=("$tfile")
        statuses+=("running")
        (
            t0=$(date +%s)
            # Same reasoning as run_step's fix: per-job .err companion
            # file instead of all parallel jobs appending to one shared
            # raven.log at once (which can interleave mid-line) and
            # instead of merging into the data file (breaks downstream
            # parsing of that same file).
            eval "${JOB_CMDS[$i]}" > "${JOB_OUTS[$i]}" 2> "${JOB_OUTS[$i]}.err"
            rc=$?
            t1=$(date +%s)
            echo "$rc $((t1 - t0))" > "$tfile"
        ) &
        pids+=($!)
        log "CMD(parallel): ${JOB_CMDS[$i]}"
        running=$((running + 1))
        # Concurrency cap: count LIVE jobs directly rather than trusting
        # wait -n's exit status (a failed tool's non-zero exit used to
        # break this loop early and silently stop enforcing the cap).
        while [ "$running" -ge "$cap" ]; do
            local alive_now=0 p
            for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive_now=$((alive_now + 1)); done
            running=$alive_now
            [ "$running" -ge "$cap" ] && sleep 0.2
        done
    done
    ACTIVE_PIDS=("${pids[@]}")

    local spin='|/-\' si=0
    local t_start; t_start=$(date +%s)
    local first_draw=1

    draw_frame() {
        local done_count=0 j elapsed_now
        elapsed_now=$(( $(date +%s) - t_start ))
        for j in "${!pids[@]}"; do
            if [ "${statuses[$j]}" == "running" ]; then
                kill -0 "${pids[$j]}" 2>/dev/null || statuses[$j]="finished"
            fi
            [ "${statuses[$j]}" != "running" ] && done_count=$((done_count + 1))
        done

        [ "$first_draw" -eq 0 ] && printf "\e[%dA" "$((n + 1))"
        first_draw=0

        local pct=$(( n > 0 ? done_count * 100 / n : 100 ))
        # NOTE: these must be two separate `local` statements. In a
        # single `local a=X b=$a`, bash does not guarantee b sees a's
        # freshly-assigned value — it was silently computing empty
        # against an unset/zero `filled`, always rendering a full-width
        # bar of dashes regardless of real progress.
        local filled=$((pct / 5))
        local empty=$((20 - filled))
        # NOTE: `printf '#%.0s' $(seq 1 0)` still prints ONE stray '#'
        # even with zero expanded arguments (printf runs its format
        # once with empty args when given none) — that put a phantom
        # character in the bar at both 0% and 100%. bar_chars() below
        # avoids seq/printf-with-no-args entirely.
        printf "\r\e[K${C_BOLD}%s${C_RESET} [${C_GREEN}%s${C_RESET}%s] %d%% (%d/%d)\n" \
            "$phase_label" "$(bar_chars '#' "$filled")" "$(bar_chars '-' "$empty")" \
            "$pct" "$done_count" "$n"

        for j in "${!JOB_LABELS[@]}"; do
            if [ "${statuses[$j]}" == "running" ]; then
                printf "\r\e[K  ${C_CYAN}[%c]${C_RESET} %-38s %s\n" \
                    "${spin:si%4:1}" "${JOB_LABELS[$j]}" "$(human_time "$elapsed_now")"
            else
                local rc=0 el=0
                [ -f "${tfiles[$j]}" ] && read -r rc el < "${tfiles[$j]}"
                if [ "$rc" -eq 0 ]; then
                    printf "\r\e[K  ${C_GREEN}[+]${C_RESET} %-38s %s\n" "${JOB_LABELS[$j]}" "$(human_time "$el")"
                else
                    printf "\r\e[K  ${C_RED}[x]${C_RESET} %-38s %s ${C_DIM}(warnings — see %s.err)${C_RESET}\n" \
                        "${JOB_LABELS[$j]}" "$(human_time "$el")" "$(basename "${JOB_OUTS[$j]}")"
                fi
            fi
        done
    }

    # BUG FIX: ui_hide_cursor/ui_show_cursor existed in lib/ui.sh but
    # were never actually called, so the real terminal cursor stayed
    # visible and jumped around during every \e[nA in-place redraw.
    ui_hide_cursor
    while true; do
        local alive=0
        for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
        draw_frame
        si=$((si + 1))
        [ "$alive" -eq 0 ] && break
        sleep 0.2
        [ "$INTERRUPTED" -eq 1 ] && break
    done
    ui_show_cursor
    echo
    wait 2>/dev/null
    ACTIVE_PIDS=()

    if [ "$INTERRUPTED" -eq 1 ]; then
        INTERRUPTED=0
        rm -rf "$tmpdir"
        return 130
    fi

    for i in "${!JOB_LABELS[@]}"; do
        local rc=0 elapsed=0
        [ -f "${tfiles[$i]}" ] && read -r rc elapsed < "${tfiles[$i]}"
        log "EXIT($rc): ${JOB_LABELS[$i]} (${elapsed}s)"
        manifest_log "$phase_label" "${JOB_LABELS[$i]}" "$([ "$rc" -eq 0 ] && echo ok || echo failed)" "${elapsed}s"
        local jerr="${JOB_OUTS[$i]}.err"
        if [ -s "$jerr" ]; then
            { echo "--- stderr for: ${JOB_LABELS[$i]} ---"; cat "$jerr"; } >> "$LOG_FILE"
        else
            rm -f "$jerr"
        fi
    done
    manifest_log "$phase_label" "(phase total)" "duration" "$(( $(date +%s) - t_phase_start ))s"
    [ -n "${SKIPPED_SUMMARY:-}" ] && warn "Skipped (not installed): ${SKIPPED_SUMMARY}"
    SKIPPED_SUMMARY=""
    rm -rf "$tmpdir"
    JOB_LABELS=(); JOB_CMDS=(); JOB_OUTS=()
    return 0
}

# ---------- rough ETA estimation ----------
probe_latency_ms() {
    local t="$1" ms=100
    if have ping; then
        local out
        out=$(ping -c 1 -W "${PING_TIMEOUT:-2}" "$t" 2>/dev/null | grep -oE 'time=[0-9.]+' | head -1 | cut -d= -f2)
        [ -n "$out" ] && ms=${out%.*}
    fi
    [ -z "$ms" ] && ms=100
    echo "$ms"
}

estimate_phase_seconds() {
    local phase_name="$1" lat_ms="$2"
    local factor=1
    if   [ "$lat_ms" -gt 300 ]; then factor=4
    elif [ "$lat_ms" -gt 150 ]; then factor=2
    else factor=1; fi

    local max=0 v
    case "$phase_name" in
        passive)
            have whois && { v=5; [ "$v" -gt "$max" ] && max=$v; }
            have dig && { v=5; [ "$v" -gt "$max" ] && max=$v; }
            have host && { v=5; [ "$v" -gt "$max" ] && max=$v; }
            have nslookup && { v=5; [ "$v" -gt "$max" ] && max=$v; }
            have dnsrecon && { v=$((40*factor)); [ "$v" -gt "$max" ] && max=$v; }
            have subfinder && { v=$((30*factor)); [ "$v" -gt "$max" ] && max=$v; }
            have amass && { v=$((90*factor)); [ "$v" -gt "$max" ] && max=$v; }
            ;;
        active)
            have httpx && { v=$((30*factor)); [ "$v" -gt "$max" ] && max=$v; }
            have whatweb && { v=$((15*factor)); [ "$v" -gt "$max" ] && max=$v; }
            ;;
        deep)
            have nmap && { v=$((60*factor)); [ "$v" -gt "$max" ] && max=$v; }
            have masscan && { v=$((90*factor)); [ "$v" -gt "$max" ] && max=$v; }
            ;;
        vuln)
            have nikto && { v=$((120*factor)); [ "$v" -gt "$max" ] && max=$v; }
            have nuclei && { v=$((90*factor)); [ "$v" -gt "$max" ] && max=$v; }
            ;;
    esac
    [ "$max" -eq 0 ] && max=10
    echo "$max"
}

show_eta() {
    local phase_name="$1"
    [ -z "$TARGET" ] && return
    local lat eta
    lat=$(probe_latency_ms "$TARGET")
    eta=$(estimate_phase_seconds "$phase_name" "$lat")
    info "Estimated time for this phase: ~$(human_time "$eta") (modules run in parallel; target latency ~${lat}ms)"
}

# ============================================================
#  RESUME / SKIP
# ============================================================
state_file() { echo "${TARGET_DIR}/.state"; }

phase_completed_at() {
    local f; f=$(state_file)
    [ -f "$f" ] && grep "^$1=" "$f" | tail -1 | cut -d= -f2-
}

mark_phase_done() {
    echo "$1=$(date '+%Y-%m-%d %H:%M:%S')" >> "$(state_file)"
}

confirm_rerun() {
    local key="$1" label="$2"
    local prev; prev=$(phase_completed_at "$key")
    if [ -n "$prev" ]; then
        warn "$label already ran for ${TARGET} at: $prev"
        read -rp "Re-run it anyway? [y/N]: " rr
        [[ "$rr" =~ ^[Yy]$ ]] || { info "Skipped — keeping previous results."; return 1; }
    fi
    return 0
}

# ============================================================
#  TARGET / SESSION / SCOPE
# ============================================================
TARGET=""; TARGET_DIR=""

load_session() { [ -f "$SESSION_FILE" ] && TARGET=$(cat "$SESSION_FILE"); [ -n "$TARGET" ] && TARGET_DIR="${RESULTS_DIR}/${TARGET}"; }
save_session()  { echo "$TARGET" > "$SESSION_FILE"; }

# Accepts a bare hostname/domain (letters, digits, dot, hyphen, optional
# leading wildcard "*.") or a plain IPv4/IPv6 address. Rejects anything
# containing shell metacharacters, quotes, spaces, etc. This is what
# keeps $TARGET safe to interpolate into the eval'd tool commands below —
# a target like "x'; rm -rf ~; echo '" is refused here, not escaped later.
is_valid_target() {
    local t="$1"
    [[ "$t" =~ ^(\*\.)?[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] && return 0
    [[ "$t" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 0
    [[ "$t" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$t" == *:* ]] && return 0
    return 1
}

# Anchored scope check: an entry "example.com" matches "example.com" and
# "*.example.com" / "sub.example.com", but NOT "example.com.evil.net".
# A wildcard entry "*.example.com" matches any subdomain, not the apex.
in_scope() {
    local t="$1" entry
    [ ! -s "$SCOPE_FILE" ] && return 1
    while IFS= read -r entry; do
        entry="${entry%%$'\r'}"
        [ -z "$entry" ] && continue
        if [[ "$entry" == \*.* ]]; then
            local base="${entry#\*.}"
            [[ "$t" == "$base" || "$t" == *".$base" ]] && return 0
        else
            [[ "$t" == "$entry" || "$t" == *".$entry" ]] && return 0
        fi
    done < "$SCOPE_FILE"
    return 1
}

# BUG FIX: this used to show the numbered scope list but then ignore
# it completely — you still had to re-type the full domain by hand
# even when it was entry #2 right there on screen. Now a bare number
# selects that scope entry directly; anything else is treated as a
# new domain to validate, add to scope, and select in one step.
target_selection() {
    clear; banner
    echo -e "${C_BOLD}── Target Selection ──${C_RESET}\n"
    local -a scope_entries=()
    if [ -s "$SCOPE_FILE" ]; then
        echo -e "${C_DIM}Current scope entries — enter a number to select one:${C_RESET}"
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            scope_entries+=("$line")
            printf "  %d) %s\n" "${#scope_entries[@]}" "$line"
        done < "$SCOPE_FILE"
    else
        warn "Scope file empty — type a new domain below to add it (wildcards like *.example.com allowed)."
    fi
    echo
    read -rp "Number from the list above, or a new domain to add+select: " sel

    local t=""
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#scope_entries[@]}" ]; then
        t="${scope_entries[$((sel - 1))]}"
        if [[ "$t" == \** ]]; then
            err "'$t' is a wildcard scope entry — it authorizes a range, it isn't a scannable host itself. Type a concrete subdomain instead."
            pause; return
        fi
    elif [ -n "$sel" ]; then
        if ! is_valid_target "$sel"; then
            err "'$sel' doesn't look like a valid domain/IP (letters, digits, dots, hyphens, or a *.domain wildcard). Aborted for safety."
            pause; return
        fi
        if ! grep -qxF "$sel" "$SCOPE_FILE" 2>/dev/null; then
            echo "$sel" >> "$SCOPE_FILE"
            ok "Added '$sel' to scope."
        fi
        t="$sel"
    else
        warn "Nothing entered."; pause; return
    fi

    if ! in_scope "$t"; then
        warn "'$t' is NOT listed in scope.txt."
        read -rp "Proceed anyway, only if authorization is verified elsewhere [y/N]: " conf
        [[ "$conf" =~ ^[Yy]$ ]] || { warn "Aborted."; pause; return; }
    fi
    TARGET="$t"; TARGET_DIR="${RESULTS_DIR}/${TARGET}"
    mkdir -p "$TARGET_DIR"/{passive,active,deepscan,vulnscan,pcap,report}
    init_report
    save_session
    ok "Target set to: $TARGET"
    pause
}

require_target() { [ -z "$TARGET" ] && { err "No target selected (menu option 1 first)."; pause; return 1; }; return 0; }

check_dependencies() {
    clear; banner
    echo -e "${C_BOLD}── Dependency Check ──${C_RESET}"
    [ "$DEBUG" -eq 1 ] && echo -e "${C_DIM}(--debug: real tool names shown in parentheses)${C_RESET}"
    echo

    local ready=0 total=0 missing_required=() missing_optional=()
    local phases=("Passive Recon" "Active Recon" "Deep Scan" "Vulnerability Scan" "Packet Capture" "System")

    for ph in "${phases[@]}"; do
        local printed_header=0
        for tool in "${!MODULE_PHASE[@]}"; do
            [ "${MODULE_PHASE[$tool]}" == "$ph" ] || continue
            [ "$printed_header" -eq 0 ] && { echo -e "  ${C_BOLD}${ph}${C_RESET}"; printed_header=1; }
            total=$((total + 1))
            local label="$(mname "$tool")"
            [ "$DEBUG" -eq 1 ] && label="${label} ${C_DIM}(${tool})${C_RESET}"
            local tag=""
            is_optional "$tool" && tag=" ${C_DIM}(optional)${C_RESET}"
            if have "$tool"; then
                ready=$((ready + 1))
                printf "   ${C_GREEN}[✓]${C_RESET} %-30b%b\n" "$label" "$tag"
            else
                if is_optional "$tool"; then
                    missing_optional+=("$tool")
                else
                    missing_required+=("$tool")
                fi
                printf "   ${C_RED}[x]${C_RESET} %-30b%b\n" "$label" "$tag"
            fi
        done
        [ "$printed_header" -eq 1 ] && echo
    done

    ui_refresh_dep_summary
    echo -e "${C_BOLD}Summary: ${C_GREEN}${ready}${C_RESET}${C_BOLD}/${total} modules ready${C_RESET}"
    echo

    if [ ${#missing_required[@]} -gt 0 ]; then
        warn "Missing (required): $(for t in "${missing_required[@]}"; do printf "%s " "$(mname "$t")"; done)"
        echo -e "   ${C_DIM}Run: sudo ./install.sh${C_RESET}"
    fi
    if [ ${#missing_optional[@]} -gt 0 ]; then
        info "Missing (optional, not required to run Raven): $(for t in "${missing_optional[@]}"; do printf "%s " "$(mname "$t")"; done)"
    fi
    [ ${#missing_required[@]} -eq 0 ] && [ ${#missing_optional[@]} -eq 0 ] && ok "All modules ready."
    pause
}

# ============================================================
#  REPORT ENGINE (ZAP-style alerts: HTML + CSV + JSON)
# ============================================================
# sev_sorted <file>: findings in TRUE severity order (Critical first),
# not alphabetical. `sort -r` on the raw text was showing Medium, Low,
# High, Critical — the reverse-alphabetical order, not actual risk
# order, which is the opposite of how a report should read.
sev_sorted() {
    awk -F'|' '{
        if ($1=="Critical") r=1; else if ($1=="High") r=2;
        else if ($1=="Medium") r=3; else if ($1=="Low") r=4; else r=5;
        print r "|" $0
    }' "$1" | sort -t'|' -k1,1n | cut -d'|' -f2-
}

ALERTS_DB=""

# category_for <raven-phase-label>: coarse grouping used by the report's
# findings table, independent of which specific module produced it.
category_for() {
    case "$1" in
        "Passive Recon") echo "Reconnaissance" ;;
        "Active Recon")  echo "Web" ;;
        "Deep Scan")     echo "Network" ;;
        "Vulnerability Scan") echo "Web" ;;
        "Packet Capture") echo "Network" ;;
        *) echo "General" ;;
    esac
}

# recommendation_for <title>: best-effort generic guidance by keyword.
# Known limitation: these are category-level recommendations, not a
# per-CVE remediation database — accurate enough to be useful in a
# report, not a substitute for reading the actual finding detail.
recommendation_for() {
    local t="$1"
    case "$t" in
        *"zone transfer"*|*"Zone Transfer"*)
            echo "Restrict AXFR to authorized secondary nameservers only; disable zone transfers to arbitrary clients." ;;
        *"SPF"*)
            echo "Publish an SPF record (and consider DKIM/DMARC) to reduce the domain's exposure to email spoofing." ;;
        *"FTP"*)
            echo "Disable anonymous FTP if not required; migrate to SFTP/FTPS, or restrict access by IP/firewall." ;;
        *"Telnet"*)
            echo "Disable Telnet and migrate to SSH; Telnet transmits credentials and data in cleartext." ;;
        *"open port"*)
            echo "Review whether each exposed service needs to be internet-facing; close or firewall anything not required." ;;
        *"nuclei"*|*"Vulnerability Templates"*)
            echo "Review the specific template/CVE referenced in the evidence and apply the vendor's patch or mitigation." ;;
        *"nikto"*|*"Web Server Audit"*)
            echo "Review the specific web-server misconfiguration noted in the evidence and harden per vendor guidance." ;;
        *"NSE"*|*"Scripted"*)
            echo "Review the CVE/script output in the evidence and patch or mitigate the affected service." ;;
        *) echo "Review the evidence for this finding and remediate per your organization's standard process." ;;
    esac
}

# add_alert <severity> <raven-phase> <title> <detail> [asset]
# Schema: severity|phase|title|detail|asset|category|recommendation
add_alert() {
    local sev="$1" ph="$2" title="$3" detail="$4" asset="${5:-$TARGET}"
    local cat; cat=$(category_for "$ph")
    local rec; rec=$(recommendation_for "$title")
    echo "${sev}|${ph}|${title}|${detail//|/;}|${asset}|${cat}|${rec//|/;}" >> "$ALERTS_DB"
}

init_report() {
    ALERTS_DB="${TARGET_DIR}/report/alerts.db"
    mkdir -p "${TARGET_DIR}/report"
    [ -f "$ALERTS_DB" ] || : > "$ALERTS_DB"
}

sev_color() {
    case "$1" in
        Critical) echo "#8b0000" ;;
        High)     echo "#d9534f" ;;
        Medium)   echo "#f0ad4e" ;;
        Low)      echo "#5bc0de" ;;
        *)        echo "#777777" ;;
    esac
}

csv_escape() { local s="$1"; s="${s//\"/\"\"}"; printf '"%s"' "$s"; }
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/ }"
    s="${s//$'\r'/}"
    printf '%s' "$s"
}

export_csv() {
    local out="${TARGET_DIR}/report/alerts.csv"
    {
        echo "severity,phase,title,detail,asset,category,recommendation"
        if [ -s "$ALERTS_DB" ]; then
            while IFS='|' read -r sev ph title detail asset cat rec; do
                echo "$(csv_escape "$sev"),$(csv_escape "$ph"),$(csv_escape "$title"),$(csv_escape "$detail"),$(csv_escape "$asset"),$(csv_escape "$cat"),$(csv_escape "$rec")"
            done < "$ALERTS_DB"
        fi
    } > "$out"
}

export_json() {
    local out="${TARGET_DIR}/report/alerts.json"
    local total=0
    [ -s "$ALERTS_DB" ] && total=$(wc -l < "$ALERTS_DB")
    {
        echo "{"
        echo "  \"target\": \"$(json_escape "$TARGET")\","
        echo "  \"generated\": \"$(date '+%Y-%m-%dT%H:%M:%S%z')\","
        echo "  \"raven_version\": \"${VERSION}\","
        echo "  \"alerts\": ["
        if [ "$total" -gt 0 ]; then
            local idx=0
            while IFS='|' read -r sev ph title detail asset cat rec; do
                idx=$((idx+1))
                local comma=","; [ "$idx" -eq "$total" ] && comma=""
                printf '    {"severity": "%s", "phase": "%s", "title": "%s", "detail": "%s", "asset": "%s", "category": "%s", "recommendation": "%s"}%s\n' \
                    "$(json_escape "$sev")" "$(json_escape "$ph")" "$(json_escape "$title")" "$(json_escape "$detail")" \
                    "$(json_escape "$asset")" "$(json_escape "$cat")" "$(json_escape "$rec")" "$comma"
            done < "$ALERTS_DB"
        fi
        echo "  ]"
        echo "}"
    } > "$out"
}

html_escape() {
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
    printf '%s' "$s"
}

export_markdown() {
    local out="${TARGET_DIR}/report/raven_report_${TARGET}.md"
    {
        echo "# Raven Assessment Report — ${TARGET}"
        echo "_Generated: $(date) · Raven v${VERSION}_"
        echo
        echo "## Findings"
        if [ -s "$ALERTS_DB" ]; then
            echo "| Severity | Asset | Category | Finding | Recommendation |"
            echo "|---|---|---|---|---|"
            sev_sorted "$ALERTS_DB" | while IFS='|' read -r sev _ title _ asset cat rec; do
                echo "| ${sev} | ${asset} | ${cat} | ${title} | ${rec} |"
            done
        else
            echo "_No findings recorded yet._"
        fi
    } > "$out"
}

generate_report() {
    require_target || return
    clear; banner
    init_report

    # Cover-page fields. Kept in a small file so they persist across
    # re-generations instead of being re-asked every single time.
    local meta_file="${TARGET_DIR}/report/.report_meta"
    local tester="" org=""
    [ -f "$meta_file" ] && { tester=$(sed -n '1p' "$meta_file"); org=$(sed -n '2p' "$meta_file"); }
    echo -e "${C_BOLD}── Report cover details ──${C_RESET} ${C_DIM}(blank keeps the current value)${C_RESET}"
    read -rp "Tester name [${tester:-none}]: " _t; [ -n "$_t" ] && tester="$_t"
    read -rp "Organization/client [${org:-none}]: " _o; [ -n "$_o" ] && org="$_o"
    printf '%s\n%s\n' "$tester" "$org" > "$meta_file"

    phase "Building assessment report for ${TARGET}"
    local html="${TARGET_DIR}/report/raven_report_${TARGET}.html"
    local total=0 crit=0 high=0 med=0 low=0 info_c=0

    if [ -s "$ALERTS_DB" ]; then
        while IFS='|' read -r sev _ _ _ _ _ _; do
            total=$((total+1))
            case "$sev" in
                Critical) crit=$((crit+1)) ;;
                High) high=$((high+1)) ;;
                Medium) med=$((med+1)) ;;
                Low) low=$((low+1)) ;;
                *) info_c=$((info_c+1)) ;;
            esac
        done < "$ALERTS_DB"
    fi

    local risk="Informational" risk_color="#5bc0de"
    if [ "$crit" -gt 0 ]; then risk="Critical"; risk_color="#8b0000"
    elif [ "$high" -gt 0 ]; then risk="High"; risk_color="#d9534f"
    elif [ "$med" -gt 0 ]; then risk="Medium"; risk_color="#f0ad4e"
    elif [ "$low" -gt 0 ]; then risk="Low"; risk_color="#5bc0de"
    fi

    {
        cat <<HTML
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<title>Raven Assessment Report — ${TARGET}</title>
<style>
:root{--bg:#0b0c10;--panel:#15161c;--border:#262832;--text:#e8e8ec;--muted:#8d8f9a;--accent:#d61f3a;--accent2:#6a2fb0}
*{box-sizing:border-box}
body{font-family:"Segoe UI",Arial,sans-serif;background:var(--bg);color:var(--text);margin:0;padding:0}
.cover{background:linear-gradient(135deg,#1a0a10 0%,#120a1f 60%,#0b0c10 100%);padding:56px 48px 40px;border-bottom:3px solid var(--accent)}
.cover .brand{font-size:13px;letter-spacing:4px;color:var(--accent);font-weight:700;text-transform:uppercase}
.cover h1{margin:10px 0 4px;font-size:34px;letter-spacing:1px}
.cover .sub{color:var(--muted);font-size:13px;margin-bottom:28px}
.meta-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:18px;max-width:780px}
.meta-grid div{background:rgba(255,255,255,0.03);border:1px solid var(--border);border-radius:8px;padding:12px 16px}
.meta-grid .k{font-size:10px;text-transform:uppercase;letter-spacing:1px;color:var(--muted)}
.meta-grid .v{font-size:15px;margin-top:4px;font-weight:600}
.risk-pill{display:inline-block;margin-top:18px;padding:6px 18px;border-radius:20px;font-weight:700;font-size:13px;color:#fff}
.container{padding:36px 48px}
h2{font-size:16px;letter-spacing:1px;text-transform:uppercase;color:var(--muted);border-bottom:1px solid var(--border);padding-bottom:10px;margin:36px 0 18px}
.summary{display:flex;gap:14px;flex-wrap:wrap}
.card{background:var(--panel);border-radius:10px;padding:18px 22px;min-width:110px;text-align:center;border:1px solid var(--border)}
.card .num{font-size:30px;font-weight:800} .card .lbl{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.5px;margin-top:4px}
.Critical .num{color:#ff4d5e} .High .num{color:#ff8a5c} .Medium .num{color:#ffc94d}
.Low .num{color:#5bc0de} .Info .num{color:var(--muted)}
table{width:100%;border-collapse:collapse;margin-top:6px;font-size:13px}
th,td{padding:11px 14px;text-align:left;border-bottom:1px solid var(--border);vertical-align:top}
th{background:var(--panel);color:var(--muted);text-transform:uppercase;font-size:10px;letter-spacing:.5px}
tr:hover td{background:rgba(255,255,255,0.02)}
.badge{display:inline-block;padding:3px 11px;border-radius:12px;color:#fff;font-size:11px;font-weight:700;white-space:nowrap}
.cat-tag{display:inline-block;padding:2px 9px;border-radius:5px;background:rgba(106,47,176,0.25);color:#c9a8f0;font-size:11px}
.asset{font-family:monospace;color:#9fd3ff}
.rec{color:#8fd19e}
.evidence{font-family:monospace;font-size:11px;color:var(--muted);max-width:280px;overflow-wrap:break-word}
.appendix-table td,.appendix-table th{font-size:12px}
.status-ok{color:#5fd68a} .status-failed{color:#ff6b6b} .status-skipped{color:var(--muted)}
footer{padding:22px 48px;color:#55565f;font-size:11px;border-top:1px solid var(--border);display:flex;justify-content:space-between}
.empty{color:var(--muted);font-style:italic;padding:16px 0}
</style></head><body>

<div class="cover">
  <div class="brand">RAVEN &middot; RECONNAISSANCE TOOL</div>
  <h1>Security Assessment Report</h1>
  <div class="sub">Discover / Enumerate / Analyze / Hunt</div>
  <div class="meta-grid">
    <div><div class="k">Target</div><div class="v">$(html_escape "$TARGET")</div></div>
    <div><div class="k">Scan Date</div><div class="v">$(date '+%d %b %Y, %H:%M')</div></div>
    <div><div class="k">Raven Version</div><div class="v">v${VERSION}</div></div>
    <div><div class="k">Tester</div><div class="v">$(html_escape "${tester:-—}")</div></div>
    <div><div class="k">Organization</div><div class="v">$(html_escape "${org:-—}")</div></div>
  </div>
  <div class="risk-pill" style="background:${risk_color}">Overall risk: ${risk}</div>
</div>

<div class="container">
  <h2>Executive Summary</h2>
  <div class="summary">
    <div class="card"><div class="num">${total}</div><div class="lbl">Total Findings</div></div>
    <div class="card Critical"><div class="num">${crit}</div><div class="lbl">Critical</div></div>
    <div class="card High"><div class="num">${high}</div><div class="lbl">High</div></div>
    <div class="card Medium"><div class="num">${med}</div><div class="lbl">Medium</div></div>
    <div class="card Low"><div class="num">${low}</div><div class="lbl">Low</div></div>
    <div class="card Info"><div class="num">${info_c}</div><div class="lbl">Info</div></div>
  </div>

  <h2>Findings</h2>
HTML
        if [ -s "$ALERTS_DB" ]; then
            cat <<'HTML'
  <table>
    <tr><th>Severity</th><th>Asset</th><th>Category</th><th>Finding</th><th>Evidence</th><th>Recommendation</th></tr>
HTML
            sev_sorted "$ALERTS_DB" | \
            while IFS='|' read -r sev ph title detail asset cat rec; do
                color=$(sev_color "$sev")
                printf '    <tr><td><span class="badge" style="background:%s">%s</span></td><td class="asset">%s</td><td><span class="cat-tag">%s</span></td><td><strong>%s</strong><br><span style="color:var(--muted);font-size:12px">via %s</span></td><td class="evidence">%s</td><td class="rec">%s</td></tr>\n' \
                    "$color" "$(html_escape "$sev")" "$(html_escape "$asset")" "$(html_escape "$cat")" \
                    "$(html_escape "$title")" "$(html_escape "$ph")" "$(html_escape "$detail")" "$(html_escape "$rec")"
            done
            echo "  </table>"
        else
            echo '  <div class="empty">No findings recorded yet — run Deep Scan / Vulnerability Scan first, then regenerate this report.</div>'
        fi

        cat <<'HTML'
  <h2>Appendix &middot; Modules Run</h2>
HTML
        local manifest="${TARGET_DIR}/report/modules.log"
        if [ -s "$manifest" ]; then
            echo '  <table class="appendix-table">'
            echo '    <tr><th>Phase</th><th>Module</th><th>Status</th><th>Duration</th><th>When</th></tr>'
            while IFS='|' read -r ts ph mod status elapsed; do
                local cls="status-${status}"
                printf '    <tr><td>%s</td><td>%s</td><td class="%s">%s</td><td>%s</td><td style="color:var(--muted)">%s</td></tr>\n' \
                    "$(html_escape "$ph")" "$(html_escape "$mod")" "$cls" "$(html_escape "$status")" "$(html_escape "$elapsed")" "$(html_escape "$ts")"
            done < "$manifest"
            echo '  </table>'
        else
            echo '  <div class="empty">No module run history yet for this target.</div>'
        fi

        cat <<HTML
</div>
<footer>
  <span>Generated by <strong>Raven</strong> v${VERSION} — for authorized security testing only.</span>
  <span>by z7</span>
</footer>
</body></html>
HTML
    } > "$html"

    export_csv
    export_json
    export_markdown

    ok "Report generated:"
    find_ "HTML     -> ${html}"
    find_ "CSV      -> ${TARGET_DIR}/report/alerts.csv"
    find_ "JSON     -> ${TARGET_DIR}/report/alerts.json"
    find_ "Markdown -> ${TARGET_DIR}/report/raven_report_${TARGET}.md"
    if have wkhtmltopdf; then
        info "wkhtmltopdf detected — PDF export is available but not run automatically yet (ask to enable it)."
    fi
    pause
}

# ============================================================
#  PASSIVE RECON (parallel)
# ============================================================
passive_recon() {
    require_target || return
    clear; banner
    echo -e "${C_BOLD}── Passive Recon :: ${TARGET} ──${C_RESET}\n"
    confirm_rerun "passive" "Passive Recon" || { pause; return; }
    local out="${TARGET_DIR}/passive"; mkdir -p "$out"
    init_report
    show_eta "passive"
    echo

    local f_whois f_dig f_host f_ns f_dnsrecon f_sub f_amass
    f_whois="${out}/$(mslug whois).txt";       f_dig="${out}/$(mslug dig).txt"
    f_host="${out}/$(mslug host).txt";         f_ns="${out}/$(mslug nslookup).txt"
    f_dnsrecon="${out}/$(mslug dnsrecon).txt"; f_sub="${out}/$(mslug subfinder).txt"
    f_amass="${out}/$(mslug amass).txt"

    JOB_LABELS=(); JOB_CMDS=(); JOB_OUTS=(); SKIPPED_SUMMARY=""
    have whois     && add_job "$(mname whois)"     "whois '$TARGET'" "$f_whois"     || add_skip "$(mname whois)"
    have dig       && add_job "$(mname dig)"       "for r in ${DNS_RECORD_TYPES}; do echo ==\$r==; dig '$TARGET' \$r +noall +answer; done" "$f_dig" || add_skip "$(mname dig)"
    have host      && add_job "$(mname host)"      "host -a '$TARGET'" "$f_host"     || add_skip "$(mname host)"
    # BUG FIX: `-type=any` is deprecated by RFC 8482 and many public
    # resolvers now refuse it outright, so this job failed with no
    # usable diagnostic beyond a bare exit code. Query NS and SOA
    # directly instead (always supported), and don't treat "query
    # succeeded, target just has no custom records" as a failure.
    have nslookup  && add_job "$(mname nslookup)"  "echo '== NS =='; nslookup -type=NS '$TARGET'; echo; echo '== SOA =='; nslookup -type=SOA '$TARGET'" "$f_ns" || add_skip "$(mname nslookup)"
    have dnsrecon  && add_job "$(mname dnsrecon)"  "dnsrecon -d '$TARGET' -t std" "$f_dnsrecon" || add_skip "$(mname dnsrecon)"
    have subfinder && add_job "$(mname subfinder)" "subfinder -d '$TARGET' -silent" "$f_sub" || add_skip "$(mname subfinder)"
    have amass     && add_job "$(mname amass)"     "amass enum -passive -d '$TARGET'" "$f_amass" || add_skip "$(mname amass)"

    if [ "${#JOB_LABELS[@]}" -eq 0 ]; then
        warn "No passive-recon modules installed — run install.sh first."; pause; return
    fi
    run_jobs_parallel "Passive Recon" || { pause; return; }

    if [ -f "$f_dig" ] && ! grep -qi "v=spf1" "$f_dig" 2>/dev/null; then
        add_alert "Low" "Passive Recon" "No SPF record found" "Domain may be more susceptible to email spoofing. Verify manually."
    fi
    if [ -f "$f_dnsrecon" ] && grep -qi "Zone Transfer was successful" "$f_dnsrecon" 2>/dev/null; then
        add_alert "Critical" "Passive Recon" "DNS zone transfer succeeded" "AXFR allowed from an untrusted source — full zone data exposed."
    fi

    build_passive_summary "$out"

    echo
    echo -e "${C_BOLD}Key Findings:${C_RESET}"
    local sub_count=0
    [ -f "$f_sub" ] && sub_count=$(wc -l < "$f_sub" 2>/dev/null || echo 0)
    [ "$sub_count" -gt 0 ] && find_ "${sub_count} subdomain(s) discovered -> passive/$(basename "$f_sub")"
    if [ -f "$f_dnsrecon" ] && grep -qi "Zone Transfer was successful" "$f_dnsrecon" 2>/dev/null; then
        find_ "${C_RED}DNS zone transfer SUCCEEDED (critical)${C_RESET} -> passive/$(basename "$f_dnsrecon")"
    fi
    # NOTE: this used to be `[ -f "$f_dig" ] && grep ... || find_ "No SPF
    # record found"` — the classic A&&B||C pitfall. When $f_dig didn't
    # exist (dig missing/skipped), [ -f ] failing made the WHOLE left
    # side false, so C ran unconditionally and claimed "No SPF record
    # found" even though SPF was never actually checked. Split into a
    # real if/elif so "not checked" and "checked, none found" are never
    # conflated.
    if [ ! -f "$f_dig" ]; then
        find_ "${C_DIM}SPF not checked — $(mname dig) didn't run${C_RESET}"
    elif ! grep -qi "v=spf1" "$f_dig" 2>/dev/null; then
        find_ "No SPF record found"
    fi

    mark_phase_done "passive"
    ok "Passive recon complete."
    info "Results saved to: $out"
    pause
}

build_passive_summary() {
    local out="$1"; local summary="${out}/SUMMARY.md"
    {
        echo "# Passive Recon Summary — ${TARGET}"
        echo "_Generated: $(date)_"
        echo
        echo "| Module | Output file |"
        echo "|---|---|"
        for tool in whois dig host nslookup dnsrecon subfinder amass; do
            local f="${out}/$(mslug "$tool").txt"
            [ -f "$f" ] && echo "| $(mname "$tool") | $(basename "$f") |"
        done
    } > "$summary"
}

# ============================================================
#  ACTIVE RECON (parallel)
# ============================================================
active_recon() {
    require_target || return
    clear; banner
    echo -e "${C_BOLD}── Active Recon :: ${TARGET} ──${C_RESET}\n"
    confirm_rerun "active" "Active Recon" || { pause; return; }
    local out="${TARGET_DIR}/active"; mkdir -p "$out"
    local sub_list="${TARGET_DIR}/passive/$(mslug subfinder).txt"
    local f_live="${out}/$(mslug httpx).txt"
    local f_webfp="${out}/$(mslug whatweb).txt"
    init_report
    show_eta "active"
    echo

    # BUG FIX: httpx was only ever probing subdomains.txt (subfinder's
    # output). The bare target itself (e.g. example.com, not
    # www.example.com) was NEVER in that list, so if subfinder found
    # few/no live subdomains, httpx correctly reported 0 — while Web
    # Fingerprint (whatweb), run separately straight against $TARGET,
    # succeeded. Key Findings then wrongly read as "target is down"
    # when it plainly wasn't. Fix: build a combined, de-duplicated
    # probe list = $TARGET + every discovered subdomain, every time.
    local probe_list="${out}/.probe-list.tmp"
    { echo "$TARGET"; [ -f "$sub_list" ] && cat "$sub_list"; } | awk 'NF' | sort -u > "$probe_list"

    JOB_LABELS=(); JOB_CMDS=(); JOB_OUTS=(); SKIPPED_SUMMARY=""
    if have httpx; then
        add_job "$(mname httpx)" "httpx -l '$probe_list' ${HTTPX_OPTS}" "$f_live"
    else
        add_skip "$(mname httpx)"
        warn "$(mname httpx) skipped (not installed)."
    fi
    have whatweb && add_job "$(mname whatweb)" "whatweb '$TARGET'" "$f_webfp" || add_skip "$(mname whatweb)"

    if [ "${#JOB_LABELS[@]}" -gt 0 ]; then
        run_jobs_parallel "Active Recon" || { rm -f "$probe_list"; pause; return; }
    fi
    rm -f "$probe_list"

    echo
    echo -e "${C_BOLD}Key Findings:${C_RESET}"
    # RULE: exit code alone is not proof of success — verify the output
    # file actually has content before reporting a count. httpx exits 0
    # even when it finds nothing, so an empty file here is reported
    # honestly as "0 live hosts" rather than silently trusted as such
    # without having actually looked.
    if have httpx; then
        if [ -s "$f_live" ]; then
            local live_count
            live_count=$(wc -l < "$f_live" 2>/dev/null)
            find_ "${live_count} live host(s) responded -> active/$(basename "$f_live")"
        else
            find_ "${C_YELLOW}$(mname httpx) produced no output — verify manually (target DNS/connectivity, or a WAF blocking probes)${C_RESET}"
        fi
    fi

    mark_phase_done "active"
    ok "Active recon complete."
    info "Results saved to: $out"
    pause
}

# ============================================================
#  DEEP NETWORK SCAN — nmap + masscan + NSE + scapy
# ============================================================
deep_scan() {
    require_target || return
    CURRENT_PHASE_LABEL="Deep Scan"
    clear; banner
    echo -e "${C_BOLD}── Deep Network Scan :: ${TARGET} ──${C_RESET}\n"
    warn "This phase touches the live target directly."
    read -rp "Confirmed your program's policy allows active/port scanning? [y/N]: " conf
    [[ "$conf" =~ ^[Yy]$ ]] || { warn "Skipped."; pause; return; }
    confirm_rerun "deep" "Deep Network Scan" || { pause; return; }

    local out="${TARGET_DIR}/deepscan"; mkdir -p "$out"
    local f_masscan="${out}/$(mslug masscan).txt"
    local f_nmap="${out}/$(mslug nmap).txt"
    local f_nse="${out}/scripted-vulnerability-checks.txt"
    local f_scapy="${out}/$(mslug python3).txt"
    init_report
    show_eta "deep"
    echo

    if have masscan; then
        read -rp "Run $(mname masscan) first? (needs sudo) [y/N]: " mc
        if [[ "$mc" =~ ^[Yy]$ ]]; then
            run_step "$(mname masscan)" "sudo masscan '$TARGET' -p${MASSCAN_PORTS} --rate ${MASSCAN_RATE}" "$f_masscan" || { pause; return; }
        fi
    fi

    if have nmap; then
        run_step "$(mname nmap)" "nmap -sV ${NMAP_TIMING} ${NMAP_PORTS_OPT} '$TARGET'" "$f_nmap" || { pause; return; }
        read -rp "Run scripted vulnerability checks too (slower)? [y/N]: " ns
        if [[ "$ns" =~ ^[Yy]$ ]]; then
            run_step "Scripted Vulnerability Checks" "nmap -sV --script vuln '$TARGET'" "$f_nse" || { pause; return; }
        fi
    fi

    if have python3 && python3 -c "import scapy" 2>/dev/null; then
        read -rp "Run $(mname python3) sweep? [y/N]: " sc
        if [[ "$sc" =~ ^[Yy]$ ]]; then
            run_step "$(mname python3)" "python3 -c \"
from scapy.all import sr1, IP, ICMP
import socket
try:
    ip = socket.gethostbyname('$TARGET')
    pkt = IP(dst=ip)/ICMP()
    r = sr1(pkt, timeout=2, verbose=0)
    print('Host', ip, 'responded' if r else 'did not respond to ICMP')
except Exception as e:
    print('error:', e)
\"" "$f_scapy" || { pause; return; }
        fi
    fi

    local open_count=0 ftp_hit=0 telnet_hit=0 nse_hit=0
    if [ -f "$f_nmap" ]; then
        # NOTE: no `|| echo 0` here on purpose. grep -c already prints
        # "0" (and only exits 1) when nothing matches, so appending
        # `|| echo 0` printed a SECOND "0" on no-match, leaving $open_count
        # as the two-line string "0\n0" and breaking every -gt/-eq test
        # that read it afterwards ("integer expression expected").
        open_count=$(grep -c "/tcp.*open" "$f_nmap" 2>/dev/null)
        [ "$open_count" -gt 0 ] && add_alert "Info" "Deep Scan" "${open_count} open port(s) detected" "See $(basename "$f_nmap") for full service/version details."
        grep -qi "21/tcp.*open.*ftp" "$f_nmap" && { add_alert "Medium" "Deep Scan" "FTP service exposed" "Unencrypted FTP found open — check for anonymous login."; ftp_hit=1; }
        grep -qi "23/tcp.*open" "$f_nmap" && { add_alert "High" "Deep Scan" "Telnet service exposed" "Unencrypted remote admin protocol — high risk if internet-facing."; telnet_hit=1; }
    fi
    if [ -f "$f_nse" ] && grep -qi "VULNERABLE" "$f_nse"; then
        add_alert "High" "Deep Scan" "Scripted checks flagged vulnerable service(s)" "Review $(basename "$f_nse") for CVE details."
        nse_hit=1
    fi

    echo
    echo -e "${C_BOLD}Key Findings:${C_RESET}"
    [ "$open_count" -gt 0 ] && find_ "${open_count} open port(s) -> deepscan/$(basename "$f_nmap")"
    [ "$ftp_hit" -eq 1 ] && find_ "${C_YELLOW}FTP exposed (medium)${C_RESET}"
    [ "$telnet_hit" -eq 1 ] && find_ "${C_RED}Telnet exposed (high)${C_RESET}"
    [ "$nse_hit" -eq 1 ] && find_ "${C_RED}Scripted checks flagged a vulnerable service (high)${C_RESET} -> deepscan/$(basename "$f_nse")"
    [ "$open_count" -eq 0 ] && [ "$nse_hit" -eq 0 ] && find_ "No notable issues surfaced by heuristics — review raw output for full detail."

    mark_phase_done "deep"
    ok "Deep scan complete."
    info "Results saved to: $out"
    pause
}

# ============================================================
#  VULNERABILITY SCAN — nikto + nuclei (parallel) + GVM
# ============================================================
vuln_scan() {
    require_target || return
    clear; banner
    echo -e "${C_BOLD}── Vulnerability Scan :: ${TARGET} ──${C_RESET}\n"
    warn "Vulnerability scanning is active testing — confirm scope/policy allows it."
    read -rp "Confirmed? [y/N]: " conf
    [[ "$conf" =~ ^[Yy]$ ]] || { warn "Skipped."; pause; return; }
    confirm_rerun "vuln" "Vulnerability Scan" || { pause; return; }

    local out="${TARGET_DIR}/vulnscan"; mkdir -p "$out"
    local f_nikto="${out}/$(mslug nikto).txt"
    local f_nuclei="${out}/$(mslug nuclei).txt"
    local f_gvm="${out}/$(mslug gvm-cli).txt"
    init_report
    show_eta "vuln"
    echo

    JOB_LABELS=(); JOB_CMDS=(); JOB_OUTS=(); SKIPPED_SUMMARY=""
    have nikto  && add_job "$(mname nikto)"  "nikto -h 'https://$TARGET'" "$f_nikto"   || add_skip "$(mname nikto)"
    have nuclei && add_job "$(mname nuclei)" "nuclei -u 'https://$TARGET' ${NUCLEI_OPTS}" "$f_nuclei" || add_skip "$(mname nuclei)"

    if [ "${#JOB_LABELS[@]}" -gt 0 ]; then
        run_jobs_parallel "Vulnerability Scan" || { pause; return; }
    fi

    if have gvm-cli; then
        info "$(mname gvm-cli) detected — full scans require a configured task."
        echo "Run manually via gvm-cli once a scan target/task is configured." >> "$f_gvm"
    else
        warn "$(mname gvm-cli) not installed (optional, heavier engine)."
    fi

    if [ -s "$f_nuclei" ]; then
        while IFS= read -r line; do
            sev=$(echo "$line" | grep -oE '\[(critical|high|medium|low|info)\]' | tr -d '[]' | head -1)
            sev_cap=$(echo "${sev^}")
            [ -z "$sev_cap" ] && sev_cap="Info"
            add_alert "$sev_cap" "Vulnerability Scan" "$(mname nuclei) finding" "$line"
        done < "$f_nuclei"
    fi

    local nikto_hits=0
    if [ -s "$f_nikto" ]; then
        while read -r line; do
            add_alert "Medium" "Vulnerability Scan" "$(mname nikto) finding" "$line"
            nikto_hits=$((nikto_hits+1))
        done < <(grep -i "OSVDB\|vulnerable" "$f_nikto")
    fi

    local nuclei_hits=0
    [ -f "$f_nuclei" ] && nuclei_hits=$(wc -l < "$f_nuclei" 2>/dev/null || echo 0)

    echo
    echo -e "${C_BOLD}Key Findings:${C_RESET}"
    [ "$nikto_hits" -gt 0 ] && find_ "${nikto_hits} $(mname nikto) finding(s) -> vulnscan/$(basename "$f_nikto")"
    [ "$nuclei_hits" -gt 0 ] && find_ "${nuclei_hits} $(mname nuclei) finding(s) -> vulnscan/$(basename "$f_nuclei")"
    [ "$nikto_hits" -eq 0 ] && [ "$nuclei_hits" -eq 0 ] && find_ "No findings flagged on this pass."

    mark_phase_done "vuln"
    ok "Vulnerability scan complete."
    info "Results saved to: $out"
    pause
}

pcap_capture() {
    require_target || return
    CURRENT_PHASE_LABEL="Packet Capture"
    clear; banner
    echo -e "${C_BOLD}── Packet Capture ──${C_RESET}\n"
    warn "Only capture traffic you generate/control — not third-party network sniffing."
    if ! have tshark; then
        warn "$(mname tshark) not installed."
        pause; return
    fi

    # BUG FIX (invalid interface silently accepted): the old regex only
    # checked that the TEXT looked interface-name-shaped ("etho" passes
    # that check fine) — it never checked the interface actually
    # exists. Ask tshark itself what it can see (`tshark -D`), which is
    # more accurate than `ip link show` since it's the exact same
    # capture-interface list tshark will use.
    local iface_list; iface_list=$(tshark -D 2>/dev/null | sed -E 's/^[0-9]+\.\s*//; s/\s.*$//')
    if [ -z "$iface_list" ]; then
        err "Could not list capture interfaces (try running with sudo/as a user in the 'wireshark' group)."
        pause; return
    fi
    echo "Available interfaces:"
    echo "$iface_list" | sed 's/^/  - /'
    echo
    read -rp "Interface: " iface
    read -rp "Duration (seconds): " dur

    if ! grep -qxF "$iface" <<< "$iface_list"; then
        err "'$iface' is not a capture interface tshark can see. Pick one from the list above. Aborted."
        pause; return
    fi
    if ! [[ "$dur" =~ ^[0-9]{1,5}$ ]] || [ "$dur" -eq 0 ]; then
        err "Duration must be a positive whole number of seconds. Aborted."
        pause; return
    fi

    local out="${TARGET_DIR}/pcap/capture_$(date +%s).pcap"
    local logf="${TARGET_DIR}/pcap/$(mslug tshark)-log.txt"
    run_step "$(mname tshark)" "timeout '$dur' tshark -i '$iface' -w '$out'" "$logf"

    # BUG FIX (silent "success" with zero packets): exit code 0 from
    # tshark just means it ran, not that anything was actually
    # captured (wrong interface with no traffic, insufficient capture
    # permissions, etc. all look identical from the exit code alone).
    # Read the packet count back OUT of the file itself before calling
    # this a success, per the "verify real output" rule.
    local pkt_count=0
    if [ -f "$out" ]; then
        pkt_count=$(tshark -r "$out" 2>/dev/null | wc -l)
    fi
    if [ "$pkt_count" -gt 0 ]; then
        ok "Captured ${pkt_count} packet(s) -> $out"
    else
        err "0 packets captured — the file exists but is empty. Common causes: no traffic occurred on '${iface}' during the ${dur}s window, or tshark lacks capture permissions (try: sudo setcap cap_net_raw,cap_net_admin+eip \$(which dumpcap), or run Raven with sudo)."
        rm -f "$out"
    fi
    pause
}

full_auto() {
    require_target || return
    clear; banner
    if ! have tmux; then err "tmux not installed."; pause; return; fi
    local session="raven_${TARGET//./_}"
    phase "Launching full pipeline for ${TARGET} (tmux session: ${session})"
    tmux new-session -d -s "$session" -n recon
    tmux send-keys -t "${session}:recon" "bash '${BASE_DIR}/raven.sh' --internal-passive '${TARGET}'" C-m
    ok "Attach with: tmux attach -t ${session}"
    pause
}

plugins_menu() {
    clear; banner
    echo -e "${C_BOLD}── Plugins ──${C_RESET}\n"
    echo "Drop executable .sh scripts into: $PLUGIN_DIR  (receive \$TARGET, \$TARGET_DIR)"
    shopt -s nullglob; local found=0
    for p in "$PLUGIN_DIR"/*.sh; do found=1; echo " - $(basename "$p")"; done
    shopt -u nullglob
    [ "$found" -eq 0 ] && warn "No plugins yet."
    pause
}

# show_results (menu option 8): a boxed "Key Findings" summary, not a
# raw file-path dump. Every section uses module names (never raw tool
# names) and shows a friendly message when that module hasn't run yet.
show_results() {
    clear; banner
    echo -e "${C_BOLD}── Results ──${C_RESET}\n"
    if [ -z "$TARGET" ]; then
        if [ -d "$RESULTS_DIR" ] && [ -n "$(ls -A "$RESULTS_DIR" 2>/dev/null)" ]; then
            echo "Previously scanned targets:"
            ls -1 "$RESULTS_DIR"
        else
            info "No targets scanned yet — use option 1 to set one."
        fi
        pause; return
    fi

    local w=56
    box_top " KEY FINDINGS — ${TARGET} " "$w"
    box_line "" "$w"

    local sub_file="${TARGET_DIR}/passive/$(mslug subfinder).txt"
    local sub_count=0
    [ -f "$sub_file" ] && sub_count=$(wc -l < "$sub_file" 2>/dev/null || echo 0)
    if [ "$sub_count" -gt 0 ]; then
        box_line "  ${C_GREEN}${sub_count}${C_RESET} subdomain(s) found" "$w"
    else
        box_line "  ${C_DIM}No subdomains discovered yet (run Passive Recon)${C_RESET}" "$w"
    fi

    local live_file="${TARGET_DIR}/active/$(mslug httpx).txt"
    local live_count=0
    [ -f "$live_file" ] && live_count=$(wc -l < "$live_file" 2>/dev/null || echo 0)
    if [ "$live_count" -gt 0 ]; then
        box_line "  ${C_GREEN}${live_count}${C_RESET} live host(s) responded" "$w"
    else
        box_line "  ${C_DIM}No live hosts probed yet (run Active Recon)${C_RESET}" "$w"
    fi

    local nmap_file="${TARGET_DIR}/deepscan/$(mslug nmap).txt"
    local open_count=0
    [ -f "$nmap_file" ] && open_count=$(grep -c "/tcp.*open" "$nmap_file" 2>/dev/null)
    if [ "$open_count" -gt 0 ]; then
        box_line "  ${C_YELLOW}${open_count}${C_RESET} open port(s)/service(s)" "$w"
    else
        box_line "  ${C_DIM}No port scan run yet (run Deep Network Scan)${C_RESET}" "$w"
    fi

    local webfp_file="${TARGET_DIR}/active/$(mslug whatweb).txt"
    if [ -s "$webfp_file" ]; then
        box_line "  Technologies fingerprinted -> active/$(basename "$webfp_file")" "$w"
    else
        box_line "  ${C_DIM}No technology fingerprint yet${C_RESET}" "$w"
    fi

    box_line "" "$w"
    box_line "  ${C_BOLD}Vulnerabilities by severity${C_RESET}" "$w"
    local db="${TARGET_DIR}/report/alerts.db" found_alerts=0 sev c
    if [ -s "$db" ]; then
        for sev in Critical High Medium Low Info; do
            c=$(grep -c "^${sev}|" "$db" 2>/dev/null)
            [ "$c" -gt 0 ] && { box_line "   ${sev}: ${c}" "$w"; found_alerts=1; }
        done
    fi
    [ "$found_alerts" -eq 0 ] && box_line "  ${C_DIM}No vulnerabilities flagged yet${C_RESET}" "$w"

    box_line "" "$w"
    box_bottom "$w"

    local st; st=$(state_file)
    if [ -f "$st" ]; then
        echo; echo -e "${C_DIM}Phases completed:${C_RESET}"
        while IFS='=' read -r k v; do echo "  - $k: $v"; done < "$st"
    fi
    echo
    echo -e "${C_DIM}Raw output files live under: ${TARGET_DIR}${C_RESET}"
    pause
}

options_menu() {
    clear; banner
    echo "1) Edit scope.txt  2) Edit raven.conf  3) Clear session  4) View log  0) Back"
    read -rp "> " o
    case "$o" in
        1) ${EDITOR:-nano} "$SCOPE_FILE" ;;
        2) ${EDITOR:-nano} "$CONFIG_FILE"; load_config; ok "Config reloaded." ;;
        3) rm -f "$SESSION_FILE"; TARGET=""; TARGET_DIR=""; ok "Cleared." ;;
        4) less "$LOG_FILE" 2>/dev/null || cat "$LOG_FILE" ;;
    esac
    pause
}

about_menu() {
    clear; banner
    cat <<EOF
Raven v${VERSION} — recon & assessment orchestrator. By z7.

Raven runs its recon, scanning and vulnerability-check modules
(Domain Registration Lookup, DNS Reconnaissance Sweep, Subdomain
Enumeration, Live Host Probe, Port & Service Scan, Vulnerability
Templates, Web Server Audit, Packet Capture, ...) behind one
consistent menu. It installs nothing itself — see install.sh to
fetch what each module needs. Run with --debug to see the real
underlying tool name next to each module on the dependency screen.

HOW TO USE
 1) Option 1: set a target domain (add it to scope.txt first). Target
    input is validated — only valid hostnames/IPs are accepted.
 2) Option 10: check which underlying tools are installed.
 3) Run phases in order: Passive Recon -> Active Recon -> Deep Scan
    -> Vulnerability Scan. Independent tools inside Passive/Active/
    Vuln phases run in PARALLEL for speed. Deep Scan and Vuln Scan
    ask for an explicit y/N confirmation because they touch the
    live target.
 4) If a phase already ran for this target, Raven asks before
    re-running it (option 8 shows what's completed and when).
 5) Option 11: generate the report — HTML, CSV and JSON, all built
    from the alerts collected across every phase you ran.
 6) Option 12 -> Edit raven.conf to tune nmap ports/timing, nuclei
    severity filters, masscan rate, etc. without touching the script.

Press Ctrl+C at any point during a running step to interrupt safely —
Raven saves whatever partial output exists, then asks if you want to
set a new target right away instead of just dumping you at the menu.

Pass --no-color to disable ANSI colors, or set NO_COLOR=1.

Only run against targets you are explicitly authorized to test.
EOF
    pause
}

main_menu() {
    clear; banner
    ui_main_menu
    read -rp "Select option: " choice
    case "$choice" in
        1) target_selection ;;  2) passive_recon ;;   3) active_recon ;;
        4) deep_scan ;;          5) vuln_scan ;;        6) pcap_capture ;;
        7) full_auto ;;          8) show_results ;;     9) plugins_menu ;;
        10) check_dependencies ;; 11) generate_report ;; 12) options_menu ;;
        13) about_menu ;;        14) echo "Bye."; exit 0 ;;
        q|Q) echo "Bye."; exit 0 ;;
        h|H) about_menu ;;
        *) warn "Invalid option."; sleep 1 ;;
    esac
}

load_config

if [ "$1" == "--internal-passive" ]; then
    TARGET="$2"; TARGET_DIR="${RESULTS_DIR}/${TARGET}"
    mkdir -p "$TARGET_DIR/passive"; init_report; passive_recon; exit 0
fi

# ---------- first-run disclaimer (Phase 7 safety requirement) ----------
DISCLAIMER_FLAG="${BASE_DIR}/.disclaimer_accepted"
if [ ! -f "$DISCLAIMER_FLAG" ]; then
    clear
    cat <<EOF
${C_BOLD}Raven — authorized security testing only${C_RESET}

Only run Raven against systems you are explicitly authorized to
test: your own infrastructure, or a program/client that has given
written permission (e.g. a bug bounty program's in-scope assets).

Every active module (Deep Network Scan, Vulnerability Scan, Packet
Capture) will separately ask you to confirm scope/authorization
before it runs. This notice is shown once.
EOF
    read -rp "Type 'yes' to continue: " _ack
    if [ "$_ack" != "yes" ]; then
        echo "Exiting."; exit 1
    fi
    touch "$DISCLAIMER_FLAG"
fi

load_session
while true; do main_menu; done
