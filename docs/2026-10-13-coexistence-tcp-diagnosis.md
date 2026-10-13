# ClashBox 共存 TCP 诊断

## 复现条件与证据

- USB MateBook Pro S，独立测试应用 `io.github.tailscaleohos.devtest`；原版未覆盖。
- 用户确认：远程桌面由 MateBook 向 Windows `<WINDOWS_TAILSCALE_IP>:3389` 发起；USB/IP 由 Windows 向 MateBook TCP 3240 发起。
- Windows 测试服务端口为 3389。测试应用、原版的实际 Tailscale 地址已脱敏，不在公开记录中披露。
- 用仅监听 Windows 回环的 USB 转发分别连接 MateBook SOCKS 1055、ClashBox mixed 7890。
- 直接经 1055 的 SOCKS 握手及 CONNECT 成功；发送 RDP X.224 协商请求收到正常响应 `030000130ed00000123400022f080002000000`。ClashBox 开启前后均成功。
- 同样请求经 ClashBox 7890，SOCKS CONNECT 返回成功，但收到 EOF，未获得 RDP 协商响应。故障范围缩小至 ClashBox 规则/策略路径；尚未取得该连接实际命中规则，不能断言具体配置错误。
- 直接经 1055 的诊断探针进一步完成 TLS 1.3 握手并取得 740 字节证书；ClashBox 7890 在 TLS 开始前即断开。诊断探针只读取证书、不登录；未更改用户远程桌面客户端证书验证设置。
- 检查时 MateBook TCP 3240 没有监听，已请求用户启动 USB/IP 服务，不能宣称该服务真机验收通过。

## 已定位的实现缺口

- tsnet 用户态 `getTCPHandlerForFlow` 对未注册监听的流返回 `nil, true`：不转发本机服务。TUN 模式的本机服务可达，不表示用户态自动提供相同入站能力。
- 共存 SOCKS 只解决出站；入站需要独立、显式的本机 TCP 端口白名单桥接，不应无条件暴露所有回环服务。
- 首页使用系统 VPN 状态显示“未连接”，不能表示用户态后端是否在线；共存状态需单独标示，不暗示流量已经验收。
- 分流规则仅放在 MATCH 前不够：仍可能先命中更早的 DIRECT 或宽泛规则。Tailscale 专用规则应排在这些覆盖规则之前，并核对实际生效策略。
- 脱敏配置审查确认两类问题：SOCKS 节点放置层级错误；Tailscale 分流被较早的宽泛 DIRECT 规则覆盖。已生成独立修正副本；公开记录不包含测试账号、用户配置内容、节点凭据或私人地址。

## 验收边界

- RDP 初始协商成功不是登录/桌面会话成功，也未获取证书或密码。
- ping 与控制台在线不能替代 TCP 服务连通。
- `0x2000D` 是客户端报告，现有证据不足以映射到唯一原因；不应据此关闭证书校验或修改 Windows 防火墙。
- 仍需用户脱敏后的代理定义与规则位置、真实服务启动后入站测试，以及 ClashBox 规则命中证据。
