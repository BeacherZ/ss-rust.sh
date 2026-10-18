# Shadowsocks-Rust 服务管理脚本

<p align="center"><a href="README_EN.md">English</a> ｜ 简体中文</p>

一个轻量、全自动化且高度兼容的 **Shadowsocks-Rust** 服务端管理脚本。

专门针对多种主流 Linux 发行版与各类老旧客户端，进行了全方位的深度适配与无缝兼容优化。

直接调取 GitHub 官方 Releases 源码库（[`shadowsocks/shadowsocks-rust`](https://github.com/shadowsocks/shadowsocks-rust)）下载与校验，确保系统安全与原汁原味。

---

## 🌟 特性亮点

* ⚙️ **架构智能匹配**：自动精准识别 `CPU 硬件架构与系统类型`，智能下载最匹配的官方编译程序包。
* 🛠️ **一键快捷维护**：全功能`交互式菜单`，轻松搞定服务安装、版本更新、彻底卸载与配置日志查看。
* 🛡️ **定向版本检索**：检索官方源码库，逐个校验并下载`个人偏好`支持 `aes-128-gcm` 加密的最新版本。
* 🎯 **原生解析兼容**：默认遵循`系统 DNS` 配置，拒绝硬编码，完美保留 VPS 原生流媒体解锁能力。
* 🌐 **双栈智能检测**：内置智能超时网络探测，自动识别并生成专属的 `IPv4 / IPv6` 节点导入链接。
* 🔄 **双守护系适配**：同时兼容 `systemd` 与 `OpenRC`，完美适配 Debian、Ubuntu、Alpine 等主流系统。
  
---

## 🖥️ 支持系统

| 系统架构 | 支持的 Linux 发行版 | 服务守护进程 |
| :--- | :--- | :--- |
| `x86_64` / `amd64` | **Debian** 10+ | Systemd |
| `aarch64` / `arm64` | **Ubuntu** 18.04+ | Systemd |
| `armv7l` / `armhf` | **Alpine Linux** 3.12+ | OpenRC |
| `i386` / `i686` | **CentOS** 7+ / **RHEL** / **Fedora** / **Rocky** / **Alma** | Systemd |
| `x86_64` / `amd64` | **Arch Linux** | Systemd |

---

## ⚡ 一键安装与运行

使用 `root` 权限登录服务器后，直接复制并执行以下命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/BeacherZ/Shadowsocks-Rust/main/ss-rust.sh)

```

---

## 📋 菜单界面概览

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

## 📁 文件与目录结构

| 路径 | 说明 |
| --- | --- |
| `/etc/shadowsocks-rust/config.json` | Shadowsocks-Rust 服务配置文件 |
| `/usr/local/bin/ssserver` | 主程序可执行文件 |
| `/etc/systemd/system/shadowsocks-rust.service` | Systemd 服务配置文件 |
| `/etc/init.d/shadowsocks-rust` | OpenRC 服务管理脚本（仅 Alpine 等系统） |

---

## 📄 开源协议

本项目采用 [MIT License](https://www.google.com/search?q=LICENSE) 协议开源。
