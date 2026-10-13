# MeshArc 上架与开源发布准备清单（草案）

> 本文是发布前审计草案，不代表已完成备案、取得资质或通过华为应用市场审核。按用户提供的华为官方[应用提交说明](https://developer.huawei.com/consumer/cn/app/submit)，发布前需关注安全、隐私、兼容性、性能测试及适用资质；具体要求以华为官方对本应用的核验结果为准。可通过[华为开发者联盟官方咨询工单](https://developer.huawei.com/consumer/cn/support/feedback/#/)询问 VPN、后台模式及资质问题。本文不套用荣耀应用市场规则或将其限制移植为华为规则。

## 已确认信息与仍待确认

- 产品名：MeshArc；开发者/主体填报名称：蒋厚斌；隐私联系邮箱：`1299177969@qq.com`；应用反馈邮箱：`smartwolf@stu.xidian.edu.cn`。上线前由开发者核对邮箱可用性、主体证件及两邮箱职责。
- GitHub 源仓库为 `https://github.com/RockyMtnWolf/MeshArc`；公开/发布时点与仓库当时可访问状态以该仓库实际页面为准。发布前检查历史、提交、附件和 issue 中是否误含密钥、用户配置、日志或个人数据。
- **正式 bundleName 已写入源码**：`io.github.rockymtnwolf.mesharc`；`AppScope/app.json5` 当前 vendor 为蒋厚斌、版本 `1.1.1-beta.1`（code `100000005`）。这仅说明源码配置已落地，不代表 AppGallery Connect 包名已登记/可用、已签名或获批；提交前仍须由主体核验账号持有关系及升级迁移方案。
- 备案/应用资质、软件著作权（如适用）、开发者账号认证、隐私标签、应用年龄分级及市场审核结论均**未确认**；由主体按提交时官方要求办理，不在本草案中声称已具备。

## 实际权限与能力（当前源码配置）

`entry/src/main/module.json5` 声明：

| 声明项 | 当前用途/核验事项 |
| --- | --- |
| `ohos.permission.INTERNET` | VPN、Tailscale/FRP、远端文件与 GitHub release 元数据/源码请求。逐功能核对真实目的地和传输数据。 |
| `ohos.permission.GET_NETWORK_INFO` | 网络状态/连接管理；确认功能关闭时是否仍需要。 |
| `ohos.permission.GET_BUNDLE_INFO` | 查询已安装应用信息（包括与 HosPlayer 等外部应用联动的场景）；核实实际调用、范围和告知。 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 前台持续任务；需要与真实 VPN/传输等任务关联，不能只为绕过后台限制。 |
| `ohos.permission.VIBRATE` | 反馈提示；核实使用场景。 |
| `ohos.permission.ACCESS_BIOMETRIC` | 当前 manifest 已声明；本次源码审计未确认其实际用途/调用。**发布前证明必要性，否则删除声明。** |

另有 `vpn` 类型 `TailscaleVpnExtensionAbility`（非 exported）及 exported 的 `statusBarView` 扩展；Entry 声明 `dataTransfer`、`audioPlayback` 后台模式。VPN 建立/路由流量属核心敏感能力，需在上架说明、权限用途和用户操作中清楚解释；确认授权、启动、停止、断开及后台行为符合目标设备/市场规则。`dataTransfer` 与 `audioPlayback` 不是可以无条件常驻的通用保活许可。

## 数据流与风险披露基线

- **Tailscale VPN / native core**：本机 ArkTS UI 经 Native Bridge 调用 Go Tailscale 引擎；建立用户态 TUN/VPN，设备流量可经 Tailscale 控制面、DERP/对端路径及用户配置的网络目的地传输。账号登录和节点/peer状态涉及 Tailscale 服务；实际域名、字段、日志与留存须按所选登录方式和版本进一步实测。不得宣称 MeshArc 自有服务器处理这些数据，也不得承诺端到端数据完全不离开设备。
- **FRP**：内嵌 `github.com/fatedier/frp` 客户端；用户导入/配置的 FRP 服务端地址、认证凭据及代理规则决定连接和转发目标。凭据可能包含在用户配置中，避免写日志/诊断包；说明哪些配置仅本地保存、如何删除，并确认服务端运营者的数据处理责任。
- **LocalSend / Taildrop**：源码实现经 Tailscale 网络探测兼容 LocalSend v2 的设备注册端点（TLS/HTTP），并提供 Tailscale Taildrop 收发。文件名、大小、peer 信息及传输进度用于界面/缓存；用户明确选择文件后传输。不得将“发现设备”描述成读取本机全部文件。验证本地缓存路径、保留期限、清理/导出及诊断日志脱敏。
- **Core update**：`CoreUpdateGateway` 请求 GitHub Tailscale releases/tag API，检查上游版本/标签并导出构建请求；现有界面明示端侧自动拉取、编译、签名、安装尚未实现。说明请求会向 GitHub 发送网络请求/IP等常规连接元数据；不宣称当前客户端会自动升级或安装。
- **诊断及设备信息**：诊断服务会收集设备/系统版本、VPN/网络状态和应用诊断事件并生成报告。发布前逐项审阅报告字段、用户主动导出/分享时机、文件位置和删除方式；不得把报告自动上传描述为本地处理。任何崩溃日志、账号标识、地址和 peer 信息必须脱敏。
- **用户态入站 TCP 暴露**：共存 SOCKS 模式支持显式配置至多 16 个 TCP 端口或 `allowAll` 全端口策略（排除 1055），由 Tailscale `tsnet` fallback handler 转发到设备 Tailscale 地址的目标端口；这是面向 tailnet 的入站服务暴露，不等同于仅本机 SOCKS。开启“全部端口”会扩大可达服务面，可能使设备上对应监听服务被 tailnet 成员访问。上线前将默认关闭、明确展示范围/风险、逐端口确认并测试撤销；若功能不能做到访问控制和清晰告知，移除全端口选项。
- **后台保活高风险项**：当前提供“模拟下载保活”（源码明确无实际下载）和循环播放低音量本地合成音频的模式。用模拟流量/无业务音频维持后台运行，可能被认定为滥用后台能力，存在审核不通过风险；本草案不声称符合规则。建议市场版移除/默认禁用这些模式及相应后台声明，只保留与用户可感知、正在进行的 VPN/FRP/文件传输直接相关的必要后台任务，并提交前复核平台政策与真机行为。

## 发布前必须完成

- [ ] 确认 AppGallery 包名可用并落地 `io.github.rockymtnwolf.mesharc`；确认升级、并存安装和签名策略；不能覆盖/冒充上游包。
- [ ] 按华为官方提交流程确认安全、隐私、兼容性、性能测试及适用资质/备案；由主体填报真实信息，存在不确定项时通过官方工单确认。
- [ ] 逐项复核权限与受限能力；查明 `ACCESS_BIOMETRIC` 实际用途；删去不用项；对 VPN、后台模式、status bar 扩展进行市场规则预审。
- [ ] 删除或整改模拟下载/循环音频保活；确认真实业务的前后台生命周期、通知、用户停止入口及系统回收时表现。无法证明后台模式必要时不要提交。
- [ ] 审查全端口入站默认值、授权提示、tailnet ACL 前提、可达服务范围及撤销；完成威胁建模与测试。
- [ ] 完成数据清单/SDK与 Go 依赖清单、隐私政策、第三方 SDK/模块目的方式范围披露。华为官方发布说明明确提示集成第三方 SDK 时需逐一披露相关个人信息处理信息；仍以当前审核规则为准。
- [ ] 生成最终签名发行包并检查包名、版本、权限、隐私标签及签名；本仓库当前未签名 HAP 不可作为已可上架成品。
- [ ] 检查 GitHub 发布物、license/notice、README（另行准备）、发布说明和应用商店描述一致；不得宣称已通过审核/备案或与 Tailscale 官方关联。
