<div align="center">

[English](README.md) | **简体中文**

# MeshArc

<img src="AppScope/resources/base/media/app_icon.png" width="96" alt="MeshArc 应用图标">

**面向 HarmonyOS 的原生 Tailscale 客户端，聚焦桌面与高级网络场景。**

[![HarmonyOS](https://img.shields.io/badge/HarmonyOS-6.1%20%7C%20API%2023-007DFF?style=for-the-badge)](https://github.com/RockyMtnWolf/MeshArc)
[![架构](https://img.shields.io/badge/Native-OpenHarmony%20arm64-3DA5D9?style=for-the-badge)](docs/development.md)
[![许可证](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg?style=for-the-badge)](LICENSE)

[源码仓库](https://github.com/RockyMtnWolf/MeshArc) · [English](README.md)

</div>

---

MeshArc 将 HarmonyOS 设备接入 Tailscale tailnet。项目将 Tailscale 用户态网络引擎构建为 OpenHarmony arm64 原生库，并提供 HarmonyOS VPN 扩展与 ArkUI 界面。

## 功能

- **Tailnet 连接：**登录 Tailscale、查看设备状态，并通过 Tailscale IP 访问节点。客户端提供已批准子网路由和出口节点选择；DNS 行为存在下文所述限制。
- **文件与媒体：**支持 Taildrop 文件传输、Taildrive 共享目录，以及 Jellyfin、Emby、Plex 和 HosPlayer 的发现/跳转工作流。
- **桌面网络工具：**适配手机、平板和二合一设备；提供 ClashBox YAML 修复/导出（显式选择的入站策略仅支持 TCP），以及支持多配置、独立 worker 和 TOML 文件导入的内嵌 FRP 客户端。
- **桌面生命周期：**窗口关闭路径使用 HarmonyOS `hideAbility`，支持隐藏到托盘的行为。
- **隐私控制：**可选应用访问保护和本地配置管理。

## 兼容性与规格

| 项目 | 当前工程基线 |
| --- | --- |
| 平台 | HarmonyOS 6.1 兼容，API 23；编译 SDK 26 |
| 设备/原生目标 | arm64；适配手机、平板和二合一设备 |
| Tailscale 引擎 | 固定为 `1.86.5` |
| OpenHarmony Go | `1.24.5`（项目工具链基线） |
| 正式包名 | `io.github.rockymtnwolf.mesharc` |

`AppScope/app.json5` 已采用独立 MeshArc 包名；这不代表该包名已获 AppGallery 核准或当前构建已完成正式签名。MagicDNS 尚未启用；适用时请使用 Tailscale IP。设备重启后可能需要手动重新连接；HarmonyOS 同一时刻只允许一个系统 VPN 服务。

## 验证情况与限制

- **共存与设备发现：**Clash VPN 保持开启时，最新独立 HAP 的传输手动刷新恰显示 2 个 LocalSend 在线节点，没有“无连接”条目；主页 native probe 显示 3 个 peer 均为 direct，延迟分别为 84/35/14 ms，未再显示恢复中。ClashBox 下 RDP 出站与 USB/IP 入站也已确认。以上不代表 DNS、UDP、子网路由、所有 peer 的文件传输或普遍多 VPN 共存均已验证。
- **FRP：**v0.52.0 兼容版独立 HAP 已构建并安装；打开既有配置卡片后，内嵌 native phase 已连接 frps。Windows 通过这条既有映射发送 USB/IP `devlist`，收到版本 `0x111`、命令 `0x5`、状态 `0`、设备数 `1` 的协议响应。这只验证单隧道外网协议响应，不证明真实 USB 设备 attach 或读写，也不代表多个公网隧道通过。基于更新 v0.51 的 Sakura 专有模式 INI 不受 stock v0.52 支持；已验证的是原 TOML 配置路径。单看 worker `running` 仍不代表公网可达。
- **FRP 导入、界面与短时后台验收：**MateBook 系统 FilePicker 导入原有 TOML 后，表单保留域名、user、TLS 标志和既有端口，没有出现 `NoSuchFile`/`ENOENT`；未另存配置或申请新端口。主代理复核截图 51/52/53/66/74：无遮罩、footer 不遮挡、五个导航图标均匀放大且 TCP 协议标签可见；第二映射页 UI 审核仍在进行。标题栏关闭经 `hideAbility` 后，主窗口从窗口列表消失；原有 USB/IP 映射立即及约 1 分钟后仍能返回 `devlist` 状态 0、设备数 1。这仅是短时后台验收，不证明强退后恢复或长期保活。
- **内核更新：**当前功能检查上游发行版元数据，并可导出构建请求清单；尚不能自动拉取源码、构建/签名内核或在设备端安装更新。完整 HAP 升级替换内核会中断 VPN；尚未实现 `.so` 热替换。
- **LocalSend：**上述设备发现/状态场景已验证；更广泛的互通与完整文件传输仍未验证。
- **发行状态：**目前没有 AppGallery 上架链接。根目录 build `100000005` HAP 已生成但未签名、未发布；未签名 HAP 不能作为常规安装包直接安装。请在 DevEco Studio 配置并使用自己有权使用的签名材料。切勿发布签名私钥或 profile。

构建结果、自动化测试、设备观察和外网验收是不同证据。详见 [beta 验收记录](docs/2026-10-13-release-beta1.md) 与[工程检查清单](docs/2026-10-13-change-checklist.md)。

## 构建

全新克隆**不能直接一键构建**。请准备 DevEco Studio 与 HarmonyOS SDK、OpenHarmony Go 1.24.5 工具链、Tailscale `v1.86.5` 源码，以及本地签名配置。详见[开发与 Windows 构建说明](docs/development.md)和[macOS 构建说明](docs/build-macos.md)。

Windows PowerShell 环境准备完成后，将 `build-profile.example.json5` 复制为本地忽略的 `build-profile.json5`，再执行：

```powershell
./scripts/build.ps1
```

构建脚本会生成 HAP；安装需要目标设备接受的有效签名。未签名 HAP 不是可直接正常安装的发行包。

## 项目信息

| 项目 | 信息 |
| --- | --- |
| 应用 | MeshArc；开发者/主体：蒋厚斌 |
| 隐私联系邮箱 | 1299177969@qq.com |
| 问题反馈 | smartwolf@stu.xidian.edu.cn |
| 源码仓库 | [RockyMtnWolf/MeshArc](https://github.com/RockyMtnWolf/MeshArc) |
| 上游来源 | 衍生自 [flypigJ/Tailscale-OHOS](https://github.com/flypigJ/Tailscale-OHOS)；MeshArc 独立维护。 |

## 许可证与致谢

MeshArc 源码采用 [BSD 3-Clause 许可证](LICENSE)。源自 Tailscale 的代码继续保留上游版权声明和 BSD 许可证；其他第三方依赖仍遵循各自条款。再分发前请查看[第三方声明](THIRD_PARTY_NOTICES.md)和 `LICENSES/`。

感谢 [Tailscale](https://github.com/tailscale/tailscale)、OpenHarmony Go 贡献者及上游 `flypigJ/Tailscale-OHOS` 项目。MeshArc 是独立社区项目，与 Tailscale Inc. 无关联且未获其背书。HarmonyOS 等产品名称归其所有者所有。
