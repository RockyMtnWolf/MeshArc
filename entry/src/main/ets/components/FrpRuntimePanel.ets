import { common } from '@kit.AbilityKit';
import { FrpConfig, FrpProxy, parseFrpToml, validateFrpConfig } from '../services/FrpConfig';
import { FrpGateway, FrpRuntimeStatus } from '../services/FrpGateway';

@Component
export struct FrpRuntimePanel {
  @State private status: FrpRuntimeStatus = {
    state: 'unknown', error: '', proxyCount: 0, serviceRunning: false, connectedToFrps: false
  };
  @State private statusText: string = '读取状态中';
  @State private errorText: string = '';
  @State private busy: boolean = false;
  @State private statusReady: boolean = false;
  @State private hasSavedConfig: boolean = false;
  @State private savedConfigValid: boolean = false;
  @State private savedServer: string = '未保存配置';
  @State private savedConfigError: string = '';
  private timer: number = -1;
  private generation: number = 0;
  private statusRequestInFlight: boolean = false;

  aboutToAppear(): void {
    const generation: number = ++this.generation;
    this.refreshStatus(generation);
    this.timer = setInterval(() => this.refreshStatus(generation), 3000);
  }

  aboutToDisappear(): void {
    this.generation++;
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private async refreshStatus(generation: number): Promise<void> {
    if (this.statusRequestInFlight || this.busy) return;
    this.statusRequestInFlight = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.loadSavedConfig(context);
      const nextStatus: FrpRuntimeStatus = await FrpGateway.status(context);
      if (generation !== this.generation) return;
      this.status = nextStatus;
      this.statusReady = true;
      this.statusText = this.makeStatusText(nextStatus);
      this.errorText = this.joinErrors(this.savedConfigError, nextStatus.error);
    } catch (error) {
      if (generation === this.generation) {
        this.statusReady = true;
        this.statusText = '状态不可用';
        this.errorText = (error as Error).message;
      }
    } finally {
      this.statusRequestInFlight = false;
    }
  }

  private loadSavedConfig(context: common.UIAbilityContext): FrpConfig | undefined {
    try {
      const saved: string = FrpGateway.load(context.filesDir);
      if (saved.length === 0) {
        this.hasSavedConfig = false;
        this.savedConfigValid = false;
        this.savedServer = '未保存配置';
        this.savedConfigError = '';
        return undefined;
      }
      const config: FrpConfig = parseFrpToml(saved).config;
      this.hasSavedConfig = true;
      const validationErrors: string[] = validateFrpConfig(config);
      this.savedConfigValid = validationErrors.length === 0;
      this.savedServer = config.serverAddr.length > 0 ? config.serverAddr : '配置缺少服务器地址';
      this.savedConfigError = validationErrors.join('；');
      return config;
    } catch (error) {
      this.hasSavedConfig = false;
      this.savedConfigValid = false;
      this.savedServer = '已保存配置无法解析';
      this.savedConfigError = `已保存配置读取失败：${(error as Error).message}`;
      return undefined;
    }
  }

  private joinErrors(configError: string, statusError: string): string {
    if (configError.length === 0) return statusError;
    if (statusError.length === 0) return configError;
    return `${configError}；${statusError}`;
  }

  private makeStatusText(status: FrpRuntimeStatus): string {
    if (status.state === 'failed') return 'frpc 启动失败';
    if (status.state === 'stopping') return '正在停止 frpc';
    if (status.state === 'starting' && !status.serviceRunning) return 'frpc 正在启动';
    if (status.serviceRunning && status.connectedToFrps) return '已连接 frps，仍需外网验证';
    if (status.serviceRunning) return 'frpc 运行中，正在连接 frps';
    if (status.state === 'stopped') return 'frpc 已停止';
    return '等待 frpc 状态';
  }

  private isStoppable(): boolean {
    return this.status.state === 'starting' || this.status.state === 'running' ||
      this.status.state === 'stopping' || this.status.serviceRunning;
  }

  private startSavedConfig(): void {
    if (this.busy || this.isStoppable()) return;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const config: FrpConfig | undefined = this.loadSavedConfig(context);
    if (config === undefined || !this.savedConfigValid) {
      this.errorText = '请先在配置页保存有效的 FRP 配置';
      return;
    }
    const validationErrors: string[] = validateFrpConfig(config);
    if (validationErrors.length > 0) {
      this.errorText = validationErrors.join('；');
      return;
    }
    const mappings: string = config.proxies.map((proxy: FrpProxy) =>
      `${proxy.type.toUpperCase()} ${proxy.localIP}:${proxy.localPort} → 公网 ${proxy.remotePort}`).join('\n');
    this.getUIContext().showAlertDialog({
      title: '确认启动 FRP 客户端',
      message: `首页启动仅用已保存配置，未保存编辑不应用。启动将把本机服务映射到公网，请确认信任 frps 且服务器已许可这些端口：\n${mappings}`,
      primaryButton: { value: '确认启动', action: () => this.performStart() },
      secondaryButton: { value: '取消', action: () => {} }
    });
  }

