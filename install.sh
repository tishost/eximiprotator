#!/bin/bash
# ============================================================
#  Exim IP Manager — Installer
#  Repo : https://github.com/tishost/eximiprotator
#  Usage: run as root on WHM/cPanel server
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}Run as root.${NC}" && exit 1

REPO_URL="https://github.com/tishost/eximiprotator.git"
CLONE_DIR="/usr/local/eximiprotator"
BIN_LINK="/usr/local/bin/eximip"

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║        Exim IP Rotation Manager — Installer          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── fresh install vs update ──────────────────────────────────
if [[ -d "$CLONE_DIR/.git" ]]; then
    echo -e "${YELLOW}Existing installation found — updating...${NC}"
    cd "$CLONE_DIR"
    git pull origin main
    echo -e "${GREEN}✓ Updated to latest version${NC}"
else
    # ── dependencies ────────────────────────────────────────
    echo -e "${YELLOW}Checking dependencies...${NC}"
    for pkg in git bind-utils nmap-ncat; do
        if ! command -v "${pkg/bind-utils/dig}" &>/dev/null && \
           ! command -v "${pkg/nmap-ncat/nc}"  &>/dev/null && \
           ! rpm -q "$pkg" &>/dev/null; then
            echo -e "  Installing $pkg..."
            yum install -y "$pkg" &>/dev/null
        fi
    done
    echo -e "${GREEN}✓ Dependencies ready${NC}"

    # ── clone ───────────────────────────────────────────────
    echo -e "${YELLOW}Cloning from GitHub...${NC}"
    git clone "$REPO_URL" "$CLONE_DIR"
    echo -e "${GREEN}✓ Cloned to $CLONE_DIR${NC}"
    cd "$CLONE_DIR"
fi

# ── install binary ───────────────────────────────────────────
chmod +x "$CLONE_DIR/exim_ip_manager.sh"
ln -sf "$CLONE_DIR/exim_ip_manager.sh" "$BIN_LINK"
touch /var/log/exim_ip_rotation.log

# ── version info ─────────────────────────────────────────────
VERSION=$(grep '^VERSION=' "$CLONE_DIR/exim_ip_manager.sh" | cut -d'"' -f2)

echo ""
echo -e "${GREEN}✓ Installed   : $CLONE_DIR${NC}"
echo -e "${GREEN}✓ Command     : eximip  (available system-wide)${NC}"
echo -e "${GREEN}✓ Version     : $VERSION${NC}"
echo -e "${GREEN}✓ Log file    : /var/log/exim_ip_rotation.log${NC}"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo -e "  1. ${YELLOW}eximip setup-guide${NC}   ← WHM এ একবারের setup দেখো"
echo -e "  2. ${YELLOW}eximip add${NC}            ← প্রথম IP যোগ করো"
echo -e "  3. ${YELLOW}eximip install-cron${NC}   ← Hourly rotation চালু করো"
echo ""
echo -e "  Full guide: ${CYAN}${CLONE_DIR}/USERGUIDE.md${NC}"
echo -e "  GitHub    : ${CYAN}${REPO_URL}${NC}"
