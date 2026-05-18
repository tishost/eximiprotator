#!/bin/bash
# ============================================================
#  Exim IP Manager — Installer (run as root on WHM server)
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}Run as root.${NC}" && exit 1

INSTALL_DIR="/usr/local/exim-ip-manager"
BIN_LINK="/usr/local/bin/eximip"

echo -e "${GREEN}Installing Exim IP Manager...${NC}"

# Create install dir
mkdir -p "$INSTALL_DIR"
cp exim_ip_manager.sh "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/exim_ip_manager.sh"

# Symlink for easy access
ln -sf "$INSTALL_DIR/exim_ip_manager.sh" "$BIN_LINK"

# Create log file
touch /var/log/exim_ip_rotation.log

# Cron: blacklist auto-check every 6 hours
CRON_JOB="0 */6 * * * /usr/local/bin/eximip blacklist >> /var/log/exim_ip_rotation.log 2>&1"
(crontab -l 2>/dev/null | grep -v "eximip"; echo "$CRON_JOB") | crontab -

echo -e "${GREEN}✓ Installed to: $INSTALL_DIR${NC}"
echo -e "${GREEN}✓ Command available: eximip${NC}"
echo -e "${GREEN}✓ Auto blacklist check: every 6 hours via cron${NC}"
echo ""
echo -e "Run: ${YELLOW}eximip${NC}   to open the menu"
echo -e "  or ${YELLOW}eximip add${NC} to add first IP"
