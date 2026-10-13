/**
 * Release changelog editor
 *
 * 每次准备发布时只编辑本文件：
 * 1. 把最新版本放在 RELEASE_CHANGELOG_ENTRIES 的第一项；
 * 2. 让 versionName/versionCode 与 AppScope/app.json5 完全一致；
 * 3. 填写至少一条中英文更新内容和发布日期；
 * 4. 旧版本按时间顺序保留在后面。
 *
 * Release 构建会校验第一项，内容为空或版本不一致时会直接失败。
 */
export interface ReleaseChangelogDefinition {
  versionName: string;
  versionCode: number;
  releaseDateZh: string;
  releaseDateEn: string;
  changesZh: string[];
  changesEn: string[];
}

export const RELEASE_CHANGELOG_ENTRIES: ReleaseChangelogDefinition[] = [
  {
    versionName: '1.1.1-dev',
    versionCode: 100000004,
    releaseDateZh: '2026年10月13日（开发测试版）',
    releaseDateEn: 'October 13, 2026 (development test build)',
    changesZh: [
      '设置子页保留自选背景与悬浮卡片，恢复滚动底部留白，移除背景选择页图片预览',
      '可选模拟保活模式与桌面状态栏入口：仅保留下载和低音量本地长音频；模拟下载不传输文件，系统仍可能回收应用',
      '托盘注册成功时，标题栏关闭默认最小化，不主动停止连接',
      '新增用户态 SOCKS 127.0.0.1:1055 与 ClashBox 规则复制入口，不创建第二个系统 VPN；共存、DNS、UDP 与子网流量仍需真机验证',
      '新增底栏 FRP 运行和 FRP 配置两页、frpc 客户端、TOML 导入/文本编辑与 TCP/UDP 可视配置、独立启停和后台任务；公网映射尚未验收',
      '连接操作增加超时与后端失效恢复，桌面弹层避免自动分栏导致的裁切',
      '反馈邮箱更新为 smartwolf@stu.xidian.edu.cn；Tailscale 内核仍为 1.86.5'
    ],
    changesEn: [
      'Preserve custom backgrounds and floating cards in settings, restore scroll clearance, and remove the background image preview',
      'Added optional simulated keepalive modes and a desktop status-bar entry: download and quiet local audio only; simulated downloads transfer no files and reclamation remains possible',
      'Minimize title-bar close requests when the desktop tray is registered, without intentionally stopping connections',
      'Add a userspace SOCKS listener on 127.0.0.1:1055 and ClashBox rule snippets without a second system VPN; coexistence, DNS, UDP and subnet traffic remain unverified on device',
      'Add FRP runtime and configuration tabs, an embedded frpc client, TOML import/text and TCP/UDP form editing, independent lifecycle and background tasks; public port mapping remains unverified',
      'Bound connection operations, recover stale backend state, and prevent unintended split layouts in desktop sheets',
      'Use smartwolf@stu.xidian.edu.cn for feedback; the Tailscale core remains 1.86.5'
    ]
  },
  {
    versionName: '1.1.0',
    versionCode: 100000003,
    releaseDateZh: '2026年9月23日',
    releaseDateEn: 'September 23, 2026',
    changesZh: [
      '新增 VPN 连接后的持续后台任务与流量通知，显示本次连接的真实上传和下载总量',
      '改进后台连接恢复：短暂状态读取异常不再立即停止保护任务；系统取消后延迟重试，用户主动关闭后尊重其选择',
      '优化连接状态更新，避免设备探测阻塞心跳，减少可选服务查询失败导致的错误断开提示',
      '修复主页设备列表过长时无法滚动到底的问题，优化设备详情半模态滚动与底部导航手势',
      '修复更新日志面板关闭及显示偏好操作，并优化底部导航的图标、文字和渐变遮罩'
    ],
    changesEn: [
      'Added a continuous background task and VPN traffic notification showing real upload and download totals for the current connection',
      'Improved background recovery: tolerate brief status-read failures, back off retries after system cancellation, and respect explicit user dismissal',
      'Start connection heartbeats before peer probes and avoid false disconnect reports when optional service snapshots fail',
      'Fixed scrolling to the end of long Home device lists and refined device-detail sheet scrolling and bottom-navigation gestures',
      'Fixed release-note dismissal and display-preference actions, and refined bottom-navigation icons, labels and gradient masking'
    ]
  },
  {
    versionName: '1.0.1',
    versionCode: 100000002,
    releaseDateZh: '2026年8月25日',
    releaseDateEn: 'August 25, 2026',
    changesZh: [
      '修复主页设备列表过长时无法滚动到底的问题'
    ],
    changesEn: [
      'Fixed an issue that prevented the Home device list from scrolling to the bottom when it was long'
    ]
  },
  {
    versionName: '1.0.0',
    versionCode: 100000000,
    releaseDateZh: '2026年8月19日',
    releaseDateEn: 'August 19, 2026',
    changesZh: [
      '合作联动：MeshArc设备卡片→媒体→点击跳转到HosPlayer；需在远程媒体服务器上安装并配置Tailscale',
      '新增应用锁：每次应用返回前台时通过系统身份验证解锁，支持设备已启用的人脸、指纹或 PIN；仅保存开关策略，不保存任何身份凭据或认证令牌',
      '新增文件夹锁：可在 Taildrive 中锁定指定远程文件夹及其全部子内容，访问受保护目录和调整锁定规则时均需系统身份验证；重命名、移动或删除文件夹后会同步更新锁定规则',
      '新增安全设置与诊断：集中查看应用锁、文件夹锁和受保护文件夹数量，并可运行不修改设置的系统身份验证自检',
      '优化设置界面：保留账户卡片，按网络、外观、存储、关于和安全分类进入二级页面；统一页面标题、材质和连续滚动的半模态交互',
      '优化外观与动效：支持背景图片、沉浸色彩和材质效果；动画预设、时长、幅度与阻尼可预览并自动保存到本地偏好',
      '优化存储与更新日志：新增本地数据、已接收文件和临时缓存的环形占用统计；更新日志支持按版本横向浏览，最新合作图展示在详细内容顶部',
      '更新 HosPlayer 服务器导入链接，并修复连接、传输和媒体联动中的若干边界问题'
    ],
    changesEn: [
      'Partnership integration: MeshArc device card → Media → tap to open HosPlayer; install and configure Tailscale on the remote media server',
      'Added App Lock: each return to the foreground requires system authentication using enrolled face, fingerprint, or PIN; only the lock policy is stored, never credentials or authentication tokens',
      'Added Folder Lock: protect a selected Taildrive remote folder and all of its contents; opening protected folders or changing their lock policy requires system authentication, and lock rules follow folder rename, move, and delete operations',
      'Added Security settings and diagnostics: view App Lock, Folder Lock, and protected-folder counts together, then run a system-authentication self-test without changing settings',
      'Polished Settings: retain the account card and organize Network, Appearance, Storage, About, and Security into second-level pages with consistent titles, material, and continuously scrolling bottom sheets',
      'Polished appearance and motion: choose a background image, immersive color, and material effects, then preview and persist animation presets, duration, amplitude, and damping',
      'Polished storage and release notes: added a ring summary for app data, received files, and temporary cache; release notes now browse by version horizontally and show the latest partnership image above the details',
      'Updated the HosPlayer server import handoff and fixed several connection, transfer, and media integration edge cases'
    ]
  },
  {
    versionName: '0.9.10',
    versionCode: 99000002,
    releaseDateZh: '2026年8月3日',
    releaseDateEn: 'August 3, 2026',
    changesZh: [
      '完善 MeshSend 文件传输流程',
      '优化响应式首页布局',
      '增加 VPN 与媒体联动诊断'
    ],
    changesEn: [
      'Expanded the MeshSend file transfer flow',
      'Polished the responsive home layout',
      'Added VPN and media integration diagnostics'
    ]
  },
  {
    versionName: '0.9.8',
    versionCode: 9800000,
    releaseDateZh: '2026年7月29日',
    releaseDateEn: 'July 29, 2026',
    changesZh: [
      '完成 Taildrop 收发文件流程',
      '增加媒体服务发现',
      '改进 VPN 启动与恢复'
    ],
    changesEn: [
      'Completed the Taildrop send and receive flow',
      'Added media service discovery',
      'Improved VPN startup and recovery'
    ]
  }
];
