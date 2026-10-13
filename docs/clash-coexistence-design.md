# ClashBox 共存、DNS 与子网路由设计

## 结论

### 2026-10-13 实施更新

已新增用户态 SOCKS 服务，绑定 `127.0.0.1:1055`，由现有 tsnet 后端执行 TCP/UDP Dial，不创建第二个 VPN。网络设置提供独立开关与可复制的 ClashBox 分流规则；需要合并到现有配置的 MATCH 规则之前，不能直接覆盖现有配置。主连接按钮在用户态模式启用时阻止创建本应用 TUN。停止该服务不停止 ClashBox，也不注销 Tailscale。

当前验证只有本地 SOCKS 握手、TCP 转发和停止资源释放测试。尚未确认 MateBook 上的 ClashBox 规则合并、UDP、DNS、子网及公网/内网同时访问。监听成功不等于共存验收成功。原先观察到两个 VPN Extension 进程 ACTIVE 也不能证明两个 TUN 的数据面同时有效。

ClashBox 当前 LTS 的真机编辑入口（由用户确认）：配置 Tab → 长按已选配置 →“编辑”（订阅元数据 sheet）→ sheet 内再次点“编辑配置”→完整 YAML 编辑器。修改前先导出备份；只把所需 `proxies` / `rules` 合并进现有配置，规则放在 `MATCH` 前，勿整体替换原配置。订阅更新可能覆盖本地修改；SOCKS 监听成功不代表两者共存已实测通过。

以下为早期设计分析；“系统只支持一个 VPN”源于接口文档，不应外推为本设备所有内部 VPN 情形的实测结论。

HarmonyOS 的 VPN Extension 是系统级 VPN 通道。本项目和 ClashBox 都通过 `VpnExtensionAbility` 创建 TUN；官方 `VpnConnection.create` 文档把“VPN 已存在”列为创建失败（错误码 `2203002`）。因此不能把两个独立 TUN 当成可同时启动的服务。产品应采用**互斥模式**：Tailscale TUN 模式或 Clash TUN 模式，一次只允许一个持有系统 VPN 的应用。

官方参考：[连接VPN](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/net-vpnextension)、[@ohos.net.vpnExtension](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-net-vpnextension)。主代理读取本地官方指南后核实其中明确写明仅支持启动一个 VPN 连接服务；子代理另核对了在线接口文档。没有执行真机 VPN 冲突测试。

用户优先的高级配置需求中，若“Clash 规则代理 + Tailscale 子网”都必须覆盖设备全部流量，当前代码不能直接满足。建议把 **Clash TUN + Tailscale 用户态接入**作为目标架构评估；它需要新增 Tailscale 到 Clash 的可用出站/转发路径及 DNS 集成，不能仅靠启动 tsnet 或复用 ClashBox 前端完成。近期低风险落点是提供互斥模式和明确能力边界，不宣称已经支持全局系统代理、Tailscale split DNS 或 Clash 与 Tailscale TUN 并行。

## 两种模式

| 模式 | VPN 所有者与流量路径 | 可行性和局限 |
| --- | --- | --- |
| **Tailscale TUN + Clash HTTP/SOCKS 代理** | Tailscale 持有系统 VPN；设备路由由 Tailscale TUN 接管。Clash 仅作为本地 HTTP/SOCKS 代理服务，流量须由支持代理的应用显式使用代理。 | 最接近现有 Tailscale Extension。不会产生第二个 TUN；但本项目没有发现创建 Clash HTTP/SOCKS 服务或设置 HarmonyOS 全局系统代理的实现。手工系统代理是否可配置、是否被所有应用遵循，需按目标设备系统版本验证；不能等同于透明接管。Tailscale Exit Node/全局路由与 Clash 代理的选路、回环和 DNS 必须单独定义。 |
| **Clash TUN + Tailscale tsnet / 用户态 SOCKS** | Clash 持有系统 VPN；Tailscale 不创建 `VpnConnection`，改由进程内 Tailscale 网络能力供 Clash 选定流量使用。 | 符合 Clash TUN 只能独占系统 VPN 的约束，也便于让 Clash 决定直连/代理规则。但现有 `backend.go` 使用 `tsnet.Server` 作为 Tailscale 后端，不等于已有可供 Clash 使用的 SOCKS 出站；仓库没有发现 Tailscale SOCKS listener、Clash 出站适配器或该 IPC。需要先基于当前依赖版本设计和实现桥接，并验证 TCP、UDP、DNS 和断线行为。系统不会因此自动获得 Tailscale 子网路由。 |

### 模式切换原则

- UI 明示当前模式、VPN 持有者及切换影响；切换前停止并确认释放当前 VPN，再启动另一方。失败时显示可恢复状态，不并发尝试创建两个 VPN。
- 将 VPN 生命周期编排集中到现有 `VpnCommandGateway` / VPN 管理入口；Clash 模式的服务能力在当前项目未实现，不能假定已有可调用的 Clash Ability。
- 代理配置和 Tailscale 会话状态分开保存。切换 VPN 所有者不得隐式清除账号、密钥或 Clash 配置。

