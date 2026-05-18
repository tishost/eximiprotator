# Exim IP Rotation Manager

WHM/cPanel server এ multiple IP থেকে email rotation manage করার CLI tool।

**Version:** 1.0.0

## Features

- Hourly IP rotation — Exim restart ছাড়াই
- cPanel user-wise daily mail statistics
- SPF / DKIM / DMARC / PTR / SMTP deliverability audit
- DNSBL blacklist check (Spamhaus, Barracuda, SpamCop ++)
- Safe cPanel IP add guide (warm-up schedule সহ)
- Existing cPanel accounts এ কোনো প্রভাব নেই

## Quick Start

```bash
# Server এ upload করো
scp exim_ip_manager.sh install.sh root@YOUR_SERVER:/tmp/

# Install
ssh root@YOUR_SERVER
cd /tmp && chmod +x install.sh && ./install.sh

# চালাও
eximip
```

## Usage

```bash
eximip                      # Interactive menu
eximip add                  # IP যোগ করো
eximip stats                # Mail statistics
eximip deliverability-fails # Deliverability সমস্যা দেখো
eximip blacklist            # Blacklist check
eximip ip-add-guide         # Safe IP add guide
eximip --version
```

বিস্তারিত: [USERGUIDE.md](USERGUIDE.md)

## Requirements

- WHM/cPanel server (root access)
- `bind-utils` (`dig`) — `yum install bind-utils`
- `nmap-ncat` (`nc`) — `yum install nmap-ncat`

## License

MIT
