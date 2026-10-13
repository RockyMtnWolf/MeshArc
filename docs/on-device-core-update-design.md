# Tailscale Core 更新设计与可行性研究

## 结论摘要

这里的“Tailscale 内核”指应用内的 Tailscale Go userspace engine（当前打包为 `libtailscale_go.so`），不是 HarmonyOS/设备操作系统内核。

| 能力 | 结论 | 边界 |
| --- | --- | --- |
| 在 HarmonyOS PC 应用内查询上游版本 | 可行，限元数据查询 | 使用固定的 `tailscale/tailscale` GitHub Releases/Tags 来源；未认证公开读取，不需要 API token。网络不可达、限流、API 格式变化时降级为手动查看 GitHub 页面。只显示“发现版本”，不代表该版本适配本项目。 |
| 在 HarmonyOS PC 应用内自动拉源码、构建 Go `.so` | 有条件可行，目标 PC host 能力未验证 | 必须能在目标 PC 执行适配系统/CPU 的 Go bootstrap/toolchain、Native SDK host clang/linker/sysroot 和构建驱动。Windows 本地 SDK 不证明目标机能运行这些 host tools。先验证；未证实前使用受控外部构建机 fallback，不宣称端侧编译已实现。 |
| 端侧 HAP 签名 | 技术可行，有 HapInstaller C++ N-API 实证 | 集成 `hapsigntool` 后可用本地私钥/profile 签 HAP；测试链不等于正式发布身份，也不授予系统特权或静默安装权限。 |
| 更新 `.so` 的系统签名与热加载 | 当前无安全实现 | 官方系统 `SignLocalCode` 是受 AccessToken/SELinux 调用者约束的 LocalCodeSign 服务，不是第三方应用通用 API。HapInstaller 的 HAP `localSign` 不等于 ELF 系统签名。Go runtime/ABI/句柄/状态迁移和加载器策略也未实现。 |
| 安装新签名 HAP | 端侧 HDC 路径有开源实证，但 VPN 期间禁止 | HapInstaller 声明 `2in1`，集成 HDC `install -r`；同 bundle 自替换会 kill 当前应用。全量 HAP 更新会中断 VPN Extension/TUN，只能作为人工断开 VPN 后的维护升级。 |

**推荐交付**：分阶段实现“上游检查 → 沙箱拉源码 → 可复现构建候选 `.so` → 嵌入并生成候选 HAP → 端侧签名 → 用户导出/人工确认安装”。端侧构建取决于 API 26 PC host 工具链验证；HapInstaller 证明端侧签名/HDC 路径可实现，但不自动赋予本应用这些能力。VPN 活跃期间不自动安装/替换 HAP；内核 `.so` 随完整 HAP 经人工维护窗口替换，会造成 VPN 断开。目标 host 验证后再决定端侧自举或外部构建机。

## 已核验对象

- `LMV475/hap-installer` 是正确的候选项目：其 `AppScope/app.json5` 的 `bundleName` 为 `cn.lxh.hapinstaller`，仓库 README 描述为 HarmonyOS Next 端侧 HAP 签名/安装工具，模块声明包含 `2in1` 设备类型。该核验只证明 GitHub 源码身份和声明；本次按要求没有查询设备，因此**没有验证当前设备实际安装包、版本、签名者或可调用能力**。
- `.tools/reference-hapinstaller` 对应用户确认的 `LMV475/hap-installer` 主源。`entry/src/main/cpp/hapsigner/napi.cpp` 通过 N-API 调用 `ParamsRunTool::ProcessCmd`，ArkTS 构造 `signtool sign-app -mode localSign`；签名使用应用提供的 p12、证书和 profile。README 明确依赖源码、补丁和自行准备签名材料，不能当作现成二进制/SDK。它证明普通应用可集成软件 HAP signer，但不证明普通应用能调用平台 LocalCodeSign 的 ELF 签名权限。
- `entry/src/main/cpp/hdctools/napi.cpp` 暴露应用进程内 HDC server/命令执行；`Home.ets` 有用户确认流程、`install -r`，并将同 bundle 自身安装记录为 `killed_expected`。模块声明包含 `2in1`，权限声明为 INTERNET、GET_NETWORK_INFO、KEEP_BACKGROUND_RUNNING；没有声明系统静默安装权限。源码证明端侧 HDC 安装路径存在，不证明免授权安装，更不提供 VPN 不断的升级能力。HapInstaller 没有可由本项目直接调用的稳定跨应用签名/安装 API；可审核后集成 Apache-2.0 代码及依赖，或重做最小 N-API。
- 按用户确认，TermForge 没有开源主源；不猜内部实现，不把它纳入保活或构建方案。若之后有公开接口/文档，再单独评估。