  private async performStart(): Promise<void> {
    this.busy = true;
    const generation: number = this.generation;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const configText: string = FrpGateway.load(context.filesDir);
      const config: FrpConfig = parseFrpToml(configText).config;
      const validationErrors: string[] = validateFrpConfig(config);
      if (validationErrors.length > 0) throw new Error(validationErrors.join('；'));
      const nextStatus: FrpRuntimeStatus = await FrpGateway.start(context, config, configText);
      if (generation === this.generation) {
        this.status = nextStatus;
        this.statusReady = true;
        this.statusText = this.makeStatusText(nextStatus);
        this.errorText = this.joinErrors(this.savedConfigError, nextStatus.error);
      }
    } catch (error) {
      if (generation === this.generation) this.errorText = (error as Error).message;
    } finally {
      this.busy = false;
      if (generation === this.generation) this.refreshStatus(generation);
    }
  }

  private async stopFrp(): Promise<void> {
    if (this.busy || !this.isStoppable()) return;
    this.busy = true;
    const generation: number = this.generation;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const nextStatus: FrpRuntimeStatus = await FrpGateway.stop(context);
      if (generation === this.generation) {
        this.status = nextStatus;
        this.statusText = this.makeStatusText(nextStatus);
        this.errorText = nextStatus.error;
      }
    } catch (error) {
      if (generation === this.generation) this.errorText = (error as Error).message;
    } finally {
      this.busy = false;
      if (generation === this.generation) this.refreshStatus(generation);
    }
  }

  build() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 4 }) {
          Text('FRP 客户端').fontSize(22).fontWeight(FontWeight.Bold)
          Text('独立运行 · 不依赖 VPN 连接状态').fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('刷新').id('frp-runtime-refresh')
          .enabled(!this.busy).onClick(() => this.refreshStatus(this.generation))
      }
      .width('100%')

      Column({ space: 6 }) {
        Text('当前配置').fontSize(12).fontColor($r('sys.color.font_secondary'))
        Text(this.savedServer).id('frp-runtime-saved-server')
          .fontSize(18).fontWeight(FontWeight.Medium)
        Text(this.savedConfigValid ? '已保存有效配置 · 首页启动仅使用此文件' :
          '配置无效或未保存，请前往配置页修复并保存')
          .fontSize(12).fontColor($r('sys.color.font_secondary'))
      }
      .width('100%').alignItems(HorizontalAlign.Start)
      .padding(16).backgroundColor($r('sys.color.comp_background_primary')).borderRadius(18)

      Row({ space: 12 }) {
        Column({ space: 12 }) {
          Text('Worker').fontSize(12).fontColor($r('sys.color.font_secondary'))
          Text(this.status.serviceRunning ? '运行中' : '未运行').id('frp-runtime-worker-state')
            .fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(this.status.serviceRunning ? Color.Green : $r('sys.color.font_secondary'))
          Text(`${this.status.proxyCount} 条映射`).id('frp-runtime-proxy-count').fontSize(13)
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)
        .padding(16).backgroundColor($r('sys.color.comp_background_primary')).borderRadius(18)

        Column({ space: 12 }) {
          Text('frps 握手').fontSize(12).fontColor($r('sys.color.font_secondary'))
          Text(this.status.connectedToFrps && this.status.serviceRunning ? '已连接' : '未连接')
            .id('frp-runtime-frps-state').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(this.status.connectedToFrps && this.status.serviceRunning ?
              Color.Green : $r('sys.color.font_secondary'))
          Text('外网可达性仍需验证').fontSize(12).fontColor($r('sys.color.font_secondary'))
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)
        .padding(16).backgroundColor($r('sys.color.comp_background_primary')).borderRadius(18)
      }
      .width('100%')

      Column({ space: 10 }) {
        Text('运行状态').fontSize(12).fontColor($r('sys.color.font_secondary'))
        Text(this.statusText).id('frp-runtime-status').fontSize(18).fontWeight(FontWeight.Medium)
        Button(this.isStoppable() ? (this.status.state === 'stopping' ? '正在停止…' : '停止 frpc') : '启动已保存配置')
          .id('frp-runtime-start-stop')
          .enabled(!this.busy && this.statusReady && (this.isStoppable() || this.savedConfigValid))
          .width('100%')
          .onClick(() => this.isStoppable() ? this.stopFrp() : this.startSavedConfig())
      }
      .width('100%').alignItems(HorizontalAlign.Start)
      .padding(16).backgroundColor($r('sys.color.comp_background_primary')).borderRadius(18)

      Text('frpc 是客户端；公网端口须由 frps 服务器许可。连接成功不代表外网映射已验收。')
        .id('frp-runtime-safety-note').fontSize(12)
        .fontColor($r('sys.color.font_secondary')).width('100%')
      if (this.errorText.length > 0) {
        Text(this.errorText).id('frp-runtime-error').fontSize(12)
          .fontColor(Color.Red).width('100%')
      }
    }
    .width('100%').padding({ left: 16, right: 16, top: 16, bottom: 32 })
    .alignItems(HorizontalAlign.Start).id('frp-runtime-panel')
  }
}
