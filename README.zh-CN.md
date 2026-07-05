# openwrt-ipv6-off

[Русский](README.md) · [English](README.en.md) · **中文**

用单个脚本在 **OpenWrt** 上关闭 **IPv6**：备份当前设置、关闭 IPv6、在连接丢失时**基于 IPv4 自动回滚**，并提供精确的状态检查与诊断。纯 `ash`/BusyBox，无依赖。

运行一次即可完整关闭 IPv6（network / dhcp / firewall / odhcpd）；万一出问题也有保险：如果 IPv4 连接没有恢复，设置会自动还原。

## 为什么需要它

[#为什么需要它](#为什么需要它)

路由器上的 IPv6 有时只会添乱：运营商下发的前缀有问题、RA/DHCPv6 与本地网络冲突、流量绕过代理/VPN 从 IPv4 规则之外泄漏、DNS 异常。手动关闭需要修改多个 UCI 配置段（`network`、`dhcp`、`firewall`）以及 `odhcpd`，很容易忘记原始状态，或者把自己从远程路由器上锁在门外。

本脚本消除了这些琐事和风险：一步完成全部操作，先完整备份当前配置，并由 watchdog 保驾护航——如果关闭后 IPv4 连接没有恢复，它会自动回滚。

## 要求

[#要求](#要求)

- OpenWrt（`ash`/BusyBox）。已在 fw4/nftables（22.03+）与 fw3/iptables 上测试——还原是通过复制原始 `/etc/config/*` 文件完成的，因此与防火墙后端无关。
- 通过 SSH 的 root 访问（或本地控制台）。
- `/root` 下少量空间用于备份和日志（几 KB）。

## 脚本做了什么

[#脚本做了什么](#脚本做了什么)

1. **备份。** 精确复制 `network`、`dhcp`、`firewall`（原始 `/etc/config/*`）并记录 `odhcpd` 状态，使回滚能还原到原样，且不会重复规则。
2. **Watchdog。** 在 `/tmp` 启动一个独立的保险程序：关闭后它检查 IPv4 连接（依次 ping `1.1.1.1`、`8.8.8.8`、`77.88.8.8`、`77.88.8.1`——只要有一个响应即视为成功），若链路未恢复则自动还原备份。它独立于 SSH 会话运行，能在断连后继续工作。列表中的 Yandex 地址是为处于白名单后（Cloudflare/Google 可能不可达）的路由器提供的兜底；该列表由脚本开头的 `WD_PING_HOSTS` 变量设置。
3. **在 UCI 中关闭 IPv6。** 移除 `ula_prefix`，设置 `lan.ip6assign=0`、`wan.reqaddress=none` / `reqprefix=no`，删除 `wan6`，在 lan 与 wan 上关闭 `dhcpv6`/`ra`/`ndp`，并清理 IPv6 防火墙规则（按索引倒序删除——否则索引会错位）。
4. **odhcpd。** 停止服务并禁用自启动。
5. *(可选)* **sysctl。** 通过持久化的 `/etc/sysctl.d/` 在内核层面强制关闭 IPv6——由 `--hard` 参数或菜单提示启用。
6. 重启防火墙与网络，然后显示对结果的精确校验。

一切均可逆：每次运行都以备份开始，还原可通过菜单、`--restore-last` 参数，或从 `/root/ipv6-off/backups/` 手动完成。

## 安装

[#安装](#安装)

命令需**在路由器上**（通过 SSH）执行。安装器会下载脚本，显示简短摘要（版本、大小、SHA256、功能说明），并可按需在分页器中翻阅源码——不会把全部代码刷屏：

```
wget -O install.sh https://raw.githubusercontent.com/lastik9/openwrt-ipv6-off/main/install.sh
sh install.sh
```

安装器菜单：`У`（安装）、`П`（查看代码——在分页器中打开，按 `q` 退出）、`О`（取消）。

非交互式 / 用于自动化：

```
sh install.sh --yes        # 静默安装
sh install.sh --yes --run  # 安装并立即启动管理器
```

如果 BusyBox 自带的 `wget` 因 HTTPS/SSL 报错，请改用 `uclient-fetch`：

```
uclient-fetch -O install.sh https://raw.githubusercontent.com/lastik9/openwrt-ipv6-off/main/install.sh
```

<details>
<summary>不使用安装器（直接下载文件）</summary>

```
wget -O ipv6-off.sh https://raw.githubusercontent.com/lastik9/openwrt-ipv6-off/main/ipv6-off.sh
sh ipv6-off.sh
```
</details>

## 用法

[#用法](#用法)

不带参数时打开交互式菜单（关闭 / 检查 / 诊断 / 日志 / 还原 / 管理备份）。

非交互式，用于自动化和测试：

```
sh ipv6-off.sh --disable --yes        # 关闭 IPv6（备份 + watchdog）
sh ipv6-off.sh --disable --yes --hard # 同上，另加内核层关闭（sysctl）
sh ipv6-off.sh --restore-last --yes   # 回滚最近一次备份
sh ipv6-off.sh --check                # 详细检查；退出码 0 = 关闭，1 = 开启
sh ipv6-off.sh --status               # 打印 ON / OFF
sh ipv6-off.sh --diag                 # 将诊断信息收集到文件
sh ipv6-off.sh --help                 # 帮助
```

## 普通关闭与强制关闭（sysctl）

[#普通关闭与强制关闭sysctl](#普通关闭与强制关闭sysctl)

关闭时脚本会询问：`Дополнительно вырубить IPv6 на уровне ядра (sysctl)? [y/N]`（是否额外在内核层面关闭 IPv6）。默认项（直接按 **Enter** 或输入 `N`）为**普通关闭**，大多数情况下这正是你需要的。

**普通关闭（Enter / N）。** 通过 OpenWrt 设置关闭 IPv6：移除地址分配、RA/DHCPv6 与前缀（`ula_prefix`、`ip6assign`、`reqaddress/reqprefix`、`wan6`），清理 IPv6 防火墙规则，停止 `odhcpd`。不再有 IPv6 流量，也不会绕过代理/VPN 泄漏。内核模块仍保持加载，接口上的链路本地地址（`fe80::…`）仍然保留。这是干净、可逆的方式——正是原脚本的做法。

**强制关闭（菜单中输入 `y`，或使用 `--hard` 参数）。** 额外通过持久化的 `/etc/sysctl.d/99-ipv6-off.conf` 设置 `net.ipv6.conf.{all,default,lo}.disable_ipv6=1`，彻底关闭内核 IPv6 栈，包括链路本地。这会带来：

- 连每个接口上的 `fe80::…` 链路本地地址都会消失。
- 依赖至少本地 IPv6 的软件可能出现异常：某些守护进程、有时是 LuCI、以及服务间通信。
- 对“只是关掉 IPv6”这一常见目标毫无额外好处——普通关闭已足以停止所有 IPv6 流量。

**结论：按 Enter（普通关闭）。** `--hard` 模式仅用于特定场景——需要彻底移除 IPv6 栈，或有程序无视 UCI 设置反复拉起链路本地并造成干扰时。

两种模式的回滚方式相同（`--restore-last` 或菜单第 5 项）。若使用了 `--hard`，还原会自动删除 `/etc/sysctl.d/99-ipv6-off.conf` 并把 `disable_ipv6=0` 复位——无需额外清理。

## 关闭后失去连接怎么办

[#关闭后失去连接怎么办](#关闭后失去连接怎么办)

1. 等待约 1 分钟——如果 IPv4 未恢复，watchdog 会自动回滚。
2. 若仍无效，从 LAN 连接并运行 `sh ipv6-off.sh --restore-last --yes`。
3. 最后手段，手动操作：

```
cp -a /root/ipv6-off/backups/<最近一次>/{network,dhcp,firewall} /etc/config/
/etc/init.d/firewall restart && /etc/init.d/network restart
```

## 文件

[#文件](#文件)

| 内容 | 路径 |
| --- | --- |
| 日志（约 400 KB 时轮转） | `/root/ipv6-off/ipv6-off.log` |
| 备份 | `/root/ipv6-off/backups/<timestamp>/` |
| 诊断 | `/root/ipv6-off/ipv6-diag-<timestamp>.txt` |
| Watchdog（自动生成） | `/tmp/ipv6_watchdog.sh` |

## 兼容性

[#兼容性](#兼容性)

已在带 fw4/nftables（22.03+）与 fw3/iptables 的 OpenWrt 上测试。防火墙还原与后端无关，因为设置是通过复制 `/etc/config/firewall` 恢复的。

`--hard`（sysctl）参数会同时关闭链路本地（link-local）IPv6——请谨慎使用，仅在 LAN 内没有仅 IPv6 的服务、且运营商不依赖 IPv6 时启用。

## 致谢

[#致谢](#致谢)

菜单风格与整体思路参考了 [openwrt-ssclash](https://github.com/lastik9/openwrt-ssclash) 安装器。脚本使用 OpenWrt 的原生机制（`uci`、`odhcpd`、`/etc/init.d/*`）；系统本身的功劳归于其作者。

## 许可证

[#许可证](#许可证)

[MIT](LICENSE) © 2026 lastik9
