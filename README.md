# Raven

<p align="center">
  <img src="assets/raven-logo.png" alt="Raven — Reconnaissance Tool" width="360">
</p>

> Save the project's logo artwork as `assets/raven-logo.png` in your repo
> for the image above to render on GitHub. The terminal UI can't draw a
> raster image, so the startup banner instead uses a compact crosshair/
> reticle glyph in box-drawing characters next to the "RAVEN" wordmark —
> see it live with `./raven.sh`, or see `docs/banner.txt` for a larger
> ASCII version suitable for pasting elsewhere.

Recon & assessment orchestrator for authorized security testing.
Raven wraps standard, widely-used tools (`whois`, `dig`, `subfinder`,
`amass`, `httpx`, `whatweb`, `nmap`, `masscan`, `nikto`, `nuclei`,
`tshark`) behind one consistent, Metasploit-style terminal menu.

- **Grouped main menu** — Recon / Scanning / Reporting / System
  sections, with a dependency summary (`N/19 tools ready`) always
  visible at the top.
- **Parallel execution** — independent tools within Passive Recon,
  Active Recon and Vulnerability Scan run concurrently (not one at a
  time), each with its own timing shown after it finishes.
- **Validated target input** — only well-formed hostnames/IPs are
  accepted; anything else (quotes, shell metacharacters, stray
  punctuation) is rejected before it ever touches a command.
- **Anchored scope matching** — `scope.txt` entries match the exact
  domain or its real subdomains only; a lookalike like
  `example.com.evil.net` is correctly flagged as out of scope.
- **Resume/skip per phase** — Raven remembers which phases already
  ran for the current target and asks before re-running one.
- **Safe Ctrl+C handling** — an interrupted step saves whatever
  partial output exists, then asks if you want to set a new target
  right away instead of just dumping you back at the menu.
- **Rough per-phase ETAs** based on target latency and installed
  tools, plus a live alert-count dashboard in the banner.
- **Reports in three formats** — HTML (`raven_report_<target>.html`),
  CSV and JSON, all built from the same alert data collected across
  every phase you ran.
- **`raven.conf`** lets you tune nmap ports/timing, nuclei severity
  filters, masscan rate, DNS record types, etc. without editing the
  script. `--no-color` / `NO_COLOR=1` disable ANSI colors.

**Author:** z7

---

## Install

```bash
git clone https://github.com/z7-codes/raven.git
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
