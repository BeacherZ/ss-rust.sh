# Shadowsocks-Rust Server Manager

<p align="center">English ｜ <a href="README.md">简体中文</a></p>

A lightweight, fully automated, and highly compatible **Shadowsocks-Rust** server management script.

It ships with deep adaptation and seamless compatibility work for major Linux distributions and a wide range of older clients.

Binaries are downloaded and verified straight from the official GitHub Releases of [`shadowsocks/shadowsocks-rust`](https://github.com/shadowsocks/shadowsocks-rust), so you get the genuine upstream build and stay on the safe side.

---

## 🌟 Highlights

* ⚙️ **Architecture-aware**: detects your `CPU architecture and OS type` automatically and downloads the matching official build.
* 🛠️ **One-click maintenance**: a full `interactive menu` covering install, update, clean uninstall, and log inspection.
* 🛡️ **Targeted version search**: walks the official release list and picks the newest build that still supports `aes-128-gcm`, so your preferred cipher keeps working.
* 🎯 **Native resolver compatibility**: follows the `system DNS` configuration by default — no hardcoding — which preserves the VPS's native streaming-unlock behaviour.
* 🌐 **Dual-stack detection**: built-in network probing with timeouts, generating dedicated `IPv4 / IPv6` import links.
* 🔄 **Dual init support**: works with both `systemd` and `OpenRC`, covering Debian, Ubuntu, Alpine and other mainstream systems.

---

## 🖥️ Supported systems

| Architecture | Supported distributions | Service manager |
| :--- | :--- | :--- |
| `x86_64` / `amd64` | **Debian** 10+ | Systemd |
| `aarch64` / `arm64` | **Ubuntu** 18.04+ | Systemd |
| `armv7l` / `armhf` | **Alpine Linux** 3.12+ | OpenRC |
| `i386` / `i686` | **CentOS** 7+ / **RHEL** / **Fedora** / **Rocky** / **Alma** | Systemd |
| `x86_64` / `amd64` | **Arch Linux** | Systemd |

---

## ⚡ Install and run

Log in to the server as `root`, then copy and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BeacherZ/Shadowsocks-Rust/main/ss-rust.sh)

```

---

## 📋 Menu overview

> The menu itself is rendered in Chinese.

```text
╔══════════════════════════════════════════════════════════════╗
║                Shadowsocks-Rust 服务管理脚本                 ║
╠══════════════════════════════════════════════════════════════╣
║  服务状态: ● 运行中 (Shadowsocks-rust-v1.22.0)               ║
╠══════════════════════════════════════════════════════════════╣
║  1. 安装 Shadowsocks-Rust                                    ║
║  2. 更新 Shadowsocks-Rust                                    ║
║  3. 卸载 Shadowsocks-Rust                                    ║
╟──────────────────────────────────────────────────────────────╢
║  4. 启动服务                                                 ║
║  5. 停止服务                                                 ║
║  6. 重启服务                                                 ║
╟──────────────────────────────────────────────────────────────╢
║  7. 查看配置及 SS 链接 (IPv4 / IPv6)                         ║
║  8. 查看运行日志                                             ║
║  0. 退出脚本                                                 ║
╚══════════════════════════════════════════════════════════════╝

```

---

## 📁 Files and directories

| Path | Description |
| --- | --- |
| `/etc/shadowsocks-rust/config.json` | Shadowsocks-Rust service configuration |
| `/usr/local/bin/ssserver` | Main executable |
| `/etc/systemd/system/shadowsocks-rust.service` | Systemd unit |
| `/etc/init.d/shadowsocks-rust` | OpenRC service script (Alpine and similar systems only) |

---

## 📄 License

Released under the [MIT License](https://www.google.com/search?q=LICENSE).