## DNS 与 split DNS

当前 Tailscale Extension 在已就绪配置中明确传入 `dnsAddresses: []`、`searchDomains: []`（`TailscaleVpnExtensionAbility.ets`），故目前没有向系统 VPN 配置提供 DNS 服务器或搜索域。VPN 文档说明配置 `dnsAddresses` 后，被 VPN 代理应用会使用所配置的 DNS；该字段是 VPN DNS 配置，不是按域名分流的 resolver map。不要把添加一个 DNS 地址描述为实现了 split DNS。

- **Tailscale TUN 模式**：下一步须读取并建模 Tailscale 后端提供的 DNS 配置，确定 MagicDNS、搜索域和上游解析路径，再映射到 HarmonyOS VpnConfig 可表达的字段。对多个域名使用不同 resolver 的 split DNS，若平台 VpnConfig 没有相应表达能力，就需由隧道内 DNS 转发器实现域名匹配与上游转发；这属于新增能力，当前没有实现。
- **Clash TUN 模式**：ClashBox 前端包含 DNS 配置项（含 `nameserver-policy`），但其 README 明确后端暂未开放。前端字段不能单独证明内核的实际 split DNS 行为，也不能证明它能访问 Tailscale/MagicDNS resolver。实现时要把 Tailscale 专属域名映射到真实可达的 Tailscale DNS 上游，并避免查询再次被送回同一代理造成循环。
- **验证边界**：同时测试普通域名、MagicDNS 名称、tailnet 搜索域、局域网域名、DNS 上游不可达、网络切换和 VPN 停止后的系统 DNS 恢复。记录查询实际到达的 resolver；只观察 UI 配置或返回 IP 不足以确认 split DNS。

## 子网路由

本项目已有 Tailscale 路由基础：`native/go_bridge/vpnroute/routes.go` 从批准路由构造路由列表；`backend.go:vpnConfig` 把路由交给 Extension；Extension 在 `TailscaleVpnExtensionAbility.ets` 将路由写入 VPN Config。当前 `RouteAll` 偏好控制批准路由的纳入，退出节点默认路由另行处理。该路径依赖 Tailscale TUN 持有系统 VPN。

- **Tailscale TUN 模式**：可延续现有子网路由路径，前提是控制面已批准路由、偏好启用且 Extension 正确安装路由。与 Clash 一起使用时，只有显式使用 Clash HTTP/SOCKS 的应用流量才可能再经 Clash；Clash 规则不会因此透明覆盖 TUN 内所有设备流量。
- **Clash TUN 模式**：系统路由先进入 Clash，现有 Tailscale Extension 不应再创建 VPN。若要访问 tailnet 子网，需设计 Tailscale 用户态转发与 Clash 路由规则的连接，并处理 CIDR 冲突、DNS、MTU、UDP、访问控制和退出路径。现有 `vpnroute.Build` 不能自动把 HarmonyOS 系统路由安装到非 Tailscale VPN 中，也不能把 Tailscale TUN 与 Clash TUN 合并。
- 如果需求只是在 Clash 接管时访问少量 tailnet 服务，可以先验证应用级访问方案；不要将其宣传成全设备子网路由。

## ClashBox 复用边界

`.tools/reference-clashbox/README.md` 明确标注仓库仅包含前端，改版后端暂未开源。当前检出的 `proxy_core` 提供 ArkTS RPC 封装、Go N-API 外壳及 `libflclash.so`，模块类型声明公开的核心入口只有 `startFlClash(fd, callback)` 等很窄的接口；`.gitmodules` 还列出 Mihomo 与 gVisor 子模块。即使本地可见预编译库或封装代码，也没有足够公开源码确认内核实现、稳定 ABI、许可证/版本约束及 Tailscale 出站集成方式。因此**不能完全复用为本项目的可维护 Clash 后端**。可以把前端交互和 VPN 配置流程作为设计参考；真正集成前须取得可审计的后端源码/接口、核验许可并做独立构建验证。

ClashBox 的 `FlClashVpnService` 展示了其自身以一个 `VpnConnection` 创建 TUN、组装 DNS 和路由并把 TUN fd 交给 native 核心的做法。这恰好说明 Clash TUN 会占用同一系统 VPN 通道，不代表该服务可与本项目 TUN 并行。

## 当前代码证据与下一步改动点

以下是设计阶段的候选改动文件；本次只新增本设计文档，没有修改实现。

