#!/bin/bash
# ============================================================
#  Exim IP Rotation Manager for WHM/cPanel
#  Version : 1.1.0
#  Requires root. Usage: bash exim_ip_manager.sh [command]
# ============================================================
set -euo pipefail

VERSION="1.1.0"

CONFIG_FILE="/etc/exim_rotation.conf"
CURRENT_IP_FILE="/etc/exim_current_ip"
LOG_FILE="/var/log/exim_ip_rotation.log"
BACKUP_DIR="/etc/exim_rotation_backups"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ── safety check ────────────────────────────────────────────

[[ $EUID -ne 0 ]] && echo -e "${RED}Error: must run as root.${NC}" && exit 1

# ── helpers ─────────────────────────────────────────────────

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }

die() { echo -e "${RED}Error: $1${NC}" >&2; log "ERROR: $1"; exit 1; }

print_header() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║        Exim IP Rotation Manager — WHM/cPanel         ║"
    printf "║  %-52s║\n" "  Version ${VERSION}"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

validate_ip() {
    local ip=$1
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -ra p <<< "$ip"
    for o in "${p[@]}"; do [[ $o -gt 255 ]] && return 1; done
    return 0
}

sanitize_label() {
    # Strip pipe, backslash, quotes, semicolons — all config-breaking chars
    echo "$1" | tr -d '|\\";`$' | cut -c1-30
}

escape_for_sed() {
    # Escape dots and slashes for use in sed patterns
    echo "$1" | sed 's/\./\\./g; s/\//\\\//g'
}

ip_count() { get_ips | wc -l | tr -d ' '; }

get_ips()     { grep -v '^#' "$CONFIG_FILE" 2>/dev/null | grep '|' | grep '|1$' || true; }
get_all_ips() { grep -v '^#' "$CONFIG_FILE" 2>/dev/null | grep '|' || true; }

init_config() {
    mkdir -p "$BACKUP_DIR"
    [[ ! -f "$CONFIG_FILE" ]] || return 0
    cat > "$CONFIG_FILE" << 'EOF'
# Exim IP Rotation Config — managed by exim_ip_manager.sh
# FORMAT: IP|LABEL|HOURLY_LIMIT|ENABLED   (ENABLED: 1=yes 0=no)
EOF
    chmod 600 "$CONFIG_FILE"
    log "Config file created: $CONFIG_FILE"
}

setup_logrotate() {
    cat > /etc/logrotate.d/exim-ip-rotation << 'EOF'
/var/log/exim_ip_rotation.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
}

# ── IP management ────────────────────────────────────────────

add_ip() {
    print_header
    echo -e "${BLUE}=== Add New IP ===${NC}\n"

    read -rp "Enter IP address     : " ip
    validate_ip "$ip" || { echo -e "${RED}Invalid IP.${NC}"; return 1; }

    if grep -q "^${ip}|" "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${YELLOW}IP $ip already exists.${NC}"; return 1
    fi

    read -rp "Label (e.g. Server1) : " raw_label
    label=$(sanitize_label "${raw_label:-IP_$(date +%s)}")

    read -rp "Hourly send limit    : " limit
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=1000

    echo "${ip}|${label}|${limit}|1" >> "$CONFIG_FILE"
    echo -e "\n${GREEN}✓ Added: $ip ($label)${NC}"
    log "Added IP: $ip label=$label limit=$limit"

    read -rp $'\nUpdate current sending IP now? [y/N]: ' apply
    [[ "$apply" =~ ^[Yy]$ ]] && update_current_ip
}

remove_ip() {
    print_header
    echo -e "${BLUE}=== Remove IP ===${NC}\n"
    list_ips_simple

    [[ $(get_all_ips | wc -l | tr -d ' ') -eq 0 ]] && \
        echo -e "${YELLOW}No IPs configured.${NC}" && return

    echo ""
    read -rp "Enter IP to remove: " ip
    validate_ip "$ip" || { echo -e "${RED}Invalid IP.${NC}"; return 1; }
    grep -q "^${ip}|" "$CONFIG_FILE" || { echo -e "${RED}IP not found.${NC}"; return 1; }

    local escaped
    escaped=$(escape_for_sed "$ip")
    sed -i "/^${escaped}|/d" "$CONFIG_FILE"
    echo -e "${GREEN}✓ Removed: $ip${NC}"
    log "Removed IP: $ip"

    read -rp $'\nUpdate rotation now? [y/N]: ' apply
    [[ "$apply" =~ ^[Yy]$ ]] && update_current_ip
}

toggle_ip() {
    print_header
    echo -e "${BLUE}=== Enable / Disable IP ===${NC}\n"
    list_ips_simple
    echo ""
    read -rp "Enter IP to toggle: " ip

    validate_ip "$ip" || { echo -e "${RED}Invalid IP.${NC}"; return 1; }
    grep -q "^${ip}|" "$CONFIG_FILE" || { echo -e "${RED}IP not found.${NC}"; return 1; }

    local escaped current
    escaped=$(escape_for_sed "$ip")
    current=$(grep "^${ip}|" "$CONFIG_FILE" | cut -d'|' -f4)

    if [[ "$current" == "1" ]]; then
        sed -i "s/^${escaped}|\(.*\)|1$/${ip}|\1|0/" "$CONFIG_FILE"
        echo -e "${YELLOW}⏸  Disabled: $ip${NC}"
        log "Disabled IP: $ip"
    else
        sed -i "s/^${escaped}|\(.*\)|0$/${ip}|\1|1/" "$CONFIG_FILE"
        echo -e "${GREEN}▶  Enabled: $ip${NC}"
        log "Enabled IP: $ip"
    fi

    read -rp $'\nUpdate rotation now? [y/N]: ' apply
    [[ "$apply" =~ ^[Yy]$ ]] && update_current_ip
}

list_ips_simple() {
    local active
    active=$(ip_count)
    echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"
    printf "%-18s %-15s %-12s %-8s\n" "IP ADDRESS" "LABEL" "HOURLY LIMIT" "STATUS"
    echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"

    while IFS='|' read -r ip label limit enabled; do
        if [[ "$enabled" == "1" ]]; then
            status="${GREEN}ACTIVE${NC}"
        else
            status="${RED}DISABLED${NC}"
        fi
        printf "%-18s %-15s %-12s " "$ip" "$label" "$limit"
        echo -e "$status"
    done < <(get_all_ips)

    echo -e "${CYAN}──────────────────────────────────────────────────────${NC}"
    echo -e "Active: ${GREEN}${active}${NC}"
}

list_ips() {
    print_header
    echo -e "${BLUE}=== IP Pool Status ===${NC}\n"

    local total active
    total=$(get_all_ips | wc -l | tr -d ' ')
    active=$(ip_count)

    list_ips_simple
    echo -e "\nTotal: ${total}  Active: ${GREEN}${active}${NC}  Disabled: ${RED}$((total - active))${NC}"

    if [[ $active -gt 0 ]]; then
        local current_ip
        current_ip=$(cat "$CURRENT_IP_FILE" 2>/dev/null || echo "not set")
        echo -e "\nCurrently sending via: ${GREEN}${current_ip}${NC}"
    fi
}

