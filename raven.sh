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

# ---------- dependency map (used by lib/ui.sh's dep summary too) ----------
declare -A TOOLS=(
    [whois]="Passive"       [dig]="Passive"        [host]="Passive"
    [nslookup]="Passive"    [dnsrecon]="Passive"    [subfinder]="Passive"
    [amass]="Passive/Active" [recon-ng]="Passive"   [spiderfoot]="Passive"
    [httpx]="Active"        [whatweb]="Active"
    [nmap]="Deep Scan"      [masscan]="Deep Scan"   [python3]="Deep Scan (scapy)"
    [nikto]="Vuln Scan"     [nuclei]="Vuln Scan"    [gvm-cli]="Vuln Scan (GVM)"
    [tshark]="Packet Capture" [tmux]="Full Auto"
)

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
    eval "$cmd" > "$outfile" 2>>"$LOG_FILE"
    local rc=$?
    t1=$(date +%s)
    elapsed=$((t1 - t0))
    log "EXIT($rc): $cmd (${elapsed}s)"
    if [ "$INTERRUPTED" -eq 1 ]; then
        INTERRUPTED=0
        return 130
    fi
    if [ $rc -eq 0 ]; then
        ok "$label — done. ($(human_time "$elapsed"))"
    else
        warn "$label — finished with warnings in $(human_time "$elapsed") (see raven.log)."
    fi
    return $rc
}

# ============================================================
#  PARALLEL JOB RUNNER — independent tools in one phase run
#  concurrently instead of one-after-another.
# ============================================================
JOB_LABELS=(); JOB_CMDS=(); JOB_OUTS=()
add_job() { JOB_LABELS+=("$1"); JOB_CMDS+=("$2"); JOB_OUTS+=("$3"); }

