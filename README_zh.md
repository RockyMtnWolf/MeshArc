<div align="center">

[English](README.md) | **简体中文**

# MeshArc

<img src="AppScope/resources/base/media/app_icon.png" width="96" alt="MeshArc 应用图标">

**面向 HarmonyOS 的原生 Tailscale 客户端，支持 FRP，并可与 ClashBox 共存。**

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-6.1%20%7C%20API%2023-007DFF?style=for-the-badge)](https://github.com/RockyMtnWolf/MeshArc)
[![OpenHarmony arm64](https://img.shields.io/badge/Native-OpenHarmony%20arm64-3DA5D9?style=for-the-badge)](https://github.com/RockyMtnWolf/MeshArc)
[![许可证](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg?style=for-the-badge)](LICENSE)

[源码仓库](https://github.com/RockyMtnWolf/MeshArc) · [English](README.md)

</div>

---

MeshArc 通过 HarmonyOS 原生 VPN 扩展和 Tailscale 用户态引擎，将设备接入 Tailscale tailnet。

## 功能

- **Tailnet：**设备状态、已批准的子网路由和出口节点选择。
- **传输与媒体：**Taildrop、Taildrive、LocalSend 局域网发现，以及 Jellyfin、Emby、Plex 和 HosPlayer 集成。
- **代理共存：**支持 ClashBox 用户态共存及 YAML 修复/导出；可选入站策略仅支持 TCP。
- **内嵌 FRP：**导入 TOML 文件、保存多份配置并由独立 worker 运行。内含 FRP v0.52.0 本地兼容补丁，**不是未修改的官方原版构建**。
- **桌面体验：**适配平板和二合一设备；支持可选访问保护及标题栏关闭到托盘。

## 兼容性

| 项目 | 基线 |
| --- | --- |
| 平台 | HarmonyOS 6.1 兼容，API 23；编译 SDK 26 |
| 原生目标 | arm64；平板和二合一设备 |
| Tailscale | `v1.86.5` |
| OpenHarmony Go | `1.24.5` |
| FRP | 本地兼容补丁版 `v0.52.0` |
| 应用版本 | `1.1.2` · build `100000007` |
| Bundle ID | `io.github.rockymtnwolf.mesharc` |

HarmonyOS 同一时刻只允许一个系统 VPN 服务。若要与 ClashBox 共存，请在网络设置中开启共存，并按应用提示修复/导出 Clash YAML。其他 Clash 类应用尚未广泛测试。MagicDNS 未启用；需要时请使用 Tailscale IP。

## 测试与限制

维护者已在 MateBook Pro S 上测试设备互通、RDP、USB/IP、LocalSend 发现、FRP 和后台使用，当前设备使用正常。这是维护者在该设备上的实测，不代表所有 HarmonyOS 设备或网络环境均无问题。

FRP 基于本地兼容补丁版 v0.52.0；已测试的是 TOML 配置。stock v0.52.0 不支持 Sakura 新版 v0.51 INI 的专有模式。

内核更新目前只能检查上游发行信息并导出构建请求清单；端侧拉取源码、编译、签名和安装尚未实现。完整 HAP 更新会中断 VPN，尚不支持 `.so` 热替换。

可选后台任务维持仅在 PC/二合一设备启用，替代原音频保活，不播放音频；其他设备不申请对应受限系统权限。后台模式不能保证应用永远不会被系统终止。

## 安装

请在 [GitHub Releases](https://github.com/RockyMtnWolf/MeshArc/releases) 查看发行包和说明。Release HAP 为未签名包，安装前请使用自己有权使用的签名材料完成签名。请勿分享私钥或 profile。

应用已提交华为应用市场审核，面向 PC/二合一设备，尚未上架，暂无下载链接。

## 构建

准备 DevEco Studio 与 HarmonyOS SDK、OpenHarmony Go `1.24.5` 工具链、Tailscale `v1.86.5` 源码和本地构建/签名配置。将 `build-profile.example.json5` 复制为被忽略的 `build-profile.json5`，配置自己的签名设置后，在 Windows PowerShell 执行：

```powershell
./scripts/build.ps1
```

上架 AppGallery 时，应构建整个产品的 Release `.app`，而不是把 `.hap` 改后缀：

```powershell
devecocli build --product default --build-mode release
```

`.app` 用于应用市场送审；`.hap` 是模块安装包，本地安装需使用设备接受的签名。

仓库不含签名凭据。未配置签名时构建产物为未签名 HAP；安装需要设备接受的有效签名。

## 许可证与致谢

MeshArc 采用 [BSD 3-Clause 许可证](LICENSE)。源自 Tailscale 的代码保留上游声明，其他组件继续遵循各自许可证。详见[第三方声明](THIRD_PARTY_NOTICES.md)及 `LICENSES/` 中随附的许可证文本。

感谢 [Tailscale](https://github.com/tailscale/tailscale)、OpenHarmony Go 贡献者及上游 [flypigJ/Tailscale-OHOS](https://github.com/flypigJ/Tailscale-OHOS) 项目。MeshArc 是独立社区项目，与 Tailscale Inc. 无关联且未获其背书。