# ── IP file approach (production-safe, no restart needed) ────
#
# How this works:
#   1. This script writes the active IP to /etc/exim_current_ip
#   2. Exim reads that file dynamically using ${readfile{...}}
#   3. No Exim restart needed when IP changes — works per-connection
#   4. WHM rebuilds don't touch /etc/exim_current_ip
#
# One-time WHM setup required (see: eximip setup-guide)

update_current_ip() {
    local active
    active=$(ip_count)

    if [[ $active -eq 0 ]]; then
        echo -e "${RED}No active IPs configured.${NC}"
        return 1
    fi

    local epoch idx selected_ip
    epoch=$(date +%s)
    idx=$(( (epoch / 3600) % active ))
    selected_ip=$(get_ips | sed -n "$((idx + 1))p" | cut -d'|' -f1)

    [[ -z "$selected_ip" ]] && die "Could not determine IP for slot $idx"

    # Atomic write — no partial reads by Exim
    local tmp
    tmp=$(mktemp /etc/exim_current_ip.XXXXXX)
    echo -n "$selected_ip" > "$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$CURRENT_IP_FILE"

    echo -e "${GREEN}✓ Current sending IP set to: $selected_ip${NC}"
    log "IP updated to: $selected_ip (slot $idx of $active)"
}

# Called by cron every hour — auto-sync then rotate
cron_rotate() {
    sync_server_ips silent
    local active
    active=$(ip_count)
    [[ $active -eq 0 ]] && log "cron_rotate: no active IPs, skipping" && exit 0
    update_current_ip
}

# ── auto-sync server IPs ──────────────────────────────────────
# Scans all IPs on the server and adds any missing ones to the
# rotation config automatically. Existing IPs are never modified.

