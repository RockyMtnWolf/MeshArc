# MeshArc 1.1.1-beta.1

**预发布版本** · Build `100000005` · HarmonyOS 6.1 / API 23 · arm64
独立应用包名：`io.github.rockymtnwolf.mesharc`

本说明记录当前 beta 的实际改动和验收边界，不代表 AppGallery 上架、正式发布或所有网络场景通过。

## 本次更新

- 修正 Tailscale 用户态 peer 探测与传输状态更新，避免将可直连 peer 显示为恢复中。
- 改进 Clash VPN 保持开启时的用户态共存与 LocalSend 状态刷新。
- FRP 配置页支持多配置和独立 worker，并整合为单页管理；新增从系统 FilePicker 导入 TOML。
- FRP 依赖固定为 v0.52.0 兼容性回退版本；当前已通过一条既有配置进行内嵌设备端协议验流。
- 使用 HarmonyOS `hideAbility` 的标题栏关闭/托盘驻留路径通过短时设备验收。
- 增加 Clash 配置 YAML 修复并导出副本，以及显式 TCP-only 入站策略选项。
- 应用身份采用独立 MeshArc bundle；不再以原上游应用身份作为发行目标。

## 验收记录

- FRP v0.52.0 兼容版独立 HAP 已构建并安装；打开既有配置卡片后，native phase 显示已连接 frps。
- Clash VPN 保持开启时，传输页手动刷新显示恰好 2 个 LocalSend 在线节点，没有“无连接”条目。
- 同一共存状态下，主页 native probe 显示 3 个 peer 均为 direct，延迟为 84、35、14 ms；界面不再显示恢复中。
- MateBook 系统 FilePicker 成功导入原有 TOML；表单保留域名、user、TLS 标志和原有端口，未出现 `NoSuchFile`/`ENOENT`。未另存新增配置，也未申请额外端口。
- 主代理复核截图 51/52/53/66/74：界面无遮罩，footer 不遮挡内容，五个导航图标均匀放大，TCP 协议标签可见。截图 76 实际复核通过：第二条空白映射可新增并滚动编辑，保存/取消固定按钮无遮挡。未填写新公网端口，也未保存第二条映射；这是 UI 新增 entry 验收，不是额外隧道或公网网络验收。私密截图不纳入仓库。
- 修复 IP helper 的 `layoutWeight` 造成的纵向空白，并调整成功/错误状态颜色以改善主题语义对比度。最终 UI build 用时约 52 秒且 USB 安装成功；主代理正在复核截图 80/81，本条不预判最终截图结论。
- 既有 ClashBox 共存验证还覆盖 RDP 出站及 USB/IP 入站。这些观察不等于 DNS、UDP、子网路由或普遍多 VPN 行为通过。
- Windows 经唯一既有映射发送 USB/IP `devlist`，收到协议版本 `0x111`、命令 `0x5`、状态 `0`、设备数 `1` 的响应。此证据证明单条隧道的外网协议往返，不证明真实 USB 设备 attach、读写或多条公网隧道。
- 标题栏关闭后，主窗口从窗口列表消失；同一既有 USB/IP 映射立即及约 1 分钟后再次返回 `devlist` 状态 0、设备数 1。该结果支持短时后台连续性，不等于强制退出后仍运行，也不是长期保活证明。对应私密截图未纳入仓库。
- 用户提供的 v0.51 Sakura 专有模式 INI 不受 stock v0.52 客户端支持；已通过的是 v0.52 与原 TOML 配置路径，不应将两种配置/模式混为一谈。
- Node 回归测试 160 项通过。测试结果、兼容版 HAP 构建/安装、Release root HAP 构建、签名和 USB 安装分别记录，不互相替代。
- Release root 已生成 build `100000005` 未签名 HAP，尚未发布。独立兼容版 HAP 的安装不代表该 root HAP 已签名或可作为正式包安装。

## 已知限制

- FRP 目前仅验收一条既有隧道的协议响应；没有验证真实 USB 设备 attach/读写，也没有验收多条公网隧道。未新增公网服务或映射申请；worker 的 `running` 状态本身不等价于已连接或公网可达。
- 截图 76 通过的是新增第二条空白映射的 UI 交互；没有保存新公网端口，也没有进行第二条映射网络验收。
- 截图 80/81 的最终 UI 复核仍待主代理确认；本记录不替代该确认。
- `hideAbility` 仅完成上述短时关闭/后台验收；强制退出恢复和长时间后台保活仍未验证。
- LocalSend 本次验证覆盖发现/在线状态，不代表完整文件传输或所有设备互通均已通过。
- Clash 共存尚未覆盖 DNS、UDP、MagicDNS 和子网路由；HarmonyOS 同时只能运行一个系统 VPN 服务。
- MagicDNS 尚未启用。设备重启后的重连可能需要用户操作。
- CoreUpdate 仅检查上游版本元数据并导出构建请求；端侧自动拉取源码、编译、签名及安装未实现。完整 HAP 升级会中断 VPN；`.so` 热替换未实现。
- 本项目不提供签名私钥、profile 或正式签名身份。当前 Release root HAP 未签名，不能作为常规应用包直接安装；使用者须自行准备有权使用且设备接受的签名配置。请勿把独立兼容测试包的安装视为 root Release HAP 已签名。
- 尚无 AppGallery 上架链接。

## 源码与分发

公开仓库：[RockyMtnWolf/MeshArc](https://github.com/RockyMtnWolf/MeshArc)。后续如发布 beta，计划通过 GitHub Releases 提供对应 beta 说明和经签名/验签的发行包；此处描述的是未来发布流程，不表示此前已有发布或当前已有可下载发行包。最终 Releases 链接待主代理确认后补充。

不在本说明中记录个人账号、tailnet 地址、服务器域名、端口或服务凭据。MeshArc 由 Tailscale 上游项目衍生，继续遵循仓库 [BSD 3-Clause 许可证](../LICENSE)；第三方组件的版权与许可证仍分别适用，详见[第三方声明](../THIRD_PARTY_NOTICES.md)。
