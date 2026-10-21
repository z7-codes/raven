#!/usr/bin/env bash
# ============================================================
#  install.sh — fetches Raven's underlying dependencies
#  (Debian/Kali/Ubuntu apt-based systems)
#  Author: z7
# ============================================================
set -e

echo "== Raven dependency installer =="
echo "This installs third-party tools Raven orchestrates."
echo "It does not modify Raven itself."
echo

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo: sudo ./install.sh"
    exit 1
fi

apt-get update

# Core packages available directly via apt on Kali/Debian
APT_PKGS=(whois dnsutils bind9-host dnsrecon nmap masscan nikto tshark tmux python3 python3-pip python3-scapy)

echo "[*] Installing apt packages: ${APT_PKGS[*]}"
apt-get install -y "${APT_PKGS[@]}" || echo "[!] Some apt packages failed — check names for your distro and retry manually."

# Go-based tools (subfinder, httpx, nuclei) — installed via go install if Go is present
if command -v go >/dev/null 2>&1; then
    echo "[*] Installing Go-based tools (subfinder, httpx, nuclei)..."
    go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest || true
    go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest || true
    go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest || true
    echo "[*] Add \$(go env GOPATH)/bin to your PATH if these commands aren't found afterwards."
else
    echo "[!] Go not installed — skipping subfinder/httpx/nuclei."
    echo "    Install Go first (apt-get install -y golang-go) then re-run this script,"
    echo "    or on Kali these may already be packaged: apt-get install -y subfinder httpx-toolkit nuclei"
fi

# amass — often packaged directly on Kali
if ! command -v amass >/dev/null 2>&1; then
    apt-get install -y amass || echo "[!] amass not available via apt — see https://github.com/owasp-amass/amass for manual install."
fi

# whatweb — packaged on Kali
if ! command -v whatweb >/dev/null 2>&1; then
    apt-get install -y whatweb || echo "[!] whatweb not available via apt."
fi

echo
echo "[+] Done. Run: bash raven.sh  ->  option 10 (Check dependencies) to verify what's ready."