| 文件/模块 | 当前静态发现 | 若实施，需要的工作 |
| --- | --- | --- |
| `entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets` | 创建 Tailscale VPN Config；带有 Tailscale 地址、tailnet/批准路由；DNS/search domain 为空；`blockedApplications: [BUNDLE_NAME]`；调用 `protectProcessNet()` 并保留失败诊断。 | 抽取/扩展配置生成与模式守卫；只有 Tailscale 模式启动此 Ability；评估 Tailscale DNS 到 HarmonyOS 配置的映射和回滚。保留应用排除与 process protection 的既有保护路径。 |
| `entry/src/main/ets/services/VpnCommandGateway.ets` | 调用 `startVpnExtensionAbility` / `stopVpnExtensionAbility` 启停当前 VPN。 | 增加互斥生命周期协调、启动失败回滚、状态同步和模式切换错误处理；不能在未知 Clash Ability 时硬编码伪入口。 |
| `native/go_bridge/backend.go`、`native/go_bridge/vpnroute/routes.go` | 后端创建 `tsnet.Server`；TUN 设备由 Extension fd 注入；路由生成使用批准路由和偏好。未发现可供 Clash 使用的 SOCKS 服务。 | 对选定的 Clash-owner 方案，先验证当前 Tailscale 依赖支持的 netstack/dial 方式，再设计受控的用户态转发、认证/访问控制、DNS 及生命周期 API；不得仅凭 `tsnet.Server` 名称宣称已实现 SOCKS。路由模型要区分系统 VPN 路由和应用内路由。 |
| `entry/src/main/ets/services/NetworkSettingsGateway.ets` 及相关设置页 | 管理现有 Tailscale 网络设置；无 Clash 共存模式的已验证入口。 | 添加互斥模式选择、当前所有者、DNS/路由能力说明及安全默认值；配置项只暴露已落地且能回读的能力。 |
| ClashBox 参考：`proxy_core/src/main/ets/rpc/FlClashVpnService.ets`、`proxy_core/src/main/cpp/types/libproxy_core/Index.d.ts`、`.tools/reference-clashbox/README.md`、`.gitmodules` | 可见前端 VPN/RPC 调用、狭窄 native 声明和后端未开源说明。 | 在决定复用前取得完整可构建后端及接口/许可材料；当前不应把参考仓库当作可直接链接的源码依赖。 |

### 已有应用排除与 socket 保护

当前 Tailscale VPN Config 已设置 `blockedApplications: [BUNDLE_NAME]`，让 Tailscale 自身应用流量不被该 TUN 捕获；并调用 `VpnConnection.protectProcessNet()` 保护 VPN 进程的网络路径，调用失败时保留应用排除作为兼容兜底。这是本项目已有逻辑，不是尚待实现的 Clash/Tailscale 共存功能。未来 Clash-owner 模式需要为 Tailscale 控制面/隧道 socket 单独设计防回环路径；目前代码没有对应的 Clash 侧 socket protect 集成。

## 建议实施顺序

1. **产品决策**：确定 Tailscale TUN 模式（保留现有全设备 tailnet/子网路由，Clash 仅代理感知应用）与 Clash TUN 模式（优先 Clash 规则，Tailscale 子网需新增用户态桥接）各自支持的功能；明确 DNS 和 exit-node 降级表现。
2. **先做模式互斥**：实现 VPN 所有者状态机和切换失败恢复；验证两种 Ability 绝不会并发运行。Clash TUN 能力必须以有来源、可构建的后端为前提。
3. **选一条路径打通 DNS**：先实现并抓包验证普通 DNS，再验证 MagicDNS 和 split DNS；明确无 resolver mapping 时的限制，不假装系统 `dnsAddresses` 就支持按域拆分。
4. **单独实现子网能力**：在 Tailscale-owner 模式验收当前批准路由；如选择 Clash-owner 模式，先实现一条测试 CIDR 的应用级转发，再决定是否扩展到所有设备流量。

## 真机验收清单

- 设备型号、HarmonyOS 版本/API、网络类型、Tailscale 控制端批准路由和 DNS 配置、Clash 配置版本均记录在测试报告。
- 启动 Tailscale TUN 后尝试切到 Clash TUN，反向再测；每次确认原 VPN 完成停止/释放，新 VPN 才启动。覆盖用户拒绝授权、创建失败、强制停止、重启及快速连续切换。
- Tailscale-owner 模式逐项验证 tailnet IPv4/IPv6、批准子网、exit node、LAN 访问偏好和普通互联网；抓包核实流量归属、DNS resolver 及无回环。
- Clash-owner 模式逐项验证 Clash 规则、直连/代理流量、Tailscale peer 和测试子网；确认隧道 socket 不回流进 Clash，测试 TCP/UDP、IPv4/IPv6、MTU 和断网恢复。
- DNS 验收覆盖公网域名、MagicDNS、tailnet 搜索域、内部 split-DNS 域名、IP 字面量、DNS 上游故障及停 VPN 后恢复；抓包或服务端日志确认实际 resolver 和查询路径。
- 验证应用排除：Tailscale/Clash 进程及保护 socket 的公网控制连接不会进入自身 TUN；记录 `blockedApplications`、`protectProcessNet` 成功/失败结果与故障时的流量行为。
- 明确验收结论的范围：编译成功不等于 VPN 共存、DNS split、子网路由或真机网络行为通过。
