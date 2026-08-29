# 🚀 Cloudflare WARP 管理与流媒体解锁工具

一个高效、稳定、全自动的 Cloudflare WARP IPv6 管理脚本。为 VPS 服务器提供纯净的 IPv6 出口通道，保留原生 IPv4 本地路由，支持 WARP+ 账户、Netflix / Disney+ / YouTube 等流媒体解锁巡检与自动刷换 IP。

---

## ⚡ 一键快速运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/geniuszerotwo/warp-unlock/main/warp_manager.sh)
```

**备用安装命令（如未安装 curl）：**
```bash
wget -qO- https://raw.githubusercontent.com/geniuszerotwo/warp-unlock/main/warp_manager.sh | bash
```

> 首次运行后将自动注册全局快捷命令 `02`，后续在终端中直接输入 `02` 即可快速打开管理看板。

---

## ✨ 核心特性

- 🌐 **双栈分流优化**：IPv6 全局走 WARP 隧道，IPv4 原样保留本地原生出口，安全稳定不影响原有 SSH 连接。
- 🎬 **多流媒体解锁支持**：
  - **Netflix**：独占影片精准检测，准确识别并提取真实解锁国家代码（SG/JP/US 等），区分完整解锁与仅自制剧。
  - **Disney+**：深度匹配 BAMGrid 接口配置，支持跨地区可用性校验。
  - **YouTube**：检测 YouTube 区域与 Premium 权限状态。
- 🔄 **智能自动换 IP 守护**：
  - 支持多策略换 IP（仅解锁 Netflix / 仅解锁 Disney+ / 双解锁）。
  - 智能自愈与退避保护：连续未命中自动降频，防频繁请求导致 IP 封锁。
- 📢 **Telegram 告警推送**：
  - IP 异常、换 IP 成功、连续重试超限均可实时推送至指定群组/私聊。
  - 内置「一键连通性测试」与自定义 API 反代地址支持，兼容国内网络。
- 🛡️ **DNS 安全与防崩溃**：
  - 自动安装 `resolvconf` / `openresolv` 关键底层依赖。
  - 保持系统内网 DNS 解析，杜绝云平台内网元数据及内网镜像源失效。
- 🔑 **WARP+ 密钥便捷管理**：
  - 支持直接在菜单绑定/更新 License Key，自动向 Cloudflare 远端同步激活并平滑重载接口。
- 🖥️ **全架构 & 多发行版支持**：
  - 架构：`x86_64` (amd64)、`aarch64`/`arm64`、`armv7`、`i386`。
  - 发行版：Debian、Ubuntu、CentOS、RHEL、AlmaLinux、Rocky Linux、openSUSE、Alpine 等。

---

## 📋 功能菜单概览

```text
============================================================
 Cloudflare WARP 核心看板: 运行中 ✅
 出口 IPv4: 1.2.3.4 (Provider, US)
 出口 IPv6: 2606:4700:xxx (Cloudflare, SG)
------------------------------------------------------------
 接口异常保活服务: 未运行 ❌
 流媒体解锁监控服务: 运行中 ✅
============================================================
               Cloudflare WARP 管理菜单
============================================================
 [基础管理]
  1) 安装/配置 WARP IPv6 (保留本地 IPv4)
  2) 手动刷新 WARP 接口 (刷换新 IPv6)
  3) 卸载 WARP 接口
  4) 卸载管理脚本与 02 快捷命令

 [流媒体解锁与状态]
  5) 一键检测流媒体解锁状态 (Netflix / Disney+ / YouTube)
  6) 开启流媒体解锁自动监控 (支持仅NF/仅Disney/双解锁换IP)
  7) 停止流媒体解锁自动监控
  8) 查看流媒体监控实时运行日志

 [告警与高级配置]
  9) 开启接口异常保活监控 (纯接口连通性自动重启)
 10) 停止接口异常保活监控
 11) 配置 / 测试 Telegram 告警推送
 12) 查看 / 绑定 WARP+ 授权密钥 (License Key)

  0. 退出
============================================================
```

---

## 📝 常见问题与提示

1. **注册时提示 429 Too Many Requests 怎么办？**
   - Cloudflare 对特定公网 IP 段有注册频次限制。可稍后再试，或在本地电脑上安装 `wgcf` 注册后，将生成的 `wgcf-account.toml` 上传到服务器 `/etc/wireguard/wgcf/` 目录下，再运行菜单选项 `1` 即可自动识别复用。
2. **如何查看后台自动换 IP 的实时日志？**
   - 在菜单中直接选择 `8`，或者在系统终端输入 `journalctl -u warp-stream-monitor.service -f`。
