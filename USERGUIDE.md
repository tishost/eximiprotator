# Exim IP Rotation Manager — User Guide
### WHM/cPanel Server এর জন্য

---

## সূচিপত্র

1. [এই tool কী করে](#এই-tool-কী-করে)
2. [Install করার আগে](#install-করার-আগে)
3. [Installation](#installation)
4. [WHM এ একবারের setup](#whm-এ-একবারের-setup)
5. [প্রথম IP যোগ করা](#প্রথম-ip-যোগ-করা)
6. [Daily ব্যবহার](#daily-ব্যবহার)
7. [Mail Statistics দেখা](#mail-statistics-দেখা)
8. [Deliverability Check](#deliverability-check)
9. [IP Blacklist হলে কী করবে](#ip-blacklist-হলে-কী-করবে)
10. [নতুন IP যোগ করার safe পদ্ধতি](#নতুন-ip-যোগ-করার-safe-পদ্ধতি)
11. [সব command এর তালিকা](#সব-command-এর-তালিকা)
12. [Troubleshooting](#troubleshooting)

---

## এই tool কী করে

এই script WHM/cPanel server এ একাধিক IP থেকে email পাঠানোর rotation manage করে।

**কাজের ধরন:**
- প্রতি ঘণ্টায় স্বয়ংক্রিয়ভাবে নতুন IP থেকে mail পাঠায়
- একটা IP blacklist হলে বাকিগুলো দিয়ে চলতে থাকে
- Exim restart ছাড়াই IP switch হয় — server এ কোনো downtime নেই
- Existing cPanel user এবং domain এ কোনো প্রভাব পড়ে না

**কী কী দেখা যায়:**
- কোন IP থেকে কতটা mail গেছে
- কোন cPanel user কতটা mail পাঠিয়েছে
- প্রতিদিনের delivery / failure / deferred count
- SPF, DKIM, DMARC, PTR সব ঠিক আছে কিনা

---

## Install করার আগে

নিশ্চিত করো:

```
[ ] Server এ root access আছে
[ ] dig ইন্সটল আছে       → yum install bind-utils
[ ] nc ইন্সটল আছে        → yum install nmap-ncat
[ ] WHM/cPanel access আছে
[ ] নতুন IP গুলো hosting provider এর panel এ server এ assigned
```

---

## Installation

```bash
# ১. ফাইল server এ আপলোড করো (local machine থেকে)
scp exim_ip_manager.sh install.sh root@YOUR_SERVER_IP:/tmp/

# ২. Server এ SSH করো
ssh root@YOUR_SERVER_IP

# ৩. Install করো
cd /tmp
chmod +x install.sh exim_ip_manager.sh
./install.sh

# ৪. এখন যেকোনো জায়গা থেকে চালাও
eximip
```

Install হলে `eximip` command সব জায়গা থেকে কাজ করবে।

---

## WHM এ একবারের setup

> এটা শুধু একবার করতে হবে। পরে IP add/remove করলে আর করতে হবে না।

**Step 1 — WHM Exim Configuration Manager**
```
WHM → Service Configuration → Exim Configuration Manager → Advanced Editor
```

**Step 2 — `remote_smtp` transport খোঁজো**

`Ctrl+F` দিয়ে `remote_smtp:` খোঁজো। এরকম দেখাবে:
```
remote_smtp:
  driver = smtp
  ...
```

**Step 3 — interface line যোগ করো**

`driver = smtp` এর নিচে এই line যোগ করো:
```
  interface = ${readfile{/etc/exim_current_ip}{}}
```

**Step 4 — Save**

WHM নিজেই Exim rebuild ও restart করবে।

**Step 5 — Cron install করো**
```bash
eximip install-cron
```

এরপর প্রতি ঘণ্টায় IP স্বয়ংক্রিয়ভাবে rotate হবে।

---

## প্রথম IP যোগ করা

```bash
eximip add
```

জিজ্ঞেস করবে:
```
Enter IP address     : 1.2.3.4
Label (e.g. Server1) : Main-IP
Hourly send limit    : 500
```

> **Warm-up এর জন্য প্রথম সপ্তাহে limit কম রাখো (50–100)**

তারপর:
```bash
eximip update-ip    # এখনই rotation এ নাও
```

---

## Daily ব্যবহার

### Menu খোলা
```bash
eximip
```

### IP list দেখা
```bash
eximip list
```
আউটপুট:
```
IP ADDRESS         LABEL           HOURLY LIMIT  STATUS
──────────────────────────────────────────────────────
1.2.3.4            Main-IP         500           ACTIVE
5.6.7.8            Backup-IP       300           ACTIVE
9.10.11.12         New-IP          100           DISABLED
```

### Rotation schedule দেখা
```bash
eximip status
```
দেখাবে কোন ঘণ্টায় কোন IP use হবে এবং পরবর্তী switch কতক্ষণে।

### IP সাময়িক বন্ধ করা
```bash
eximip menu → 4 → IP টাইপ করো
```
অথবা সরাসরি:
```bash
eximip menu
# 4 নির্বাচন করো, IP দাও
```

---

## Mail Statistics দেখা

```bash
eximip stats
```

অথবা menu থেকে **m** চাপো।

জিজ্ঞেস করবে কতদিনের data দেখতে চাও (1–30)।

**দেখাবে:**

```
══════════════════════════════════════════════
  OVERALL SUMMARY
══════════════════════════════════════════════
  Queued/Accepted    : 4521
  Delivered          : 4489
  Deferred           : 12
  Failed/Bounced     : 20

── Daily Breakdown ──────────────────────────────
  DATE          DELIVERED   DEFERRED    FAILED
  2024-01-15    1523        4           7
  2024-01-14    1489        5           8
  2024-01-13    1477        3           5

── Top Senders (cPanel user) ─────────────────────
  CPANEL USER           MESSAGES SENT
  john                  1200
  newsletter            890
  support               450

── Top Sender Addresses (From) ───────────────────
  FROM ADDRESS                         COUNT
  newsletter@yourdomain.com            890
  support@yourdomain.com               450

── Sent Per Outgoing IP ──────────────────────────
  IP                  SENT        LABEL
  1.2.3.4             2300        Main-IP
  5.6.7.8             2189        Backup-IP

── Hourly Distribution (2024-01-15) ────────────
  00:00  45    █████████
  01:00  23    ████
  ...
  09:00  312   ██████████████████████████████████
```

---

## Deliverability Check

### সব check দেখা
```bash
eximip deliverability
```

### শুধু সমস্যা দেখা (recommended)
```bash
eximip deliverability-fails
```

Domain এবং DKIM selector জিজ্ঞেস করবে।

**Check করে:**

| Check | কী দেখে |
|-------|--------|
| MX | Domain এর MX record আছে কিনা |
| SPF | সব IP authorized কিনা, policy সঠিক কিনা |
| DKIM | Selector আছে কিনা, key 2048-bit কিনা |
| DMARC | Policy কী, reporting address আছে কিনা |
| PTR | প্রতিটা IP এর rDNS আছে কিনা |
| FCrDNS | PTR → forward lookup same IP দেয় কিনা |
| Port | 25, 465, 587 open কিনা |
| SMTP Banner | Banner hostname PTR এর সাথে মেলে কিনা |

শেষে score দেয়:
```
  Score: 85/100 — Good (fix warnings)

── Issues to fix ──────────────────────────────
  ⚠ WARN  PTR 'srv.host.com' does not contain domain 'yourdomain.com'
  ⚠ WARN  DMARC policy is 'none' — monitoring only
```

---

## IP Blacklist হলে কী করবে

### ১. Blacklist check করো
```bash
eximip blacklist
```

### ২. Blacklisted IP disable করো
```bash
eximip menu → 4 → IP দাও
```
IP disable হলে সেটা rotation থেকে বাদ পড়বে। অন্য IP দিয়ে mail চলতে থাকবে।

### ৩. Delisting request করো

| Blacklist | Delisting URL |
|-----------|--------------|
| Spamhaus | https://check.spamhaus.org |
| Barracuda | https://www.barracudacentral.org/rbl/removal-request |
| SpamCop | https://www.spamcop.net/bl.shtml |

### ৪. কারণ খোঁজো
```bash
# কে বেশি mail পাঠাচ্ছে দেখো
eximip stats

# কোন account থেকে spam যাচ্ছে দেখো
grep "$(date '+%Y-%m-%d')" /var/log/exim_mainlog | grep ' <= ' | \
  grep -oP '(?<=(A=dovecot_plain:|U=))[a-zA-Z0-9_]+' | sort | uniq -c | sort -rn
```

---

## নতুন IP যোগ করার safe পদ্ধতি

```bash
eximip ip-add-guide
```

সংক্ষেপে:

```
১. Hosting panel এ IP টা server এ assign করো
২. ping করে verify করো
   ping -c 3 NEW_IP

৩. WHM → IP Functions → Add a New IP Address
   ⚠ কোনো cPanel account এ assign করবে না

৪. SPF record এ নতুন IP যোগ করো
   v=spf1 ip4:OLD_IP ip4:NEW_IP ~all

৫. PTR/rDNS set করো hosting panel এ
   NEW_IP → mail.yourdomain.com

৬. eximip add → limit কম দাও (warm-up)

৭. eximip update-ip
```

**Warm-up schedule:**

| সময় | দৈনিক limit |
|------|------------|
| ১ম সপ্তাহ | ৫০–১০০ |
| ২য় সপ্তাহ | ৫০০–১০০০ |
| ৩য় সপ্তাহ | ৩০০০–৫০০০ |
| ৪র্থ সপ্তাহ+ | স্বাভাবিক |

---

## সব command এর তালিকা

```bash
eximip                      # Interactive menu
eximip add                  # নতুন IP যোগ করো
eximip remove               # IP বাদ দাও
eximip list                 # সব IP দেখো
eximip status               # Rotation schedule দেখো
eximip update-ip            # IP ফাইল এখনই আপডেট করো
eximip stats                # Mail send statistics
eximip blacklist            # DNSBL blacklist check
eximip deliverability       # Full deliverability audit
eximip deliverability-fails # শুধু সমস্যা দেখো
eximip dns                  # SPF/PTR/DKIM recommendation
eximip ip-add-guide         # নতুন IP যোগ করার guide
eximip install-cron         # Hourly rotation cron install
eximip remove-cron          # Cron বাদ দাও
eximip setup-guide          # WHM setup guide
eximip logs                 # Rotation activity log
```

---

## Troubleshooting

### Mail যাচ্ছে না

```bash
# ১. Current IP সেট আছে কিনা
cat /etc/exim_current_ip

# ২. Active IP আছে কিনা
eximip list

# ৩. Exim চলছে কিনা
service exim status

# ৪. Exim এ interface line আছে কিনা (WHM → Advanced Editor)
grep -i 'readfile' /etc/exim.conf
```

### IP switch হচ্ছে না

```bash
# Cron আছে কিনা
crontab -l | grep eximip

# নেই? Install করো:
eximip install-cron

# হাতে switch করো:
eximip update-ip
```

### `dig not found` error

```bash
yum install bind-utils -y
```

### `nc not found` error

```bash
yum install nmap-ncat -y
```

### WHM Exim rebuild করার পর interface চলে গেছে

WHM rebuild করলে `/etc/exim.conf` regenerate হয় কিন্তু `interface` line থাকলে সাধারণত ঠিকই থাকে।  
না থাকলে আবার [WHM এ একবারের setup](#whm-এ-একবারের-setup) করো।

### Log দেখা

```bash
eximip logs                              # rotation log
tail -f /var/log/exim_mainlog            # live Exim log
tail -f /var/log/exim_ip_rotation.log   # এই script এর log
```

---

## ফাইলের তালিকা

| ফাইল | কাজ |
|------|-----|
| `/usr/local/exim-ip-manager/exim_ip_manager.sh` | Main script |
| `/etc/exim_rotation.conf` | IP pool config |
| `/etc/exim_current_ip` | বর্তমান active IP |
| `/var/log/exim_ip_rotation.log` | Rotation activity log |
| `/etc/logrotate.d/exim-ip-rotation` | Log rotation config |

---

*Exim IP Rotation Manager — WHM/cPanel*