run_jobs_parallel() {
    local n="${#JOB_LABELS[@]}"
    [ "$n" -eq 0 ] && return 0
    phase "Running $n module(s) in parallel..."
    log "PARALLEL BATCH START ($n jobs)"

    local tmpdir; tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/raven.XXXXXX")
    local -a tfiles=() pids=()
    local i cap="${MAX_PARALLEL_JOBS:-6}"
    local running=0

    for i in "${!JOB_LABELS[@]}"; do
        local tfile="${tmpdir}/job_${i}.time"
        tfiles+=("$tfile")
        (
            t0=$(date +%s)
            eval "${JOB_CMDS[$i]}" > "${JOB_OUTS[$i]}" 2>>"$LOG_FILE"
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
    while true; do
        local alive=0
        for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
        [ "$alive" -eq 0 ] && break
        printf "\r${C_CYAN}[%c]${C_RESET} working... " "${spin:si%4:1}"
        si=$((si + 1))
        sleep 0.2
        [ "$INTERRUPTED" -eq 1 ] && break
    done
    printf "\r\033[K"
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
        if [ "$rc" -eq 0 ]; then
            ok "${JOB_LABELS[$i]} — done. ($(human_time "$elapsed"))"
        else
            warn "${JOB_LABELS[$i]} — finished with warnings in $(human_time "$elapsed")."
        fi
    done
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

target_selection() {
    clear; banner
    echo -e "${C_BOLD}── Target Selection ──${C_RESET}\n"
    if [ -s "$SCOPE_FILE" ]; then
        echo -e "${C_DIM}Current scope entries:${C_RESET}"; nl -ba "$SCOPE_FILE"
    else
        warn "Scope file empty. Add authorized domains first (wildcards like *.example.com allowed)."
    fi
    echo
    read -rp "Add a domain to scope? (blank to skip): " ns
    if [ -n "$ns" ]; then
        if is_valid_target "$ns"; then
            echo "$ns" >> "$SCOPE_FILE"; ok "Added '$ns' to scope."
        else
            err "'$ns' doesn't look like a valid domain/IP — not added."
        fi
    fi
    echo
    read -rp "Enter target domain to work on: " t
    [ -z "$t" ] && { warn "No target entered."; pause; return; }
    if ! is_valid_target "$t"; then
        err "'$t' contains characters that aren't valid in a domain/IP (letters, digits, dots, hyphens only). Aborted for safety."
        pause; return
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
    echo -e "${C_BOLD}── Dependency Check ──${C_RESET}\n"
    local missing=()
    for tool in "${!TOOLS[@]}"; do
        if have "$tool"; then
            printf "  ${C_GREEN}%-12s READY${C_RESET}   %s\n" "$tool" "${TOOLS[$tool]}"
        else
            printf "  ${C_RED}%-12s MISSING${C_RESET}  %s\n" "$tool" "${TOOLS[$tool]}"
            missing+=("$tool")
        fi
    done
    ui_refresh_dep_summary
    echo
    [ ${#missing[@]} -eq 0 ] && ok "All tools ready." || warn "Missing: ${missing[*]} (that step auto-skips and logs it). Run install.sh to fetch them."
    pause
}

# ============================================================
#  REPORT ENGINE (ZAP-style alerts: HTML + CSV + JSON)
# ============================================================
ALERTS_DB=""
add_alert() {
    local sev="$1" ph="$2" title="$3" detail="$4"
    echo "${sev}|${ph}|${title}|${detail//|/;}" >> "$ALERTS_DB"
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
        echo "severity,phase,title,detail"
        if [ -s "$ALERTS_DB" ]; then
            while IFS='|' read -r sev ph title detail; do
                echo "$(csv_escape "$sev"),$(csv_escape "$ph"),$(csv_escape "$title"),$(csv_escape "$detail")"
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
            while IFS='|' read -r sev ph title detail; do
                idx=$((idx+1))
                local comma=","; [ "$idx" -eq "$total" ] && comma=""
                printf '    {"severity": "%s", "phase": "%s", "title": "%s", "detail": "%s"}%s\n' \
                    "$(json_escape "$sev")" "$(json_escape "$ph")" "$(json_escape "$title")" "$(json_escape "$detail")" "$comma"
            done < "$ALERTS_DB"
        fi
        echo "  ]"
        echo "}"
    } > "$out"
}

generate_report() {
    require_target || return
    clear; banner
    phase "Building assessment report for ${TARGET}"
    init_report
    local html="${TARGET_DIR}/report/raven_report_${TARGET}.html"
    local total=0 crit=0 high=0 med=0 low=0 info_c=0

    if [ -s "$ALERTS_DB" ]; then
        while IFS='|' read -r sev _ _ _; do
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

    {
        cat <<HTML
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<title>Raven Report — ${TARGET}</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;background:#0f1115;color:#e6e6e6;margin:0;padding:0}
header{background:#1a1d24;padding:24px 32px;border-bottom:3px solid #6a5acd}
header h1{margin:0;font-size:22px} header p{margin:4px 0 0;color:#9a9ca3;font-size:13px}
.container{padding:24px 32px}
.summary{display:flex;gap:16px;margin-bottom:24px;flex-wrap:wrap}
.card{background:#1a1d24;border-radius:8px;padding:16px 20px;min-width:110px;text-align:center;border:1px solid #2a2d35}
.card .num{font-size:28px;font-weight:700} .card .lbl{font-size:12px;color:#9a9ca3;text-transform:uppercase}
.Critical .num{color:#8b0000} .High .num{color:#d9534f} .Medium .num{color:#f0ad4e}
.Low .num{color:#5bc0de} .Info .num{color:#9a9ca3}
table{width:100%;border-collapse:collapse;margin-top:8px}
th,td{padding:10px 12px;text-align:left;border-bottom:1px solid #2a2d35;font-size:13px}
th{background:#1a1d24;color:#9a9ca3;text-transform:uppercase;font-size:11px}
.badge{display:inline-block;padding:3px 10px;border-radius:12px;color:#fff;font-size:11px;font-weight:600}
.phase-tag{color:#6a5acd;font-weight:600}
footer{padding:16px 32px;color:#555;font-size:11px}
</style></head><body>
<header>
  <h1>RAVEN Assessment Report</h1>
  <p>Target: ${TARGET} &nbsp;|&nbsp; Generated: $(date)</p>
</header>
<div class="container">
  <div class="summary">
    <div class="card"><div class="num">${total}</div><div class="lbl">Total Alerts</div></div>
    <div class="card Critical"><div class="num">${crit}</div><div class="lbl">Critical</div></div>
    <div class="card High"><div class="num">${high}</div><div class="lbl">High</div></div>
    <div class="card Medium"><div class="num">${med}</div><div class="lbl">Medium</div></div>
    <div class="card Low"><div class="num">${low}</div><div class="lbl">Low</div></div>
    <div class="card Info"><div class="num">${info_c}</div><div class="lbl">Info</div></div>
  </div>
  <table>
    <tr><th>Severity</th><th>Phase</th><th>Finding</th><th>Detail</th></tr>
HTML
        if [ -s "$ALERTS_DB" ]; then
            sort -t'|' -k1,1 -r "$ALERTS_DB" | \
            while IFS='|' read -r sev ph title detail; do
                color=$(sev_color "$sev")
                echo "<tr><td><span class=\"badge\" style=\"background:${color}\">${sev}</span></td><td class=\"phase-tag\">${ph}</td><td>${title}</td><td>${detail}</td></tr>"
            done
        else
            echo "<tr><td colspan=4>No alerts recorded yet — run Deep Scan / Vulnerability Scan first.</td></tr>"
        fi
        cat <<HTML
  </table>
</div>
<footer>Generated by Raven v${VERSION} — by z7 — for authorized security testing only.</footer>
</body></html>
HTML
    } > "$html"

    export_csv
    export_json

    ok "Report generated:"
    find_ "HTML -> ${html}"
    find_ "CSV  -> ${TARGET_DIR}/report/alerts.csv"
    find_ "JSON -> ${TARGET_DIR}/report/alerts.json"
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

    JOB_LABELS=(); JOB_CMDS=(); JOB_OUTS=()
    have whois     && add_job "Looking up domain registration"      "whois '$TARGET'" "${out}/whois.txt"
    have dig       && add_job "Resolving DNS records"                "for r in ${DNS_RECORD_TYPES}; do echo ==\$r==; dig '$TARGET' \$r +noall +answer; done" "${out}/dig_records.txt"
    have host      && add_job "Cross-checking host records"          "host -a '$TARGET'" "${out}/host.txt"
    have nslookup  && add_job "Querying nameservers directly"        "nslookup -type=any '$TARGET'" "${out}/nslookup.txt"
    have dnsrecon  && add_job "Running DNS reconnaissance sweep"     "dnsrecon -d '$TARGET' -t std" "${out}/dnsrecon.txt"
    have subfinder && add_job "Enumerating subdomains (passive)"     "subfinder -d '$TARGET' -silent" "${out}/subdomains.txt"
    have amass     && add_job "Cross-referencing subdomain sources"  "amass enum -passive -d '$TARGET'" "${out}/subdomains_amass.txt"

    if [ "${#JOB_LABELS[@]}" -eq 0 ]; then
        warn "No passive-recon tools installed — run install.sh first."; pause; return
    fi
    run_jobs_parallel || { pause; return; }

    if [ -f "${out}/dig_records.txt" ] && ! grep -qi "v=spf1" "${out}/dig_records.txt" 2>/dev/null; then
        add_alert "Low" "Passive Recon" "No SPF record found" "Domain may be more susceptible to email spoofing. Verify manually."
    fi
    if [ -f "${out}/dnsrecon.txt" ] && grep -qi "Zone Transfer was successful" "${out}/dnsrecon.txt" 2>/dev/null; then
        add_alert "Critical" "Passive Recon" "DNS zone transfer succeeded" "AXFR allowed from an untrusted source — full zone data exposed."
    fi

    build_passive_summary "$out"

    echo
    echo -e "${C_BOLD}Key Findings:${C_RESET}"
    local sub_count=0
    [ -f "${out}/subdomains.txt" ] && sub_count=$(wc -l < "${out}/subdomains.txt" 2>/dev/null || echo 0)
    [ "$sub_count" -gt 0 ] && find_ "${sub_count} subdomain(s) discovered -> passive/subdomains.txt"
    if [ -f "${out}/dnsrecon.txt" ] && grep -qi "Zone Transfer was successful" "${out}/dnsrecon.txt" 2>/dev/null; then
        find_ "${C_RED}DNS zone transfer SUCCEEDED (critical)${C_RESET} -> passive/dnsrecon.txt"
    fi
    [ -f "${out}/dig_records.txt" ] && grep -qi "v=spf1" "${out}/dig_records.txt" 2>/dev/null || find_ "No SPF record found"

    mark_phase_done "passive"
    ok "Passive recon complete."
    pause
}

build_passive_summary() {
    local out="$1"; local summary="${out}/SUMMARY.md"
    {
        echo "# Passive Recon Summary — ${TARGET}"
        echo "_Generated: $(date)_"
        echo
        echo "| Phase | Output file |"
        echo "|---|---|"
        for f in whois.txt dig_records.txt host.txt nslookup.txt dnsrecon.txt subdomains.txt subdomains_amass.txt; do
            [ -f "${out}/${f}" ] && echo "| ${f%.txt} | ${f} |"
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
    local sub_list="${TARGET_DIR}/passive/subdomains.txt"
    init_report
    show_eta "active"
    echo

    JOB_LABELS=(); JOB_CMDS=(); JOB_OUTS=()
    if have httpx && [ -s "$sub_list" ]; then
        add_job "Probing live hosts" "httpx -l '$sub_list' ${HTTPX_OPTS}" "${out}/live_hosts.txt"
    else
        warn "Live-host probing skipped (run Passive Recon first, and ensure httpx is installed)."
    fi
    have whatweb && add_job "Fingerprinting web technologies" "whatweb '$TARGET'" "${out}/whatweb.txt"

    if [ "${#JOB_LABELS[@]}" -gt 0 ]; then
        run_jobs_parallel || { pause; return; }
    fi

    echo
    echo -e "${C_BOLD}Key Findings:${C_RESET}"
    if [ -f "${out}/live_hosts.txt" ]; then
        local live_count
        live_count=$(wc -l < "${out}/live_hosts.txt" 2>/dev/null || echo 0)
        find_ "${live_count} live host(s) responded -> active/live_hosts.txt"
    fi

    mark_phase_done "active"
    ok "Active recon complete."
    pause
}

# ============================================================
#  DEEP NETWORK SCAN — nmap + masscan + NSE + scapy
# ============================================================
deep_scan() {
    require_target || return
    clear; banner
    echo -e "${C_BOLD}── Deep Network Scan :: ${TARGET} ──${C_RESET}\n"
    warn "This phase touches the live target directly."
    read -rp "Confirmed your program's policy allows active/port scanning? [y/N]: " conf
    [[ "$conf" =~ ^[Yy]$ ]] || { warn "Skipped."; pause; return; }
    confirm_rerun "deep" "Deep Network Scan" || { pause; return; }

    local out="${TARGET_DIR}/deepscan"; mkdir -p "$out"
    init_report
    show_eta "deep"
    echo

    if have masscan; then
        read -rp "Run fast full-range port sweep with masscan first? (needs sudo) [y/N]: " mc
        if [[ "$mc" =~ ^[Yy]$ ]]; then
            run_step "Sweeping full port range" "sudo masscan '$TARGET' -p${MASSCAN_PORTS} --rate ${MASSCAN_RATE}" "${out}/masscan.txt" || { pause; return; }
        fi
    fi

    if have nmap; then
        run_step "Scanning common ports & services" "nmap -sV ${NMAP_TIMING} ${NMAP_PORTS_OPT} '$TARGET'" "${out}/nmap_top1000.txt" || { pause; return; }
        read -rp "Run NSE vulnerability scripts too (slower)? [y/N]: " ns
        if [[ "$ns" =~ ^[Yy]$ ]]; then
            run_step "Running scripted vulnerability checks" "nmap -sV --script vuln '$TARGET'" "${out}/nmap_nse_vuln.txt" || { pause; return; }
        fi
    fi

    if have python3 && python3 -c "import scapy" 2>/dev/null; then
        read -rp "Run a lightweight scapy host-discovery sweep? [y/N]: " sc
        if [[ "$sc" =~ ^[Yy]$ ]]; then
            run_step "Running host discovery sweep" "python3 -c \"
from scapy.all import sr1, IP, ICMP
import socket
try:
    ip = socket.gethostbyname('$TARGET')
    pkt = IP(dst=ip)/ICMP()
    r = sr1(pkt, timeout=2, verbose=0)
    print('Host', ip, 'responded' if r else 'did not respond to ICMP')
except Exception as e:
    print('error:', e)
\"" "${out}/scapy_sweep.txt" || { pause; return; }
        fi
    fi

    local open_count=0 ftp_hit=0 telnet_hit=0 nse_hit=0
    if [ -f "${out}/nmap_top1000.txt" ]; then
        open_count=$(grep -c "/tcp.*open" "${out}/nmap_top1000.txt" 2>/dev/null || echo 0)
        [ "$open_count" -gt 0 ] && add_alert "Info" "Deep Scan" "${open_count} open port(s) detected" "See nmap_top1000.txt for full service/version details."
        grep -qi "21/tcp.*open.*ftp" "${out}/nmap_top1000.txt" && { add_alert "Medium" "Deep Scan" "FTP service exposed" "Unencrypted FTP found open — check for anonymous login."; ftp_hit=1; }
        grep -qi "23/tcp.*open" "${out}/nmap_top1000.txt" && { add_alert "High" "Deep Scan" "Telnet service exposed" "Unencrypted remote admin protocol — high risk if internet-facing."; telnet_hit=1; }
    fi
    if [ -f "${out}/nmap_nse_vuln.txt" ] && grep -qi "VULNERABLE" "${out}/nmap_nse_vuln.txt"; then
        add_alert "High" "Deep Scan" "NSE flagged vulnerable service(s)" "Review nmap_nse_vuln.txt for CVE details."
        nse_hit=1
    fi

    echo
    echo -e "${C_BOLD}Key Findings:${C_RESET}"
    [ "$open_count" -gt 0 ] && find_ "${open_count} open port(s) -> deepscan/nmap_top1000.txt"
    [ "$ftp_hit" -eq 1 ] && find_ "${C_YELLOW}FTP exposed (medium)${C_RESET}"
    [ "$telnet_hit" -eq 1 ] && find_ "${C_RED}Telnet exposed (high)${C_RESET}"
    [ "$nse_hit" -eq 1 ] && find_ "${C_RED}NSE flagged a vulnerable service (high)${C_RESET} -> deepscan/nmap_nse_vuln.txt"
    [ "$open_count" -eq 0 ] && [ "$nse_hit" -eq 0 ] && find_ "No notable issues surfaced by heuristics — review raw output for full detail."

    mark_phase_done "deep"
    ok "Deep scan complete."
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
    init_report
    show_eta "vuln"
    echo

    JOB_LABELS=(); JOB_CMDS=(); JOB_OUTS=()
    have nikto  && add_job "Scanning web server for known issues" "nikto -h 'https://$TARGET'" "${out}/nikto.txt"
    have nuclei && add_job "Running template-based vulnerability checks" "nuclei -u 'https://$TARGET' ${NUCLEI_OPTS}" "${out}/nuclei.txt"

    if [ "${#JOB_LABELS[@]}" -gt 0 ]; then
        run_jobs_parallel || { pause; return; }
    fi

    if have gvm-cli; then
        info "GVM/OpenVAS detected — full scans require a configured GVM task."
        echo "Run manually via gvm-cli once a scan target/task is configured." >> "${out}/gvm_notes.txt"
    else
        warn "GVM/OpenVAS not installed (optional, heavier deep-vuln engine)."
    fi

    if [ -s "${out}/nuclei.txt" ]; then
        while IFS= read -r line; do
            sev=$(echo "$line" | grep -oE '\[(critical|high|medium|low|info)\]' | tr -d '[]' | head -1)
            sev_cap=$(echo "${sev^}")
            [ -z "$sev_cap" ] && sev_cap="Info"
            add_alert "$sev_cap" "Vulnerability Scan" "nuclei finding" "$line"
        done < "${out}/nuclei.txt"
    fi

    local nikto_hits=0
    if [ -s "${out}/nikto.txt" ]; then
        while read -r line; do
            add_alert "Medium" "Vulnerability Scan" "nikto finding" "$line"
            nikto_hits=$((nikto_hits+1))
        done < <(grep -i "OSVDB\|vulnerable" "${out}/nikto.txt")
    fi

    local nuclei_hits=0
    [ -f "${out}/nuclei.txt" ] && nuclei_hits=$(wc -l < "${out}/nuclei.txt" 2>/dev/null || echo 0)

    echo
    echo -e "${C_BOLD}Key Findings:${C_RESET}"
    [ "$nikto_hits" -gt 0 ] && find_ "${nikto_hits} nikto finding(s) -> vulnscan/nikto.txt"
    [ "$nuclei_hits" -gt 0 ] && find_ "${nuclei_hits} nuclei finding(s) -> vulnscan/nuclei.txt"
    [ "$nikto_hits" -eq 0 ] && [ "$nuclei_hits" -eq 0 ] && find_ "No findings flagged by nikto/nuclei on this pass."

    mark_phase_done "vuln"
    ok "Vulnerability scan complete."
    pause
}

pcap_capture() {
    require_target || return
    clear; banner
    echo -e "${C_BOLD}── Packet Capture ──${C_RESET}\n"
    warn "Only capture traffic you generate/control — not third-party network sniffing."
    if have tshark; then
        read -rp "Interface (e.g. eth0, lo): " iface
        read -rp "Duration (seconds): " dur
        local out="${TARGET_DIR}/pcap/capture_$(date +%s).pcap"
        run_step "Capturing packets (${dur}s)" "timeout '$dur' tshark -i '$iface' -w '$out'" "${TARGET_DIR}/pcap/capture_log.txt"
        ok "Saved -> $out"
    else
        warn "tshark not installed."
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

show_results() {
    clear; banner
    echo -e "${C_BOLD}── Results ──${C_RESET}\n"
    if [ -z "$TARGET" ]; then
        ls -1 "$RESULTS_DIR" 2>/dev/null
    else
        find "$TARGET_DIR" -type f ! -name '.state' | sort
        local db="${TARGET_DIR}/report/alerts.db"
        [ -f "$db" ] && { echo; echo "Alerts logged: $(wc -l < "$db")"; }
        local st; st=$(state_file)
        if [ -f "$st" ]; then
            echo; echo -e "${C_DIM}Phases completed:${C_RESET}"
            while IFS='=' read -r k v; do echo "  - $k: $v"; done < "$st"
        fi
    fi
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

Wraps standard, widely-used security tools (whois, dig, subfinder,
amass, httpx, nmap, nikto, nuclei, tshark, ...) behind one consistent
menu. It installs nothing itself — see install.sh to fetch the
underlying tools.

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

load_session
while true; do main_menu; done
