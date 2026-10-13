# MeshArc 开源与第三方许可说明（发布准备草案）

发布到华为应用市场前，安全、隐私、兼容性、性能测试及适用资质要求以[华为官方提交说明](https://developer.huawei.com/consumer/cn/app/submit)和官方核验为准；问题可提交[华为官方咨询工单](https://developer.huawei.com/consumer/cn/support/feedback/#/)。本说明不代表审核通过，也不套用荣耀市场规则。

## MeshArc

MeshArc 原创项目代码采用仓库根目录 `LICENSE` 中的 BSD 3-Clause License。现有 LICENSE 标注 `Copyright (c) 2026, Jerry Zhu and MeshArc contributors`；发布前应由代码权利人确认版权人姓名/组织、贡献者授权及该年份声明适用于拟发布内容。不得以项目许可证替代第三方代码许可证。

计划公开新仓库：GitHub 用户 `RockyMtnWolf`；仓库 URL 与公开时间待确定。公开前检查是否夹带私钥、HAP签名材料、用户配置、令牌、诊断报告及未授权代码。产品名 MeshArc 不表示与 Tailscale、LocalSend 或 HarmonyOS 官方关联。

## 已确认的 Go 组件基线

以下直接依赖版本来自 `native/go_bridge/go.mod`。列表用于审计定位，不是完整发行版 SBOM，也不代替各组件随附的版权/许可文本：

| 模块 | 固定版本/来源 | 发布注意 |
| --- | --- | --- |
| `tailscale.com` | v1.86.5，`replace` 到 `third_party/tailscale` | `THIRD_PARTY_NOTICES.md` 指向上游 BSD 3-Clause 文本 `LICENSES/Tailscale.txt`；保留上游版权与修改标注。核对本地源码 commit 与版本基线。 |
| `github.com/fatedier/frp` | v0.52.0 | Apache-2.0，文本见 `LICENSES/FRP.txt` 和 `third_party/frp-compat/LICENSE`。这是兼容性 fallback，不是最新版本；本轮 Windows 官方客户端实测，同一配置下 0.52 登录与代理成功、0.67 返回 EOF（仅该配置）。这不等于 MeshArc 内嵌 HarmonyOS 客户端已验证通过。对缓存 v0.52.0 源码逐文件比较并统一 CRLF/LF 后，发现 Go 源码差异在 `client/control.go`、`client/service.go`、`client/proxy/proxy.go`、`client/visitor/xtcp.go`、`pkg/nathole/controller.go`、`pkg/util/net/conn.go`、`pkg/util/net/dial.go`、`server/service.go`；这是内容差异清单，不是语义审查。发布前需审核完整 diff，并保留全部上游署名和许可。FRP 树中非 Go 文件也有变化，须另行检查。 |
| `github.com/pelletier/go-toml/v2` | v2.2.0 | 确认上游许可文本随分发保留。 |
| `github.com/tailscale/wireguard-go` | `v0.0.0-20250716170648-1d0488a3d7da` | 确认上游许可、版权和可能的代码来源声明。 |
| `golang.org/x/sys` | v0.35.0 | 按对应模块许可随分发保留。 |
| `gopkg.in/yaml.v3` | v3.0.1 | 按对应模块许可随分发保留。 |

已从当前 `.so` 的 Go build metadata 提取 93 个实际 Go modules（含传递依赖），并把对应模块的 LICENSE/NOTICE/COPYING/COPYRIGHT 原文归档到 `LICENSES/dependencies/`；逐模块版本、cache/local replace 来源及原文路径见 [docs/third-party-module-inventory.md](third-party-module-inventory.md)。Go runtime/toolchain 原始 `LICENSE` 与 `PATENTS` 也已归档。该清单不覆盖非 Go native libraries、HarmonyOS 系统组件或所有嵌入资产；发布前仍须核验这些范围，并审阅 FRP/Tailscale 本地 replace 的源码差异。缺少适用许可原文或无法确认分发条件的组件不得随包发布。

## 发布核查清单

- [ ] 在目标发布提交和目标 HarmonyOS 构建配置上锁定 Go 模块图与源码 commit；确认 `third_party/tailscale` 的实际来源、版本、修改内容和许可文件。
- [ ] 对直接及间接 Go 模块、Go 工具链、HarmonyOS native/runtime 组件和打包资源生成 SBOM；识别许可证、版权声明、专利/NOTICE 条件及不可再分发组件。
- [ ] 对进入 HAP 的代码而非仅 `go.mod` 做 license 扫描；检查复制/改编代码头部，保留原始 notice。核对 FRP、WireGuard、Tailscale 的上游许可证文本及声明。
- [ ] 在源码仓库与二进制随附材料中提供各许可证要求的文本、版权/归属和修改说明；确认 BSD 3-Clause 二进制再分发材料满足根 `LICENSE` 条款。
- [ ] 发布源代码、未签名 HAP 时说明它不含签名身份/私钥；HAP 仍须由有权主体按市场要求完成签名和包名校验。不得公开证书私钥、账号 token、真实 FRP/VPN 配置。
- [ ] 确认第三方商标/名称的描述性使用合规，避免暗示官方认证、合作或背书。

## 资料局限

根 `THIRD_PARTY_NOTICES.md` 明确说明自己不是全部传递依赖的清单，且当前只具体列出 Tailscale；本文件同样是发布准备记录，不宣称已经完成完整许可证审计。最终 notices 必须基于实际发行物逐项确认，不得由模块名推断许可证。
