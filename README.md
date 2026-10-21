# Raven

Lightweight recon & assessment orchestrator for authorized security
testing. Raven wraps standard, widely-used tools (`whois`, `dig`,
`subfinder`, `amass`, `httpx`, `whatweb`, `nmap`, `masscan`, `nikto`,
`nuclei`, `tshark`) behind one consistent menu, with:

- Branded, filtered console output — raw tool output goes to
  `raven.log` and per-target result files; the screen shows phase
  names, timing, and a short "Key Findings" summary.
- Scope tracking (`scope.txt`) with an explicit confirmation prompt
  before testing anything not listed.
- Rough per-phase time estimates based on target latency and which
  tools are installed.
- Safe Ctrl+C handling — an interrupted step saves whatever partial
  output exists and returns you to the menu instead of crashing.
- An HTML assessment report (`raven_report_<target>.html`) with
  severity-colored alerts aggregated across every phase you ran.

**Author:** z7

---

## Install

```bash
git clone https://github.com/<your-username>/raven.git
cd raven
sudo ./install.sh
```

`install.sh` installs the underlying tools via `apt` (and `go install`
for the Go-based scanners, if Go is present). Raven itself has no
dependencies beyond `bash` — it runs with nothing installed, it just
skips phases whose tools are missing and tells you which.

## Usage

```bash
bash raven.sh
```

```
 1  Target selection        — add a domain to scope.txt, then set it as the active target
 2  Passive recon            — whois, DNS records, subdomain enumeration (no traffic to target's services)
 3  Active recon              — live-host probing, web tech fingerprinting
 4  Deep network scan         — nmap / masscan / NSE (confirmation required — touches the live target)
 5  Vulnerability scan        — nikto / nuclei (confirmation required)
 6  Packet capture            — tshark, for traffic you generate yourself
 7  Full auto                 — runs the pipeline in a background tmux session
 8  Show results              — list every file written for the current target
 9  Plugins                   — drop your own .sh scripts in plugins/, they receive $TARGET and $TARGET_DIR
 10 Check dependencies        — see which underlying tools are installed
 11 Generate report           — HTML report, severity-colored alerts from every phase
 12 Options                   — edit scope.txt, clear session, view the full log
 13 About / Help              — in-app usage guide
 14 Exit
```

Typical flow: **1 → 2 → 3 → 4 → 5 → 11**.

## Output layout

```
results/<target>/
  passive/      whois, DNS, subdomain lists, SUMMARY.md
  active/       live hosts, whatweb fingerprints
  deepscan/     nmap / masscan / NSE output
  vulnscan/     nikto / nuclei output
  pcap/         packet captures
  report/       alerts.csv + the final HTML report
```

`raven.log` (repo root) has the exact command and exit code for every
step Raven ran, for your own audit trail.

## Scope & authorization

Raven will warn you and ask for explicit confirmation before running
anything against a target not listed in `scope.txt`. **Only run this
against systems you are explicitly authorized to test** — your own
infrastructure, or a program/client that has given written permission
(e.g. a bug bounty program's in-scope assets).

## What Raven is (and isn't)

Raven is an **orchestrator** — it calls the same tools already in
Kali Linux (`nmap`, `nikto`, `nuclei`, etc.) through one menu with
consistent logging, scoping, and reporting. It does not replace those
tools or contain its own scanning engine. Getting it packaged into
Kali's official tool list is a separate, maintainer-reviewed process
([kali-tools-scripts](https://gitlab.com/kalilinux/packages) /
`kali-dev` mailing list) that takes community adoption and a
maintenance track record — publishing here is the first step toward
that, not a replacement for it.

## License

Add a LICENSE file before making the repo public (MIT is the common
choice for tools like this).
