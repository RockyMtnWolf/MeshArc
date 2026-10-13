<div align="center">

[English](README.md) | **简体中文**

# MeshArc

<img src="AppScope/resources/base/media/app_icon.png" width="96" alt="MeshArc 应用图标">

**面向 HarmonyOS 的原生 Tailscale 客户端，集成 Frpc ，并且可与 ClashBox 等代理软件共存。**

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-6.1%20%7C%20API%2023-007DFF?style=for-the-badge)](https://github.com/RockyMtnWolf/MeshArc)
[![架构](https://img.shields.io/badge/Native-OpenHarmony%20arm64-3DA5D9?style=for-the-badge)](docs/development.md)
[![许可证](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg?style=for-the-badge)](LICENSE)

[源码仓库](https://github.com/RockyMtnWolf/MeshArc) · [English](README.md)

</div>

---

## 功能

- **Tailnet 连接**：登录 Tailscale、查看设备状态，并通过 Tailscale IP 访问节点。客户端提供已批准子网路由和出口节点选择；DNS 行为存在下文所述限制。
- **文件与媒体**：支持 Taildrop 文件传输、Taildrive 共享目录，以及 Jellyfin、Emby、Plex 和 HosPlayer 的发现/跳转工作流。
- **桌面网络工具**：适配平板和二合一设备；提供 Clash YAML 修复/导出（显式选择的入站策略仅支持 TCP），以及支持多配置、独立 worker 和 TOML 文件导入的内嵌 FRP 客户端。
- **桌面生命周期**：窗口关闭路径使用 HarmonyOS `hideAbility`，支持隐藏到托盘的行为。
- **隐私控制**：可选应用访问保护和本地配置管理。

## 兼容性与规格

| 项目 | 当前工程基线 |
| --- | --- |
| 平台 | HarmonyOS 6.1 兼容，API 23；编译 SDK 26 |
| 设备/原生目标 | arm64；适配平板和二合一设备 |
| Tailscale 引擎 |  `1.86.5` |
| OpenHarmony Go | `1.24.5` |

MagicDNS 尚未启用；适用时请使用 Tailscale IP。HarmonyOS 同一时刻只允许一个系统 VPN 服务，需要和其他代理软件共存时请在设置的网络与连接页面开启 ClashBox 共存并且根据提示对 YAML 配置文件进行修补。
理论上其他 Clash 类代理软件也能正常共存，但是并未测试。

## 验证情况与限制

- **共存与设备发现**：Clash VPN 保持开启时，MeshArc 工作在用户态，测试 Tailscale 局域网内设备互相通信成功，测试 RDP 远程桌面， USB/IP ，Localsend 局域网自动发现均没有问题。
- **FRP**：内置 Frpc 版本为官方 v0.52.0 ，基于更新 v0.51 的 Sakura 专有模式 INI 不受 stock v0.52 支持。
- **内核更新**：当前功能检查上游发行版元数据，并可导出构建请求清单；尚不能自动拉取源码、构建/签名内核或在设备端安装更新。完整 HAP 升级替换内核会中断 VPN；尚未实现 `.so` 热替换。

## 构建

请准备 DevEco Studio 与 HarmonyOS SDK、OpenHarmony Go 1.24.5 工具链、Tailscale `v1.86.5` 源码，以及本地签名配置。详见[开发与 Windows 构建说明](docs/development.md)和[macOS 构建说明](docs/build-macos.md)。

Windows PowerShell 环境准备完成后，将 `build-profile.example.json5` 复制为本地忽略的 `build-profile.json5`，再执行：

```powershell
./scripts/build.ps1
```

构建脚本会生成未签名 HAP ，请自行签名安装。

## 许可证与致谢

MeshArc 源码采用 [BSD 3-Clause 许可证](LICENSE)。源自 Tailscale 的代码继续保留上游版权声明和 BSD 许可证；其他第三方依赖仍遵循各自条款。再分发前请查看[第三方声明](THIRD_PARTY_NOTICES.md)和 `LICENSES/`。

感谢 [Tailscale](https://github.com/tailscale/tailscale)、OpenHarmony Go 贡献者及上游 `flypigJ/Tailscale-OHOS` 项目。MeshArc 是独立社区项目，与 Tailscale Inc. 无关联且未获其背书。HarmonyOS 等产品名称归其所有者所有。
