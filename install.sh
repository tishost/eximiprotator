#!/bin/bash
# ============================================================
#  Exim IP Manager — Installer
#  Repo : https://github.com/tishost/eximiprotator
#  Usage: bash <(curl -s https://raw.githubusercontent.com/tishost/eximiprotator/main/install.sh)
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}Run as root.${NC}" && exit 1

RAW_BASE="https://raw.githubusercontent.com/tishost/eximiprotator/main"
INSTALL_DIR="/usr/local/eximiprotator"
BIN_LINK="/usr/local/bin/eximip"
MAIN_SCRIPT="$INSTALL_DIR/exim_ip_manager.sh"

FILES=(
    "exim_ip_manager.sh"
    "install.sh"
    "USERGUIDE.md"
    "README.md"
)

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║        Exim IP Rotation Manager — Installer          ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── download via curl (no git needed) ────────────────────────
download_files() {
    echo -e "${YELLOW}Downloading files from GitHub...${NC}"
    mkdir -p "$INSTALL_DIR"

    for file in "${FILES[@]}"; do
        local url="${RAW_BASE}/${file}"
        local dest="${INSTALL_DIR}/${file}"
        if curl -fsSL "$url" -o "$dest" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $file"
        else
            echo -e "  ${RED}✗ Failed to download: $file${NC}"
            exit 1
        fi
    done
}

# ── check if already installed ───────────────────────────────
if [[ -f "$MAIN_SCRIPT" ]]; then
    local_ver=$(grep '^VERSION=' "$MAIN_SCRIPT" 2>/dev/null | cut -d'"' -f2 || echo "unknown")
    echo -e "${YELLOW}Existing installation found (v${local_ver}) — updating...${NC}"
    download_files
    echo -e "${GREEN}✓ Updated to latest version${NC}"
else
    echo -e "${YELLOW}Fresh install...${NC}"

    # Check curl
    if ! command -v curl &>/dev/null; then
        echo -e "${YELLOW}Installing curl...${NC}"
        yum install -y curl &>/dev/null || { echo -e "${RED}curl install failed.${NC}"; exit 1; }
    fi

    download_files
    echo -e "${GREEN}✓ Installed to $INSTALL_DIR${NC}"
fi

# ── set permissions + symlink ─────────────────────────────────
chmod +x "$MAIN_SCRIPT"
ln -sf "$MAIN_SCRIPT" "$BIN_LINK"
touch /var/log/exim_ip_rotation.log

# ── version info ──────────────────────────────────────────────
VERSION=$(grep '^VERSION=' "$MAIN_SCRIPT" | cut -d'"' -f2)

echo ""
echo -e "${GREEN}✓ Installed   : $INSTALL_DIR${NC}"
echo -e "${GREEN}✓ Command     : eximip  (available system-wide)${NC}"
echo -e "${GREEN}✓ Version     : $VERSION${NC}"
echo -e "${GREEN}✓ Log file    : /var/log/exim_ip_rotation.log${NC}"
echo ""
# ── auto-sync server IPs on first install ────────────────────
if [[ ! -f /etc/exim_rotation.conf ]] || \
   ! grep -q '|' /etc/exim_rotation.conf 2>/dev/null; then
    echo -e "${YELLOW}Auto-detecting server IPs...${NC}"
    "$MAIN_SCRIPT" sync 2>/dev/null || true
fi

echo -e "${CYAN}Next steps:${NC}"
echo -e "  1. ${YELLOW}eximip setup-guide${NC}   ← WHM এ একবারের setup দেখো"
echo -e "  2. ${YELLOW}eximip list${NC}           ← Auto-detected IPs দেখো"
echo -e "  3. ${YELLOW}eximip install-cron${NC}   ← Hourly rotation চালু করো"
echo ""
echo -e "  Full guide : ${CYAN}${INSTALL_DIR}/USERGUIDE.md${NC}"
echo -e "  GitHub     : ${CYAN}https://github.com/tishost/eximiprotator${NC}"
echo -e "  Update     : ${CYAN}bash <(curl -s ${RAW_BASE}/install.sh)${NC}"
