# openwrt-ipv6-off

[Русский](README.md) · **English** · [中文](README.zh-CN.md)

A single-script manager for disabling **IPv6** on **OpenWrt**: backs up your current settings, disables IPv6, **auto-rolls back over IPv4** if connectivity is lost, and provides precise status checks and diagnostics. Pure `ash`/BusyBox, no dependencies.

One run fully disables IPv6 (network / dhcp / firewall / odhcpd), and if something goes wrong there's a safety net: if IPv4 connectivity doesn't come back, the settings restore themselves.

## Why

[#why](#why)

IPv6 on a router can get in the way: a broken prefix from the ISP, RA/DHCPv6 clashing with your LAN, traffic leaking around your proxy/VPN past the IPv4 rules, DNS breakage. Disabling it by hand means editing several UCI sections (`network`, `dhcp`, `firewall`) plus `odhcpd` — and it's easy to either forget the original state or lock yourself out of a remote router.

This script removes the chore and the risk: it does everything in one action, with a full backup of the current config and a watchdog that automatically rolls back if IPv4 connectivity fails to return after the change.

## Requirements

[#requirements](#requirements)

- OpenWrt (`ash`/BusyBox). Tested on fw4/nftables (22.03+) and fw3/iptables — restore copies the raw `/etc/config/*` files, so it doesn't depend on the firewall backend.
- Root access over SSH (or the local console).
- A little space in `/root` for backups and the log (a few KB).

## What the script does

[#what-the-script-does](#what-the-script-does)

1. **Backup.** Takes an exact copy of `network`, `dhcp`, `firewall` (raw `/etc/config/*`) and records the `odhcpd` state, so a rollback restores exactly what was there — with no duplicated rules.
2. **Watchdog.** Launches a standalone safety net in `/tmp`: after disabling, it checks IPv4 connectivity (`ping 1.1.1.1 / 8.8.8.8`) and restores the backup by itself if the link doesn't come up. It runs independently of the SSH session and survives a disconnect.
3. **Disable IPv6 in UCI.** Removes `ula_prefix`, sets `lan.ip6assign=0`, `wan.reqaddress=none` / `reqprefix=no`, deletes `wan6`, turns off `dhcpv6`/`ra`/`ndp` on lan and wan, and clears IPv6 firewall rules (in reverse index order — otherwise the indices shift).
4. **odhcpd.** Stops the service and disables autostart.
5. *(Optional)* **sysctl.** A hard kernel-level IPv6 disable with a persistent `/etc/sysctl.d/` entry — enabled via the `--hard` flag or the menu prompt.
6. Restarts firewall and network, then shows a precise verification of the result.

Nothing is irreversible: every run starts with a backup, and restore is available from the menu, via the `--restore-last` flag, or manually from `/root/ipv6-off/backups/`.

## Installation

[#installation](#installation)

Run the commands **on the router** (over SSH), not on your computer. Download and read the code first, then run it:

```
wget https://raw.githubusercontent.com/lastik9/openwrt-ipv6-off/main/ipv6-off.sh
cat ipv6-off.sh        # review before running
sh ipv6-off.sh
```

If BusyBox's built-in `wget` complains about HTTPS/SSL, use `uclient-fetch`:

```
uclient-fetch -O ipv6-off.sh https://raw.githubusercontent.com/lastik9/openwrt-ipv6-off/main/ipv6-off.sh
```

## Usage

[#usage](#usage)

With no arguments it opens an interactive menu (disable / check / diagnostics / log / restore / manage backups).

Non-interactive, for automation and testing:

```
sh ipv6-off.sh --disable --yes        # disable IPv6 (backup + watchdog)
sh ipv6-off.sh --disable --yes --hard # same, plus kernel-level disable (sysctl)
sh ipv6-off.sh --restore-last --yes   # roll back the latest backup
sh ipv6-off.sh --check                # detailed check; exit code 0 = off, 1 = on
sh ipv6-off.sh --status               # prints ON / OFF
sh ipv6-off.sh --diag                 # collect diagnostics to a file
sh ipv6-off.sh --help                 # help
```

## If you lose access after disabling

[#if-you-lose-access-after-disabling](#if-you-lose-access-after-disabling)

1. Wait ~1 minute — the watchdog rolls back automatically if IPv4 didn't come up.
2. If that doesn't help, connect from the LAN and run `sh ipv6-off.sh --restore-last --yes`.
3. As a last resort, do it manually:

```
cp -a /root/ipv6-off/backups/<latest>/{network,dhcp,firewall} /etc/config/
/etc/init.d/firewall restart && /etc/init.d/network restart
```

## Files

[#files](#files)

| What | Path |
| --- | --- |
| Log (rotated at ~400 KB) | `/root/ipv6-off/ipv6-off.log` |
| Backups | `/root/ipv6-off/backups/<timestamp>/` |
| Diagnostics | `/root/ipv6-off/ipv6-diag-<timestamp>.txt` |
| Watchdog (generated) | `/tmp/ipv6_watchdog.sh` |

## Compatibility

[#compatibility](#compatibility)

Tested on OpenWrt with fw4/nftables (22.03+) and fw3/iptables. The firewall restore is backend-independent because settings are returned by copying `/etc/config/firewall`.

The `--hard` (sysctl) flag also disables link-local IPv6 — use it deliberately, only when there are no IPv6-only services on the LAN and the ISP doesn't depend on IPv6.

## Credits

[#credits](#credits)

Menu styling and overall approach follow the [openwrt-ssclash](https://github.com/lastik9/openwrt-ssclash) installer. The script uses OpenWrt's native mechanisms (`uci`, `odhcpd`, `/etc/init.d/*`); all credit for the system itself goes to its authors.

## License

[#license](#license)

[MIT](LICENSE) © 2026 lastik9