sync_server_ips() {
    local silent="${1:-}"  # pass "silent" to suppress output

    [[ "$silent" != "silent" ]] && print_header
    [[ "$silent" != "silent" ]] && echo -e "${BLUE}=== Auto-Sync Server IPs ===${NC}\n"

    # Get all routable IPs on server (skip loopback + link-local)
    local server_ips=()
    while read -r sip; do
        server_ips+=("$sip")
    done < <(ip addr show 2>/dev/null \
        | grep 'inet ' \
        | awk '{print $2}' \
        | cut -d/ -f1 \
        | grep -vE '^(127\.|169\.254\.)' \
        | sort -u)

    if [[ ${#server_ips[@]} -eq 0 ]]; then
        [[ "$silent" != "silent" ]] && echo -e "${RED}No IPs found on server.${NC}"
        return 1
    fi

    # Identify main server IP (default route)
    local main_ip=""
    main_ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' || true)

    local added=0 skipped=0

    for sip in "${server_ips[@]}"; do
        # Already in config? Skip
        if grep -q "^${sip}|" "$CONFIG_FILE" 2>/dev/null; then
            skipped=$((skipped+1))
            [[ "$silent" != "silent" ]] && \
                echo -e "  ${CYAN}already in pool${NC}  $sip"
            continue
        fi

        # Build label
        local label
        if [[ "$sip" == "$main_ip" ]]; then
            label="Main-IP"
        else
            label="IP-$((added + skipped + 1))"
        fi

        echo "${sip}|${label}|1000|1" >> "$CONFIG_FILE"
        added=$((added+1))
        log "Auto-synced IP: $sip label=$label"

        [[ "$silent" != "silent" ]] && \
            echo -e "  ${GREEN}✓ added${NC}           $sip  ($label)"
    done

    if [[ "$silent" != "silent" ]]; then
        echo ""
        echo -e "  Total on server : ${#server_ips[@]}"
        echo -e "  Added           : ${GREEN}${added}${NC}"
        echo -e "  Already existed : ${skipped}"

        if [[ $added -gt 0 ]]; then
            echo -e "\n${GREEN}✓ Config updated. Running: eximip list${NC}"
            echo ""
            list_ips_simple
            echo ""
            read -rp "Update sending IP now? [y/N]: " apply
            [[ "$apply" =~ ^[Yy]$ ]] && update_current_ip
        else
            echo -e "\n${GREEN}✓ All server IPs already in rotation pool.${NC}"
        fi
    else
        # Silent mode: just log
        [[ $added -gt 0 ]] && log "sync_server_ips: added $added new IPs"
    fi
}

# ── WHM setup guide ──────────────────────────────────────────

show_setup_guide() {
    print_header
    echo -e "${BLUE}=== One-Time WHM Setup Guide ===${NC}\n"
    echo -e "This script uses a FILE-BASED approach:"
    echo -e "  • /etc/exim_current_ip holds the active IP"
    echo -e "  • Exim reads it dynamically — ${GREEN}no restart when IP changes${NC}"
    echo -e "  • Cron updates the file every hour\n"

    echo -e "${YELLOW}STEP 1 — WHM Exim Configuration Manager${NC}"
    echo -e "  1. Log into WHM"
    echo -e "  2. Go to: Service Configuration → Exim Configuration Manager"
    echo -e "  3. Click: Advanced Editor\n"

    echo -e "${YELLOW}STEP 2 — Find the remote_smtp transport${NC}"
    echo -e "  Search for:   remote_smtp:"
    echo -e "  It looks like:"
    echo -e "    remote_smtp:"
    echo -e "      driver = smtp"
    echo -e "      ...\n"

    echo -e "${YELLOW}STEP 3 — Add the interface line${NC}"
    echo -e "  Add this line inside the remote_smtp transport block:"
    echo -e "  ${GREEN}  interface = \${readfile{/etc/exim_current_ip}{}}${NC}\n"

    echo -e "${YELLOW}STEP 4 — Save & rebuild${NC}"
    echo -e "  Click Save. WHM will rebuild and restart Exim automatically.\n"

    echo -e "${YELLOW}STEP 5 — Install the hourly cron${NC}"
    echo -e "  Run: ${CYAN}eximip install-cron${NC}\n"

    echo -e "${YELLOW}STEP 6 — Add your IPs${NC}"
    echo -e "  Run: ${CYAN}eximip add${NC}\n"

    echo -e "${GREEN}After setup, IP switches every hour with zero downtime.${NC}"
    echo -e "${GREEN}If an IP is blacklisted, disable it with: eximip menu → option 4${NC}"
}

# ── cron installer ───────────────────────────────────────────

install_cron() {
    print_header
    echo -e "${BLUE}=== Installing Hourly Cron ===${NC}\n"

    local script_path
    script_path=$(realpath "$0")
    local cron_job="0 * * * * $script_path cron-rotate >> $LOG_FILE 2>&1"

    # Remove old entry if exists
    crontab -l 2>/dev/null | grep -v "exim_ip_manager" | crontab - || true
    (crontab -l 2>/dev/null; echo "$cron_job") | crontab -

    echo -e "${GREEN}✓ Cron installed: runs at top of every hour${NC}"
    echo -e "  Entry: $cron_job"
    log "Cron installed"

    setup_logrotate
    echo -e "${GREEN}✓ Log rotation configured${NC}"
}

remove_cron() {
    crontab -l 2>/dev/null | grep -v "exim_ip_manager" | crontab - || true
    echo -e "${GREEN}✓ Cron removed.${NC}"
    log "Cron removed"
}

# ── status & monitoring ──────────────────────────────────────

show_status() {
    print_header
    echo -e "${BLUE}=== Live Rotation Status ===${NC}\n"

    local epoch active current_ip
    epoch=$(date +%s)
    active=$(ip_count)

    echo -e "Server time   : $(date)"
    echo -e "Active IPs    : $active"

    if [[ -f "$CURRENT_IP_FILE" ]]; then
        current_ip=$(cat "$CURRENT_IP_FILE")
        echo -e "Sending via   : ${GREEN}$current_ip${NC}"
    else
        echo -e "Sending via   : ${RED}NOT SET — run: eximip update-ip${NC}"
    fi

    if [[ $active -gt 0 ]]; then
        local next_switch
        next_switch=$(( 3600 - (epoch % 3600) ))
        printf "Next rotation : in %d min %d sec\n" $((next_switch / 60)) $((next_switch % 60))
    fi

    echo -e "\n${BLUE}--- 24-Hour Schedule ---${NC}"
    printf "%-8s  %-18s  %s\n" "HOUR" "IP" "LABEL"
    echo "────────────────────────────────────────"

    for h in $(seq 0 23); do
        if [[ $active -gt 0 ]]; then
            local slot_idx slot_ip slot_label
            slot_idx=$(( (epoch / 3600 + h) % active ))
            slot_ip=$(get_ips | sed -n "$((slot_idx + 1))p" | cut -d'|' -f1)
            slot_label=$(get_ips | sed -n "$((slot_idx + 1))p" | cut -d'|' -f2)
            local cur_h
            cur_h=$(date +%H | sed 's/^0*//')
            if [[ $h -eq 0 ]]; then
                echo -e "${GREEN}$(printf '%02d:00' "${cur_h:-0}")  ←  %-18s  %s (NOW)${NC}" "$slot_ip" "$slot_label"
            else
                local future_h=$(( (${cur_h:-0} + h) % 24 ))
                printf "%02d:00      %-18s  %s\n" "$future_h" "$slot_ip" "$slot_label"
            fi
        fi
    done
}

check_blacklist() {
    print_header
    echo -e "${BLUE}=== Blacklist Check (DNSBL) ===${NC}\n"

    command -v dig &>/dev/null || die "dig not found. Install: yum install bind-utils"

    local BLACKLISTS=(
        "zen.spamhaus.org"
        "b.barracudacentral.org"
        "bl.spamcop.net"
        "dnsbl.sorbs.net"
        "spam.dnsbl.sorbs.net"
        "ix.dnsbl.manitu.net"
    )

    while IFS='|' read -r ip label _ _; do
        echo -e "${CYAN}Checking: $ip ($label)${NC}"
        local reversed listed=0
        reversed=$(echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')

        for bl in "${BLACKLISTS[@]}"; do
            local result
            result=$(dig +short +time=5 +tries=1 "${reversed}.${bl}" 2>/dev/null || true)
            if [[ -n "$result" ]]; then
                echo -e "  ${RED}✗ LISTED on $bl ($result)${NC}"
                log "BLACKLISTED: $ip on $bl"
                listed=1
            fi
        done

        if [[ $listed -eq 0 ]]; then
            echo -e "  ${GREEN}✓ Clean${NC}"
        else
            echo -e "  ${YELLOW}→ Disable this IP: eximip menu → option 4${NC}"
        fi
        echo ""
    done < <(get_all_ips)
}

dns_check() {
    print_header
    echo -e "${BLUE}=== DNS Records Needed ===${NC}\n"

    read -rp "Sending domain: " domain
    [[ -z "$domain" ]] && echo -e "${RED}Domain required.${NC}" && return 1

    local spf_ips=""
    while IFS='|' read -r ip _ _ _; do
        spf_ips+=" ip4:$ip"
    done < <(get_ips)

    echo -e "\n${CYAN}1. SPF (add to DNS for $domain):${NC}"
    echo -e "   ${GREEN}v=spf1${spf_ips} ~all${NC}"

    echo -e "\n${CYAN}2. PTR / rDNS (set in your server panel):${NC}"
    while IFS='|' read -r ip label _ _; do
        echo "   $ip  →  mail.${domain}"
    done < <(get_ips)

    echo -e "\n${CYAN}3. DKIM (one key covers all IPs):${NC}"
    echo "   WHM → Email → DKIM Private Keys → Generate for $domain"

    echo -e "\n${CYAN}4. DMARC:${NC}"
    echo "   _dmarc.${domain}  TXT  \"v=DMARC1; p=quarantine; rua=mailto:postmaster@${domain}\""

    echo -e "\n${CYAN}5. Verify each IP has PTR set:${NC}"
    while IFS='|' read -r ip _ _ _; do
        local ptr
        ptr=$(dig +short -x "$ip" 2>/dev/null | sed 's/\.$//' || echo "NOT SET")
        echo "   $ip → PTR: $ptr"
    done < <(get_ips)
}

show_logs() {
    print_header
    echo -e "${BLUE}=== Recent Rotation Logs ===${NC}\n"
    if [[ -f "$LOG_FILE" ]]; then
        tail -50 "$LOG_FILE"
    else
        echo -e "${YELLOW}No logs yet.${NC}"
    fi
}

# ── mail stats ───────────────────────────────────────────────

show_mail_stats() {
    print_header
    echo -e "${BLUE}=== Mail Send Statistics ===${NC}\n"

    # cPanel Exim mainlog location
    local MAINLOG="/var/log/exim_mainlog"
    [[ ! -f "$MAINLOG" ]] && MAINLOG="/var/log/exim4/mainlog"
    [[ ! -f "$MAINLOG" ]] && die "Exim mainlog not found. Checked: /var/log/exim_mainlog"

    read -rp "Days to show [1–30, default 1]: " days_input
    local days="${days_input:-1}"
    [[ "$days" =~ ^[0-9]+$ && $days -ge 1 && $days -le 30 ]] || days=1

    local today
    today=$(date '+%Y-%m-%d')

    # Build date list (today, yesterday, ...)
    local date_list=()
    for ((d=0; d<days; d++)); do
        date_list+=( "$(date -d "-${d} days" '+%Y-%m-%d' 2>/dev/null || date -v-${d}d '+%Y-%m-%d')" )
    done

    # Build grep pattern: 2024-01-15|2024-01-14|...
    local date_pattern
    date_pattern=$(IFS='|'; echo "${date_list[*]}")

    echo -e "${CYAN}Log file : $MAINLOG${NC}"
    echo -e "${CYAN}Period   : last ${days} day(s) — ${date_list[-1]} to ${today}${NC}\n"

    # ── extract relevant lines once (performance) ───────────
    local tmpfile
    tmpfile=$(mktemp /tmp/exim_stats.XXXXXX)
    grep -E "^(${date_pattern})" "$MAINLOG" > "$tmpfile" 2>/dev/null || true

    local total_queued total_delivered total_failed total_deferred
    # <= lines: messages accepted/queued
    total_queued=$(grep -c ' <= ' "$tmpfile" 2>/dev/null || echo 0)
    # => lines: delivered
    total_delivered=$(grep -c ' => ' "$tmpfile" 2>/dev/null || echo 0)
    # ** lines: failed/bounced
    total_failed=$(grep -c ' \*\* ' "$tmpfile" 2>/dev/null || echo 0)
    # ==> deferred
    total_deferred=$(grep -c ' == ' "$tmpfile" 2>/dev/null || echo 0)

    # ── summary ──────────────────────────────────────────────
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  OVERALL SUMMARY${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    printf "  %-18s : ${GREEN}%s${NC}\n"  "Queued/Accepted"  "$total_queued"
    printf "  %-18s : ${GREEN}%s${NC}\n"  "Delivered"        "$total_delivered"
    printf "  %-18s : ${YELLOW}%s${NC}\n" "Deferred"         "$total_deferred"
    printf "  %-18s : ${RED}%s${NC}\n"    "Failed/Bounced"   "$total_failed"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}\n"

    # ── per-day breakdown ────────────────────────────────────
    if [[ $days -gt 1 ]]; then
        echo -e "${BLUE}── Daily Breakdown ──────────────────────────────${NC}"
        printf "  %-12s  %-10s  %-10s  %-8s\n" "DATE" "DELIVERED" "DEFERRED" "FAILED"
        echo "  ────────────────────────────────────────────────"
        for d in "${date_list[@]}"; do
            local d_del d_def d_fail
            d_del=$(grep  "^${d}" "$tmpfile" | grep -c ' => '   2>/dev/null || echo 0)
            d_def=$(grep  "^${d}" "$tmpfile" | grep -c ' == '   2>/dev/null || echo 0)
            d_fail=$(grep "^${d}" "$tmpfile" | grep -c ' \*\* ' 2>/dev/null || echo 0)
            printf "  %-12s  %-10s  %-10s  %-8s\n" "$d" "$d_del" "$d_def" "$d_fail"
        done
        echo ""
    fi

    # ── per-user stats ───────────────────────────────────────
    # cPanel Exim log: authenticated user appears as A=dovecot_plain:USERNAME or U=USERNAME
    echo -e "${BLUE}── Top Senders (cPanel user) ─────────────────────${NC}"
    printf "  %-20s  %s\n" "CPANEL USER" "MESSAGES SENT"
    echo "  ──────────────────────────────────────────────"

    # Extract cPanel username from A=dovecot_plain:user or A=login:user or U=user
    grep ' <= ' "$tmpfile" \
        | grep -oP '(?<=(A=dovecot_plain:|A=login:|A=plain:|U=))[a-zA-Z0-9_.-]+' \
        | sort | uniq -c | sort -rn | head -20 \
        | while read -r count user; do
            printf "  %-20s  ${GREEN}%s${NC}\n" "$user" "$count"
        done

    # If no authenticated users found, try sender domain
    local auth_count
    auth_count=$(grep ' <= ' "$tmpfile" | grep -cP '(A=dovecot_plain:|A=login:|A=plain:|U=)' 2>/dev/null || echo 0)
    if [[ $auth_count -eq 0 ]]; then
        echo -e "  ${YELLOW}No authenticated users found — showing sender domains:${NC}\n"
        grep ' <= ' "$tmpfile" \
            | grep -oP '(?<= <= )[^\s]+@[^\s]+' \
            | cut -d@ -f2 | sort | uniq -c | sort -rn | head -20 \
            | while read -r count domain; do
                printf "  %-30s  ${GREEN}%s${NC}\n" "$domain" "$count"
            done
    fi
    echo ""

    # ── per-sender-address top 20 ────────────────────────────
    echo -e "${BLUE}── Top Sender Addresses (From) ───────────────────${NC}"
    printf "  %-35s  %s\n" "FROM ADDRESS" "COUNT"
    echo "  ──────────────────────────────────────────────"
    grep ' <= ' "$tmpfile" \
        | grep -oP '(?<= <= )[^\s]+@[^\s]+' \
        | sort | uniq -c | sort -rn | head -15 \
        | while read -r count addr; do
            printf "  %-35s  ${GREEN}%s${NC}\n" "$addr" "$count"
        done
    echo ""

    # ── per outgoing IP stats (rotation pool + server IPs) ──────
    echo -e "${BLUE}── Mail Sent Per IP ──────────────────────────────${NC}"
    printf "  %-18s  %-8s  %-12s  %-10s  %s\n" "IP" "SENT" "IN ROTATION" "SENDING NOW" "LABEL/NOTE"
    echo "  ────────────────────────────────────────────────────────────"

    local current_ip=""
    [[ -f "$CURRENT_IP_FILE" ]] && current_ip=$(cat "$CURRENT_IP_FILE" | tr -d '[:space:]')

    # Collect all server IPs
    local all_server_ips=()
    while read -r sip; do
        all_server_ips+=("$sip")
    done < <(ip addr show 2>/dev/null \
        | grep 'inet ' \
        | awk '{print $2}' \
        | cut -d/ -f1 \
        | grep -v '^127\.' \
        | grep -v '^::' \
        | sort -u)

    # Build list of rotation-config IPs for lookup
    declare -A rotation_label rotation_status
    while IFS='|' read -r ip label _ enabled; do
        rotation_label["$ip"]="$label"
        rotation_status["$ip"]="$enabled"
    done < <(get_all_ips)

    # Track IPs already printed
    declare -A printed

    # ── print rotation IPs first ────────────────────────────────
    while IFS='|' read -r ip label _ enabled; do
        local escaped_ip cnt in_rot send_now note row_color
        escaped_ip=$(echo "$ip" | sed 's/\./\\./g')

        # Mail sent: try I=[ip]: field first (Exim interface log), fallback grep
        cnt=$(grep ' => ' "$tmpfile" \
            | grep -cP "I=\[${escaped_ip}\]" 2>/dev/null || true)
        [[ -z "$cnt" || "$cnt" == "0" ]] && \
            cnt=$(grep -c "I=\[${escaped_ip}\]" "$tmpfile" 2>/dev/null || echo 0)

        [[ "$enabled" == "1" ]] && in_rot="${GREEN}YES (active)${NC}" || in_rot="${YELLOW}YES (disabled)${NC}"
        [[ "$ip" == "$current_ip" ]] && send_now="${GREEN}● YES${NC}" || send_now="  no"
        note="$label"
        [[ "$ip" == "$current_ip" ]] && row_color="$GREEN" || row_color="$NC"

        printf "  ${row_color}%-18s${NC}  %-8s  " "$ip" "$cnt"
        echo -ne "$in_rot"
        printf "  "
        echo -ne "$send_now"
        printf "  %s\n" "$note"

        printed["$ip"]=1
    done < <(get_all_ips)

    # ── print remaining server IPs not in rotation ───────────────
    for sip in "${all_server_ips[@]}"; do
        [[ "${printed[$sip]+_}" ]] && continue

        local escaped cnt send_now note
        escaped=$(echo "$sip" | sed 's/\./\\./g')
        cnt=$(grep -c "I=\[${escaped}\]" "$tmpfile" 2>/dev/null || echo 0)
        [[ "$sip" == "$current_ip" ]] && send_now="${GREEN}● YES${NC}" || send_now="  no"

        # Guess if it's the main server IP
        local main_ip
        main_ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' || true)
        [[ "$sip" == "$main_ip" ]] && note="main server IP" || note="not in rotation"

        printf "  %-18s  %-8s  ${RED}%-12s${NC}  " "$sip" "$cnt" "NOT IN POOL"
        echo -ne "$send_now"
        printf "  ${YELLOW}%s${NC}\n" "$note"
    done

    unset rotation_label rotation_status printed
    echo ""

    # ── suggest adding unmanaged IPs ─────────────────────────────
    local unmanaged=0
    for sip in "${all_server_ips[@]}"; do
        local found=0
        while IFS='|' read -r ip _; do
            [[ "$ip" == "$sip" ]] && found=1 && break
        done < <(get_all_ips)
        [[ $found -eq 0 ]] && unmanaged=$((unmanaged+1))
    done
    if [[ $unmanaged -gt 0 ]]; then
        echo -e "  ${YELLOW}ℹ  $unmanaged server IP(s) are not in rotation pool.${NC}"
        echo -e "  ${YELLOW}   Run: eximip add  →  to include them.${NC}\n"
    fi

    # ── hourly distribution (today only) ────────────────────
    echo -e "${BLUE}── Hourly Distribution (${today}) ────────────────${NC}"
    printf "  %-6s  %s\n" "HOUR" "SENT"
    echo "  ──────────────────────"
    for h in $(seq -w 0 23); do
        local hcount
        hcount=$(grep "^${today} ${h}:" "$tmpfile" | grep -c ' => ' 2>/dev/null || echo 0)
        local bar=""
        local b
        for ((b=0; b<hcount/5; b++)); do bar+="█"; done
        printf "  %s:00  ${GREEN}%-4s${NC}  %s\n" "$h" "$hcount" "$bar"
    done
    echo ""

    # ── failed mail detail ───────────────────────────────────
    if [[ $total_failed -gt 0 ]]; then
        echo -e "${BLUE}── Recent Failures (last 10) ─────────────────────${NC}"
        grep ' \*\* ' "$tmpfile" | tail -10 | while read -r line; do
            echo -e "  ${RED}$line${NC}"
        done
        echo ""
    fi

    rm -f "$tmpfile"
    log "Stats viewed: days=$days delivered=$total_delivered failed=$total_failed"
}

# ── server IP overview ───────────────────────────────────────

show_server_ips() {
    print_header
    echo -e "${BLUE}=== Server IP Overview ===${NC}\n"

    local MAINLOG="/var/log/exim_mainlog"
    [[ ! -f "$MAINLOG" ]] && MAINLOG="/var/log/exim4/mainlog"

    local current_ip=""
    [[ -f "$CURRENT_IP_FILE" ]] && current_ip=$(cat "$CURRENT_IP_FILE" | tr -d '[:space:]')

    local today
    today=$(date '+%Y-%m-%d')

    # Main server IP (default route)
    local main_ip=""
    main_ip=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' || true)

    # All IPs on server
    local server_ips=()
    while read -r sip; do
        server_ips+=("$sip")
    done < <(ip addr show 2>/dev/null \
        | grep 'inet ' \
        | awk '{print $2}' \
        | cut -d/ -f1 \
        | grep -v '^127\.' \
        | sort -u)

    echo -e "${CYAN}Main server IP  : ${GREEN}${main_ip:-unknown}${NC}"
    echo -e "${CYAN}Current sending : ${GREEN}${current_ip:-not set}${NC}"
    echo -e "${CYAN}Total IPs       : ${#server_ips[@]}${NC}"
    echo -e "${CYAN}Log file        : $MAINLOG${NC}\n"

    echo -e "${CYAN}──────────────────────────────────────────────────────────────────${NC}"
    printf "  %-18s  %-8s  %-14s  %-10s  %s\n" \
        "IP ADDRESS" "TODAY" "ROTATION" "ACTIVE NOW" "ROLE / LABEL"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────${NC}"

    # Build rotation lookup
    declare -A rot_label rot_enabled
    while IFS='|' read -r ip label _ enabled; do
        rot_label["$ip"]="$label"
        rot_enabled["$ip"]="$enabled"
    done < <(get_all_ips)

    for sip in "${server_ips[@]}"; do
        local sent=0 rotation_col active_col role

        # Mail sent today via this IP (I=[ip]: in Exim log)
        if [[ -f "$MAINLOG" ]]; then
            local esc
            esc=$(echo "$sip" | sed 's/\./\\./g')
            sent=$(grep "^${today}" "$MAINLOG" \
                | grep -cP "I=\[${esc}\]" 2>/dev/null || echo 0)
        fi

        # Rotation status
        if [[ -n "${rot_label[$sip]+_}" ]]; then
            if [[ "${rot_enabled[$sip]}" == "1" ]]; then
                rotation_col="${GREEN}IN POOL (on)${NC}"
            else
                rotation_col="${YELLOW}IN POOL (off)${NC}"
            fi
            role="${rot_label[$sip]}"
        else
            rotation_col="${RED}NOT IN POOL${NC}"
            [[ "$sip" == "$main_ip" ]] && role="main server IP" || role="—"
        fi

        # Active now?
        if [[ "$sip" == "$current_ip" ]]; then
            active_col="${GREEN}● SENDING${NC}"
        else
            active_col="  —"
        fi

        # Row highlight for current sending IP
        if [[ "$sip" == "$current_ip" ]]; then
            printf "  ${GREEN}%-18s${NC}  %-8s  " "$sip" "$sent"
        else
            printf "  %-18s  %-8s  " "$sip" "$sent"
        fi
        echo -ne "$rotation_col"
        printf "  "
        echo -ne "$active_col"
        printf "  %s\n" "$role"
    done

    unset rot_label rot_enabled

    echo -e "${CYAN}──────────────────────────────────────────────────────────────────${NC}"

    # Count unmanaged IPs
    local unmanaged=0
    for sip in "${server_ips[@]}"; do
        local f=0
        while IFS='|' read -r ip _; do [[ "$ip" == "$sip" ]] && f=1 && break; done < <(get_all_ips)
        [[ $f -eq 0 ]] && unmanaged=$((unmanaged+1))
    done

    echo ""
    if [[ $unmanaged -gt 0 ]]; then
        echo -e "  ${YELLOW}⚠  $unmanaged IP(s) on this server are not in the rotation pool.${NC}"
        echo -e "  ${YELLOW}   Use: eximip add  →  to add them.${NC}"
    else
        echo -e "  ${GREEN}✓  All server IPs are in the rotation pool.${NC}"
    fi

    # Warn if main IP is sending (not in rotation)
    if [[ -n "$current_ip" && "$current_ip" == "$main_ip" ]]; then
        echo -e "\n  ${YELLOW}⚠  Main server IP is currently sending mail.${NC}"
        echo -e "  ${YELLOW}   Add more IPs and run: eximip update-ip${NC}"
    fi
    echo ""
}

# ── deliverability check ─────────────────────────────────────

check_deliverability() {
    # $1 = optional "fails" → only print failures & warnings
    local fails_only="${1:-}"

    print_header
    if [[ "$fails_only" == "fails" ]]; then
        echo -e "${BLUE}=== Deliverability Check — Failures & Warnings Only ===${NC}\n"
    else
        echo -e "${BLUE}=== Email Deliverability Check ===${NC}\n"
    fi

    command -v dig &>/dev/null || die "dig not found. Install: yum install bind-utils"
    command -v nc  &>/dev/null || { echo -e "${YELLOW}nc not found — port tests skipped (yum install nmap-ncat)${NC}\n"; NC_MISSING=1; }

    read -rp "Sending domain (e.g. example.com)  : " domain
    [[ -z "$domain" ]] && echo -e "${RED}Domain required.${NC}" && return 1

    read -rp "DKIM selector (default: mail)       : " dkim_selector
    dkim_selector="${dkim_selector:-mail}"

    local total_checks=0 passed=0 failed=0 warnings=0
    # issue_lines collects only fails/warns for the summary
    local issue_lines=()

    # ── output helpers ───────────────────────────────────────
    pass() {
        passed=$((passed+1)); total_checks=$((total_checks+1))
        [[ "$fails_only" != "fails" ]] && echo -e "  ${GREEN}✓${NC} $1"
    }
    fail() {
        failed=$((failed+1)); total_checks=$((total_checks+1))
        issue_lines+=("${RED}✗ FAIL${NC}  $1")
        echo -e "  ${RED}✗${NC} $1"
    }
    warn() {
        warnings=$((warnings+1)); total_checks=$((total_checks+1))
        issue_lines+=("${YELLOW}⚠ WARN${NC}  $1")
        echo -e "  ${YELLOW}⚠${NC} $1"
    }
    info() {
        [[ "$fails_only" != "fails" ]] && echo -e "  ${CYAN}ℹ${NC} $1"
    }
    section() {
        [[ "$fails_only" != "fails" ]] && echo -e "\n${BLUE}── $1 ──${NC}" || echo -e "\n${CYAN}[$1]${NC}"
    }

    # ════════════════════════════════════════════════════════
    section "MX Records"
    local mx_result
    mx_result=$(dig +short MX "$domain" 2>/dev/null | sort -n | head -5 || true)
    if [[ -n "$mx_result" ]]; then
        pass "MX record found for $domain"
        while read -r mx; do info "  $mx"; done <<< "$mx_result"
    else
        fail "No MX record found for $domain"
    fi

    # ════════════════════════════════════════════════════════
    section "SPF Record"
    local spf_record
    spf_record=$(dig +short TXT "$domain" 2>/dev/null | grep -i 'v=spf1' | tr -d '"' || true)

    if [[ -z "$spf_record" ]]; then
        fail "No SPF record found"
        info "Add: v=spf1 ip4:<your-ip> ~all"
    else
        pass "SPF record exists"
        info "$spf_record"

        # Check each active IP is covered by SPF
        while IFS='|' read -r ip _ _ _; do
            if echo "$spf_record" | grep -q "ip4:${ip}"; then
                pass "IP $ip is in SPF record"
            else
                # Check CIDR coverage
                local covered=0
                while read -r cidr; do
                    if [[ "$cidr" =~ ^ip4:([0-9.]+)/([0-9]+)$ ]]; then
                        # Simple /24 check — good enough for most cases
                        local net="${BASH_REMATCH[1]%.*}"
                        local ip_net="${ip%.*}"
                        [[ "$net" == "$ip_net" ]] && covered=1 && break
                    fi
                done < <(echo "$spf_record" | tr ' ' '\n' | grep '^ip4:')
                if [[ $covered -eq 1 ]]; then
                    pass "IP $ip covered by SPF CIDR block"
                else
                    fail "IP $ip NOT found in SPF record"
                    info "Add ip4:$ip to your SPF record"
                fi
            fi
        done < <(get_ips)

        # Check for common SPF mistakes
        if echo "$spf_record" | grep -q '+all'; then
            fail "SPF uses +all — allows anyone to send (very dangerous!)"
        elif echo "$spf_record" | grep -q '?all'; then
            warn "SPF uses ?all — neutral, provides no protection"
        elif echo "$spf_record" | grep -q '~all'; then
            pass "SPF uses ~all (softfail — good)"
        elif echo "$spf_record" | grep -q '-all'; then
            pass "SPF uses -all (hardfail — strict, best)"
        fi

        # Check DNS lookup count (max 10 allowed in SPF)
        local lookup_count
        lookup_count=$(echo "$spf_record" | grep -oP '(include:|a:|mx:|exists:)' | wc -l | tr -d ' ')
        if [[ $lookup_count -gt 8 ]]; then
            warn "SPF has $lookup_count DNS lookups (max 10 — close to limit)"
        fi
    fi

    # ════════════════════════════════════════════════════════
    section "DKIM Record"
    local dkim_record
    dkim_record=$(dig +short TXT "${dkim_selector}._domainkey.${domain}" 2>/dev/null | tr -d '"' | tr -d ' ' || true)

    if [[ -z "$dkim_record" ]]; then
        fail "No DKIM record found for selector '${dkim_selector}'"
        info "WHM → Email → DKIM Keys → Generate for $domain"
        info "Then check selector name matches (common: mail, default, dkim)"
    else
        pass "DKIM record found (selector: $dkim_selector)"
        if echo "$dkim_record" | grep -q 'p='; then
            local key_part
            key_part=$(echo "$dkim_record" | grep -oP 'p=[A-Za-z0-9+/=]+' | cut -c1-40)
            info "Public key: ${key_part}..."

            # Check key length (2048 bit recommended)
            local key_len
            key_len=$(echo "$dkim_record" | grep -oP 'p=[A-Za-z0-9+/=]+' | sed 's/p=//' | wc -c | tr -d ' ')
            if [[ $key_len -gt 350 ]]; then
                pass "DKIM key length looks like 2048-bit (recommended)"
            elif [[ $key_len -gt 170 ]]; then
                warn "DKIM key may be 1024-bit — consider upgrading to 2048-bit"
            fi
        else
            fail "DKIM record found but no public key (p=) — may be revoked"
        fi
    fi

    # ════════════════════════════════════════════════════════
    section "DMARC Record"
    local dmarc_record
    dmarc_record=$(dig +short TXT "_dmarc.${domain}" 2>/dev/null | tr -d '"' || true)

    if [[ -z "$dmarc_record" ]]; then
        fail "No DMARC record found"
        info "Add: _dmarc.${domain} TXT \"v=DMARC1; p=quarantine; rua=mailto:postmaster@${domain}\""
    else
        pass "DMARC record found"
        info "$dmarc_record"

        if echo "$dmarc_record" | grep -q 'p=none'; then
            warn "DMARC policy is 'none' — monitoring only, no enforcement"
        elif echo "$dmarc_record" | grep -q 'p=quarantine'; then
            pass "DMARC policy: quarantine (good)"
        elif echo "$dmarc_record" | grep -q 'p=reject'; then
            pass "DMARC policy: reject (strictest — best for deliverability)"
        fi

        if ! echo "$dmarc_record" | grep -q 'rua='; then
            warn "DMARC has no rua= — you won't receive failure reports"
        fi
    fi

    # ════════════════════════════════════════════════════════
    section "PTR / rDNS Check (per IP)"
    while IFS='|' read -r ip label _ _; do
        echo -e "  ${CYAN}$ip ($label)${NC}"
        local ptr
        ptr=$(dig +short -x "$ip" 2>/dev/null | sed 's/\.$//' || true)

        if [[ -z "$ptr" ]]; then
            fail "No PTR record for $ip — set rDNS in your hosting panel"
            continue
        fi
        pass "PTR found: $ptr"

        # Forward-confirmed rDNS: PTR should resolve back to the same IP
        local fwd
        fwd=$(dig +short A "$ptr" 2>/dev/null | head -1 || true)
        if [[ "$fwd" == "$ip" ]]; then
            pass "FCrDNS confirmed: $ptr → $ip"
        else
            warn "FCrDNS mismatch: $ptr resolves to '$fwd' (expected $ip)"
        fi

        # PTR hostname should match sending domain or contain it
        if echo "$ptr" | grep -qi "${domain}"; then
            pass "PTR hostname contains domain name"
        else
            warn "PTR '$ptr' does not contain domain '$domain' — may affect spam scores"
        fi
    done < <(get_ips)

    # ════════════════════════════════════════════════════════
    section "SMTP Port Connectivity (per IP)"
    if [[ "${NC_MISSING:-0}" == "1" ]]; then
        warn "nc not available — skipping port tests"
    else
        while IFS='|' read -r ip label _ _; do
            echo -e "  ${CYAN}$ip ($label)${NC}"
            for port in 25 465 587; do
                if nc -z -w5 "$ip" "$port" 2>/dev/null; then
                    pass "Port $port open on $ip"
                else
                    info "Port $port closed on $ip (may be intentional)"
                fi
            done
        done < <(get_ips)
    fi

    # ════════════════════════════════════════════════════════
    section "SMTP Banner Check (per IP)"
    while IFS='|' read -r ip label _ _; do
        echo -e "  ${CYAN}$ip ($label)${NC}"
        local banner
        banner=$(echo "QUIT" | timeout 5 nc "$ip" 25 2>/dev/null | head -1 || true)
        if [[ -n "$banner" ]]; then
            pass "SMTP banner: $banner"
            # Banner hostname should match PTR
            local banner_host
            banner_host=$(echo "$banner" | grep -oP '(?<=220 )\S+' || true)
            local ptr_check
            ptr_check=$(dig +short -x "$ip" 2>/dev/null | sed 's/\.$//' || true)
            if [[ -n "$banner_host" && -n "$ptr_check" && "$banner_host" == "$ptr_check" ]]; then
                pass "Banner hostname matches PTR record"
            elif [[ -n "$banner_host" && -n "$ptr_check" ]]; then
                warn "Banner hostname '$banner_host' ≠ PTR '$ptr_check'"
            fi
        else
            warn "Could not reach SMTP on $ip:25 (firewall or timeout)"
        fi
    done < <(get_ips)

    # ════════════════════════════════════════════════════════
    # Final score + issues summary
    local score=0
    [[ $total_checks -gt 0 ]] && score=$(( (passed * 100) / total_checks ))

    echo -e "\n${CYAN}══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  DELIVERABILITY SCORE — $domain${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    printf "  Passed  : ${GREEN}%d${NC}\n"  "$passed"
    printf "  Warnings: ${YELLOW}%d${NC}\n" "$warnings"
    printf "  Failed  : ${RED}%d${NC}\n"   "$failed"
    printf "  Total   : %d checks\n"        "$total_checks"
    echo ""

    if   [[ $score -ge 90 ]]; then
        echo -e "  Score: ${GREEN}${score}/100 — Excellent${NC}"
    elif [[ $score -ge 70 ]]; then
        echo -e "  Score: ${YELLOW}${score}/100 — Good (fix warnings)${NC}"
    elif [[ $score -ge 50 ]]; then
        echo -e "  Score: ${YELLOW}${score}/100 — Fair (fix failures first)${NC}"
    else
        echo -e "  Score: ${RED}${score}/100 — Poor (mail likely going to spam)${NC}"
    fi

    # Always show issues summary at the end
    if [[ ${#issue_lines[@]} -gt 0 ]]; then
        echo -e "\n${RED}── Issues to fix ──────────────────────────────${NC}"
        for line in "${issue_lines[@]}"; do
            echo -e "  $line"
        done
    else
        echo -e "\n  ${GREEN}No failures or warnings — all checks passed!${NC}"
    fi

    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    log "Deliverability check: $domain score=$score passed=$passed warn=$warnings failed=$failed"
}

# ── cPanel IP add guide ──────────────────────────────────────

show_ip_add_guide() {
    print_header
    echo -e "${BLUE}=== Safe IP Addition Guide for WHM/cPanel ===${NC}"
    echo -e "${RED}  Read every step before touching anything on a live server.${NC}\n"

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}PHASE 1 — Get the IP from your provider (BEFORE server touch)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << 'GUIDE'

  [ ] 1. Hosting panel (Hetzner/OVH/Vultr/Linode etc.) থেকে
         নতুন IP টা server এ assign করো।
         → এটা না করলে WHM তে IP add করলেও কাজ করবে না।

  [ ] 2. Reverse DNS (PTR) সেট করো hosting panel থেকে:
         IP → mail.yourdomain.com
         (এটা পরে করলেও হয়, কিন্তু আগে করলে ভালো)

  [ ] 3. IP টা ping করো নিশ্চিত হতে:
         ping -c 3 <new-ip>
         → response না পেলে server এ assigned হয়নি

GUIDE

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}PHASE 2 — WHM এ IP যোগ করো (downtime নেই)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << 'GUIDE'

  [ ] 1. WHM → IP Functions → Add a New IP Address

  [ ] 2. Fields:
         • New IP or IP range : <your-new-ip>
         • Subnet Mask        : 255.255.255.0  (বা provider যা দিয়েছে)
         • Assign to ethernet : eth0  (অথবা server এর interface নাম)

         ⚠ "Assign to Ethernet Device" — eth0 এর জায়গায়
           তোমার server এর সঠিক interface দাও।
           দেখতে: ip addr | grep -E 'eth|ens|bond'

  [ ] 3. Submit করো।

  [ ] 4. Verify করো — WHM → IP Functions → Show IP Address Usage
         নতুন IP দেখাচ্ছে কিনা এবং "Unassigned" আছে কিনা।

  ✓ এই পর্যন্ত কোনো existing account বা mail এ কোনো প্রভাব পড়েনি।

GUIDE

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}PHASE 3 — IP কে "Unassigned" রাখো (critical)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << 'GUIDE'

  ⚠ IMPORTANT: নতুন IP কে কোনো cPanel account এ assign করো না।
    Rotation এর জন্য IP শুধু Exim outgoing interface এ use হবে।
    কোনো account এ assign করলে সেই account এর website/mail
    নতুন IP তে চলে যাবে — বিপদ।

  ✓ WHM → Show IP Address Usage → নতুন IP "Unassigned" থাকুক।

GUIDE

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}PHASE 4 — DNS records (mail delivery এর জন্য required)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << 'GUIDE'

  [ ] 1. SPF record আপডেট করো — নতুন IP যোগ করো:
         yourdomain.com  TXT  "v=spf1 ip4:OLD_IP ip4:NEW_IP ~all"

  [ ] 2. PTR (rDNS) — hosting panel এ:
         NEW_IP → mail.yourdomain.com

  [ ] 3. Forward-confirmed rDNS verify করো (PTR add করার পর):
         dig +short -x NEW_IP
         dig +short A mail.yourdomain.com
         → দুটো একই IP দেখাবে

  [ ] 4. DKIM — নতুন IP এর জন্য আলাদা DKIM লাগে না।
         একটা domain এর একটা DKIM key সব IP cover করে।

GUIDE

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}PHASE 5 — Exim এ যোগ করো (একবারই করতে হয়)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << 'GUIDE'

  প্রথমবার setup (setup-guide দেখো):
  [ ] WHM → Exim Configuration Manager → Advanced Editor
  [ ] remote_smtp transport এ যোগ করো:
        interface = ${readfile{/etc/exim_current_ip}{}}
  [ ] Save → WHM automatically rebuild + restart করবে

  নতুন IP প্রতিবার:
  [ ] eximip add       → IP ও label দাও
  [ ] eximip update-ip → এখনই rotation এ নাও

  ✓ Exim restart লাগে না।
  ✓ Existing mail delivery বাধাগ্রস্ত হয় না।

GUIDE

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}PHASE 6 — IP Warm-up (নতুন IP এর জন্য mandatory)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << 'GUIDE'

  নতুন IP থেকে হঠাৎ বেশি mail পাঠালে blacklist হয়।
  Gmail/Yahoo নতুন IP কে বিশ্বাস করে না।

  Recommended warm-up schedule:
  ┌─────────┬────────────────────────────────────┐
  │ Day 1–3 │ max 50–100 mails/day               │
  │ Day 4–7 │ max 200–500 mails/day              │
  │ Week 2  │ max 1,000–2,000 mails/day          │
  │ Week 3  │ max 5,000 mails/day                │
  │ Week 4+ │ normal volume                      │
  └─────────┴────────────────────────────────────┘

  eximip add করার সময় hourly limit কম দাও (প্রথম সপ্তাহে 50–100)।
  পরে eximip remove → re-add দিয়ে limit বাড়াও।

GUIDE

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}সতর্কতা — এগুলো কখনো করবে না${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << 'GUIDE'

  ✗ নতুন IP কে main server IP বানাবে না
  ✗ নতুন IP কে কোনো cPanel account এ assign করবে না
  ✗ SPF ছাড়া IP rotation চালু করবে না
  ✗ PTR ছাড়া mail পাঠাবে না (Gmail reject করে)
  ✗ Warm-up ছাড়া নতুন IP থেকে bulk mail দেবে না
  ✗ Exim config manually edit করবে না WHM rebuild এর পরে

GUIDE

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}Quick checklist — IP add এর আগে${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Run করো: ${GREEN}eximip deliverability-fails${NC}"
    echo -e "  → বর্তমান সমস্যা দেখাবে, আগে ঠিক করো"
    echo ""
    echo -e "  Run করো: ${GREEN}eximip blacklist${NC}"
    echo -e "  → নতুন IP blacklist এ আছে কিনা দেখো"
    echo ""
    echo -e "  Run করো: ${GREEN}eximip add${NC}"
    echo -e "  → IP যোগ করো"
    echo ""
}

# ── menu ─────────────────────────────────────────────────────

main_menu() {
    while true; do
        print_header
        echo -e "  ${GREEN}1)${NC} List IPs (rotation pool)"
        echo -e "  ${GREEN}i)${NC} Server IP overview (all IPs + sending status)"
        echo -e "  ${GREEN}2)${NC} Add IP manually"
        echo -e "  ${GREEN}a)${NC} Auto-sync — detect & add all server IPs"
        echo -e "  ${GREEN}3)${NC} Remove IP"
        echo -e "  ${GREEN}4)${NC} Enable / Disable IP"
        echo -e "  ${GREEN}5)${NC} Update current sending IP now"
        echo -e "  ${GREEN}6)${NC} Live rotation schedule (24h)"
        echo -e "  ${GREEN}7)${NC} Blacklist check"
        echo -e "  ${GREEN}8)${NC} DNS / SPF / PTR helper"
        echo -e "  ${GREEN}9)${NC} View logs"
        echo -e "  ${GREEN}m)${NC} Mail send statistics (daily / user / IP)"
        echo -e "  ${GREEN}d)${NC} Deliverability check — full report"
        echo -e "  ${GREEN}f)${NC} Deliverability check — failures & warnings only"
        echo -e "  ${GREEN}g)${NC} cPanel IP add guide (safe step-by-step)"
        echo -e "  ${CYAN}s)${NC} WHM setup guide (read first!)"
        echo -e "  ${CYAN}c)${NC} Install hourly cron"
        echo -e "  ${RED}0)${NC} Exit"
        echo ""
        read -rp "Select: " choice

        case $choice in
            1) list_ips ;;
            i) show_server_ips ;;
            2) add_ip ;;
            a) sync_server_ips ;;
            3) remove_ip ;;
            4) toggle_ip ;;
            5) update_current_ip ;;
            6) show_status ;;
            7) check_blacklist ;;
            8) dns_check ;;
            9) show_logs ;;
            m) show_mail_stats ;;
            d) check_deliverability ;;
            f) check_deliverability fails ;;
            g) show_ip_add_guide ;;
            s) show_setup_guide ;;
            c) install_cron ;;
            0) echo -e "\n${GREEN}Done.${NC}\n"; exit 0 ;;
            *) echo -e "${RED}Invalid.${NC}" ;;
        esac

        echo ""
        read -rp "Press Enter to continue..."
    done
}

# ── init ─────────────────────────────────────────────────────

init_config

case "${1:-menu}" in
    menu)          main_menu ;;
    add)           add_ip ;;
    remove)        remove_ip ;;
    list)          list_ips ;;
    status)        show_status ;;
    update-ip)     update_current_ip ;;
    cron-rotate)   cron_rotate ;;
    blacklist)     check_blacklist ;;
    dns)           dns_check ;;
    logs)          show_logs ;;
    install-cron)      install_cron ;;
    remove-cron)       remove_cron ;;
    setup-guide)       show_setup_guide ;;
    version|--version|-v)  echo "exim_ip_manager v${VERSION}" ;;
    sync)                  sync_server_ips ;;
    server-ips)            show_server_ips ;;
    stats)                 show_mail_stats ;;
    deliverability)        check_deliverability ;;
    deliverability-fails)  check_deliverability fails ;;
    ip-add-guide)          show_ip_add_guide ;;
    *)
        echo "Usage: $0 [menu|add|remove|list|status|update-ip|blacklist|dns|logs|stats|install-cron|setup-guide|deliverability|deliverability-fails|ip-add-guide]"
        exit 1
        ;;
esac