参考主源：[HapInstaller README](https://github.com/LMV475/hap-installer)、[HapInstaller Releases](https://github.com/LMV475/hap-installer/releases)、[HapInstaller bundle 配置](https://github.com/LMV475/hap-installer/blob/main/AppScope/app.json5)、[OpenHarmony hapsigner](https://github.com/openharmony/developtools_hapsigner)、[OpenHarmony HDC](https://github.com/openharmony/developtools_hdc_standard)、[OpenHarmony code signature](https://github.com/openharmony/security_code_signature)、[Tailscale v1.86.5 release/tag](https://github.com/tailscale/tailscale/releases/tag/v1.86.5)。本节来源只使用 GitHub 项目主源；本仓库文件作为本地实现证据。

## 官方工具与主机支持

### SDK、打包与安装

OpenHarmony 官方 `developtools_hdc_standard` 说明 HDC 的 host client/server 与设备侧 daemon；列出的 host 平台为 Windows、Linux、macOS。它没有证明 HarmonyOS PC host 不可能，只能说明该 README 未确认 HarmonyOS PC host 支持承诺。

OpenHarmony `developtools_hapsigner` 提供 Java `hap-sign-tool.jar`（JRE 8+）和 C++ 形式的 hapsigner；官方源码说明其可生成密钥/证书/CSR，签 profile、HAP 和 binary tool。C++ 版本按 OpenHarmony SDK 形态构建，不是可直接嵌入本项目 ArkTS 的现成动态库。HapInstaller 则是另一款集成了 hapsigner/hdc 的端侧应用，但其前置条件、证书来源和闭源/缺失组件限制见上一节。

HAP 签名只解决包完整性和签名身份问题。设备安装还需证书链、profile、bundle/version 和系统安装策略满足要求；项目没有拿到维护者正式签名私钥时，无法产出可升级现有正式安装的同身份签名包。Debug/自签名材料不能代替正式 Release 身份。签名材料只能来自 DevEco/AGC 或维护者批准的安全密钥流程。

### HarmonyOS PC 作为构建机

本次本机环境是 Windows 11 x64，安装 DevEco Studio 26.0.0.821、SDK `26.0.0`；本地 Native SDK 含 OHOS sysroot/LLVM、Windows 版 HDC/校验工具。这证明 Windows host 交叉编译/打包环境存在，**不是**目标 HarmonyOS PC 的 host 能力证据。未访问目标 PC 或操作设备，目标机 CPU 架构、API 26 下应用能否执行 host tools、完整 SDK/Go host 编译器可否运行都未验证。没有官方 GitHub 文档确认 HarmonyOS PC 是 DevEco/Hvigor/Go 构建 host。

不能把“官方未列出 host 支持”写成“端侧绝对不可能”。目标 API 26 PC 上应只读盘点：CPU/系统架构、官方 SDK 是否提供匹配 host 的 `java`/`node`/Hvigor/clang/ld/ar、Go bootstrap/toolchain 能否在应用沙箱执行、OHOS cgo sysroot 是否完整、源码/产物文件权限以及 HDC 本机安装限制。Windows SDK 交叉编译器不是 HarmonyOS PC 可执行 host 工具的证据。端侧构建是待验证可行路线；实测这些工具运行并可复现构建后才可确认为支持，否则回退到受控 Windows/Linux 构建机。

### 端侧签名、系统权限与安装边界

- **HAP 软件签名**：可把 HapInstaller 所集成的 hapsigntool 及其开源依赖审计后编入本应用 N-API，使用 p12、证书和 profile 签署候选 HAP。必须满足既有应用的签名身份、bundle/profile/version 策略。正式私钥不应放在可提取的普通应用沙箱；优先维护者签名服务或硬件保护密钥。不得复用参考项目测试凭据/证书。
- **系统 ELF 签名**：官方 `security_code_signature` 的 `SignLocalCode` 属系统 LocalCodeSign 服务，不等同 HAP signer。其源码权限检查限定调用者（`compiler_service`；初始化证书另限 `key_enable`），并依赖 HUKS/AccessToken/SELinux；普通第三方应用不能假定有此权限，也不得伪造系统 token。当前无公开证据表明本项目 app 可取得该特权。
- **HDC 安装**：参考应用把 HDC 编入 N-API，经调试连接运行 `install -r` 并要求用户确认；这不是普通 BundleManager API 或静默安装授权。复用到自更新仍需在目标 API 26 PC 核验调试连接/本机目标/自替换行为与恢复能力；HapInstaller 源码明确同 bundle 替换会 kill 当前进程。

## 本项目现有构建链

本地只读检查发现：

- `docs/development.md` 将架构描述为 ArkTS → VPN Extension → C++ N-API → OpenHarmony arm64 Go shared library → Tailscale userspace engine；当前 Tailscale 固定版本写为 `1.86.5`，MagicDNS 关闭。
- `scripts/build-go.ps1` 当前采用 `GOOS=openharmony`、`GOARCH=arm64`、`CGO_ENABLED=1`、DevEco Native SDK 的 OHOS clang/sysroot，输出 `libtailscale_go.so` 并复制到 `entry/libs/arm64-v8a/`。它要求预先构建的 `third_party/ohos-go/bin/go.exe` 及 `third_party/tailscale` 源树，并对 Go/Tailscale 应用本仓库补丁。
- `scripts/build.ps1` 负责选择 SDK/Hvigor 并构建 HAP；签名配置来自本地忽略文件 `build-profile.json5`，示例配置不含凭据。发布入口有 Release changelog gate。
- 工作区中的 `scripts/build-go.ps1` 在本任务开始前已是未提交修改。本设计只记录当前可见实现，不评判或覆盖这些用户改动；新增自动更新方案应先在干净、锁定的 build runner 上复核其脚本和补丁状态。
- 当前项目已有 Windows 主机 Go/HAP 构建步骤，但 Go fork 的上游项目在本仓库 `docs/build-macos.md` 中指向 GitCode，不在本次允许的 GitHub 主源范围内。故本设计不把该 fork 的维护者身份、提交签名或 GitHub 镜像状态视为已验证；它是当前构建的外部依赖 blocker，需另行审核并锁定准确 commit。

这条链可支持**受控 PC 构建机**为 HarmonyOS 目标交叉编译 `.so` 和 HAP；它不等于设备端原生自举编译链。普通上游 Go 官方发行版也不能直接替代当前 `GOOS=openharmony` fork/cgo/ABI 适配。

## 可行的更新工作流

### 阶段 A：应用内只检查上游

1. 固定唯一 repo 为 `tailscale/tailscale`，查询 GitHub Releases/Tags 的公开只读元数据；不接受用户可编辑 URL、重定向到任意主机、压缩包内执行脚本或 `latest` 二进制。
2. 展示上游 tag、提交 SHA、签名验证状态、当前嵌入版本、检测时间和“尚未验证此版本适配 HarmonyOS”的提示。检测动作不拉源码、不下载 `.so`、不签名、不停止 VPN。
3. 可增加手动检查入口与定期提示；网络失败/限流时保留上次成功结果并显示过期时间。公开 API 不需要 token；若未来访问私有源，凭据走受保护的用户授权/系统凭据存储，绝不硬编码进源码、HAP、日志、链接或更新清单。

### 阶段 B：受控构建机生成候选包

1. 由维护者批准目标 Tailscale 版本；按固定 tag/commit 拉取**源码**，验证 tag 的 GitHub Verified 签名/预期 signer 身份，并锁定完整 commit SHA。拒绝 tag 被移动、无签名/身份不匹配或提交不在已审核策略内的情形。
2. 使用锁定的 OpenHarmony Go fork commit、Go bootstrap 版本、DevEco SDK 组件版本、补丁 SHA-256、`go.sum` 和依赖来源清单构建；自动更新只生成候选，不自动合并或发布。记录工具链版本、构建日志、源 commit、patch digest、产物 SHA-256 和 SBOM/provenance。
3. 构建 `libtailscale_go.so` 后检查 ELF 架构、动态依赖、导出 C ABI、版本标记；运行可重复的静态/单元验证及受控环境 HAP 构建。任何下载的 source archive 都只作输入数据，不执行仓库脚本，除非已审核并在隔离 runner 中执行。
4. 把 `.so` 放入 HAP 原有 native library 路径，构建完整候选 HAP；用官方 HAP signer 验签并检查包名、版本、profile、证书链。HapInstaller 证明端侧 hapsigntool N-API 路径可实现；本应用需集成并维护 signer/依赖，或调用维护者签名服务。正式私钥优先由硬件密钥/受保护服务持有，不能放入普通 app 沙箱。
5. 候选 HAP 交人工发布/兼容性评审并可导出；本设计不授权 VPN 活跃时安装。即使端侧签名成功，也不代表获得正式签名身份、系统 ELF 签名权限或静默安装授权。

### 阶段 C：版本与回滚管理

- 每个版本清单至少绑定 Tailscale tag、完整 commit SHA、签名校验结果、Go fork commit、补丁与 SDK 版本、HAP versionCode、包 SHA-256、签名证书指纹、最低/最高兼容 API 和测试结论。客户端对清单做签名验证；TLS 和 HTTPS 仅保护传输，不替代签名。
- SHA-256 必须与独立可信、签名的清单绑定；仅下载 HAP 后从同一未签名页面取 SHA 不构成供应链验证。支持离线导入时同样要求包签名和 SHA 校验。
- 保留上一已批准源 commit、完整构建输入、签名 HAP 和验证报告。回滚须先验证设备安装策略是否允许版本回退及证书身份是否一致；如果禁止降级，只能发布更高 versionCode 的修复版。不得在客户端覆盖已加载 `.so` 作为回滚方式。
- Release 私钥/keystore 及密码不得内置；更新签名信任锚和 source signer allowlist 要有轮换/撤销流程。不要把 GitHub API token 写入源代码或 HAP；读取公开 Tailscale 项目无需 token。

### 自动与手动模式

- **可先实现的自动模式**：定时查询固定 GitHub 上游、提醒用户、验证签名清单；在 API 26 host 能力验证后，可自动拉源码并在沙箱生成未发布候选。签名可以由端侧集成的 HAP signer 使用受保护密钥流程完成，但正式 key 不得嵌入应用。自动模式不得自动替换正在运行的 HAP/VPN。
- **手动模式**：用户点击检查/拉取，经维护者批准版本后生成候选；审核摘要、源 commit、验证结果和 SHA-256，选择签名服务/授权密钥签 HAP，再导出或在确认 VPN 已断开后使用受支持的 HDC 调试安装路径。任一阶段不支持时，产物交外部受控构建/签名机，不伪造“本机已完成”。
- **原版限制**：两种模式都不能实现已加载 Go `.so` 无中断替换。由于全包更新会杀进程，运行 VPN 的设备必须保留旧包直至用户进入维护窗口；不能后台下载完即安装。

## 禁止方案与 VPN 中断

1. **禁止**在 VPN 连接期间自动替换、安装或静默重启整个 HAP；此举会结束当前 Ability/应用进程，系统 VPN/TUN 中断，正是原版禁止的升级行为。
2. **禁止**下载任意 `.so` 后直接复制到 HAP/私有目录并热加载；签名、代码完整性、动态加载策略、ABI、Go runtime 单例及 goroutine/FD 清理均无实现和验证。
3. **禁止**在没有维护者批准的签名凭据时用 HapInstaller 自签名证书冒充现有正式签名；不同签名身份不能作为同一应用的无缝升级身份。
4. **禁止**让“查到新 tag”直接触发源码执行、发布构建、签名或安装。自动化只生成可审计候选，签名和发布必须过受控 gate。

## Blockers 与解除条件

| Blocker | 影响 | 解除条件 |
| --- | --- | --- |
| HarmonyOS PC API 26 host 编译链未知 | 端侧自编译暂不能确认为可用，但不能据此断言不可能 | 在目标 PC/API 26 核验 CPU/系统架构、官方 SDK host 组件及 Go bootstrap 可执行性、沙箱执行权限、OHOS cgo linker/sysroot，完成构建和复现验证；否则使用 Windows/Linux 受控 runner。 |
| OpenHarmony Go fork 的 GitHub 主源/身份未核验 | Go toolchain 供应链无法只靠 GitHub 主源锁定 | 维护者批准 fork 正确上游、可信来源、固定 commit、patch 和可复现 bootstrap；当前本地开发文档指向 GitCode，超出本任务来源范围。 |
| `.so` 无热更新 ABI/卸载协议 | 不能无中断替换已加载引擎 | 设计并独立验证安全进程边界/版本化库装载、会话迁移、fd/状态交接和故障恢复；否则明确要求 VPN 断开后更新，且仍受原版禁止约束。 |
| 正式签名身份、profile 与私钥托管方案待维护者确认 | 可产测试签名候选，不能保证升级正式安装 | 提供维护者签名服务或硬件保护密钥、正式 profile 和证书轮换/撤销流程；release 私钥不驻留普通 app 沙箱。 |
| HapInstaller 不是跨应用 SDK，端侧依赖需集成 | 不能直接调用已安装应用完成签名/安装 | 审核并集成 Apache-2.0 N-API/依赖，或独立实现；核验依赖许可证/补丁和 API 26 兼容。安装仍需目标机调试/授权策略与人工维护窗口验收。 |
| 端侧 HDC 自安装限制未在目标 PC 验证 | 不承诺自动自更新 | 核验 API 26 PC 调试授权、本机 HDC target、自替换行为、失败恢复和用户确认路径；VPN 活跃时仍禁止全 HAP 替换。 |

## 后续实施建议

1. 先只读核验目标 HarmonyOS PC API 26 的 host 架构/SDK/Go 工具链；证实可执行后，在隔离沙箱验证源码拉取、可复现构建及资源/权限预算。否则采用现有 Windows/Linux runner；端侧仍可负责检查、下载源/候选、验证清单和 HAP 签名。
2. 明确密钥托管、HAP signer 集成和 API 26 HDC 安装约束后，才实现候选生成/签名/导出；入口应明确表达真实阶段，不能以 UI 按钮宣称未实现能力。
3. 全量 HAP 替换安排在用户人工断开 VPN 的维护窗口。若未来要求 VPN 不断，需另立引擎隔离、版本化装载、会话迁移和真机故障恢复项目，不能用 `.so` 覆盖或 HapInstaller 自替换代替。

## 验收与本次范围

更新系统未来验收至少覆盖：上游新 tag/无更新/无网络/限流/签名错误/tag 移动/恶意重定向；重复构建的源与产物 provenance；错误证书、旧版本/降级、错误 API/ABI、损坏 HAP、存储不足；VPN 活跃期间全程不触发安装/进程重启；用户取消和失败后的配置/网络状态恢复。

本次只做只读源码/仓库研究和 GitHub 主源查阅，并新增本文件；未操作设备、未下载源码/SDK/二进制、未构建/签名/安装、未修改其他文件，未运行测试。工作区原有未提交改动（包括 `scripts/build-go.ps1`）保持原状。
