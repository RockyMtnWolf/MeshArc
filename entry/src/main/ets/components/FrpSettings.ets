import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { FrpConfig, FrpProxy, emptyFrpConfig, parseFrpToml, serializeFrpToml, validateFrpConfig } from '../services/FrpConfig';
import { FrpGateway, FrpRuntimeStatus } from '../services/FrpGateway';

const MAX_CONFIG_BYTES: number = 256 * 1024;

@Component
export struct FrpSettings {
  @Prop configurationOnly: boolean = false;
  @State private config: FrpConfig = emptyFrpConfig();
  @State private tomlText: string = '';
  @State private textMode: boolean = false;
  @State private busy: boolean = false;
  @State private statusText: string = '未连接';
  @State private statusError: string = '';
  @State private running: boolean = false;
  @State private nativeState: string = 'stopped';
  @State private statusReady: boolean = false;
  @State private unknownTextFields: boolean = false;
  @State private proxyIds: string[] = [];
  private timer: number = -1;
  private generation: number = 0;
  private statusRequestInFlight: boolean = false;
  private nextProxyId: number = 1;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const saved: string = FrpGateway.load(context.filesDir);
      if (saved.length > 0) {
        const parsed = parseFrpToml(saved);
        this.config = parsed.config;
        this.resetProxyIds();
        this.tomlText = saved;
        if (parsed.hasUnknownFields) {
          this.textMode = true;
          this.unknownTextFields = true;
          this.statusError = `配置含表单无法保留的高级字段：${parsed.warnings.join('；')}。请留在文本模式。`;
        }
      } else {
        this.tomlText = serializeFrpToml(this.config);
      }
    } catch (error) {
      this.statusError = `保存的配置无法读取：${(error as Error).message}`;
    }
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
    if (this.statusRequestInFlight) return;
    this.statusRequestInFlight = true;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const state: FrpRuntimeStatus = await FrpGateway.status(context);
      if (generation !== this.generation) return;
      this.nativeState = state.state;
      this.statusReady = true;
      this.running = state.serviceRunning;
      this.statusText = this.stateLabel(state);
      this.statusError = state.error;
    } catch (error) {
      if (generation === this.generation) {
        this.nativeState = 'unknown';
        this.statusReady = true;
        this.running = false;
        this.statusText = '状态不可用';
        this.statusError = (error as Error).message;
      }
    } finally {
      this.statusRequestInFlight = false;
    }
  }

  private stateLabel(state: FrpRuntimeStatus): string {
    if (state.serviceRunning && state.connectedToFrps) return '已连接frps，仍需外网验证';
    if (state.serviceRunning) return 'frpc运行，正在连接frps';
    if (state.state === 'starting') return 'frpc 正在启动…';
    if (state.state === 'stopping') return '正在停止 frpc…';
    if (state.state === 'failed') return 'frpc 启动失败';
    if (state.state === 'stopped') return '已停止';
    return state.state;
  }

  private canStop(): boolean {
    return this.nativeState !== 'stopped' && this.nativeState !== 'failed';
  }

  private updateConfig(config: FrpConfig): void {
    const proxies: FrpProxy[] = [];
    for (const proxy of config.proxies) {
      proxies.push({ name: proxy.name, type: proxy.type, localIP: proxy.localIP,
        localPort: proxy.localPort, remotePort: proxy.remotePort });
    }
    this.config = { serverAddr: config.serverAddr, serverPort: config.serverPort,
      token: config.token, proxies: proxies };
    this.tomlText = serializeFrpToml(this.config);
  }

  private resetProxyIds(): void {
    const ids: string[] = [];
    for (let index: number = 0; index < this.config.proxies.length; index++) {
      ids.push(`frp-proxy-${this.nextProxyId++}`);
    }
    this.proxyIds = ids;
  }

  private updateServerAddress(value: string): void {
    this.updateConfig({ serverAddr: value, serverPort: this.config.serverPort,
      token: this.config.token, proxies: this.config.proxies });
  }

  private updateServerPort(value: string): void {
    this.updateConfig({ serverAddr: this.config.serverAddr, serverPort: Number(value),
      token: this.config.token, proxies: this.config.proxies });
  }

  private updateToken(value: string): void {
    this.updateConfig({ serverAddr: this.config.serverAddr, serverPort: this.config.serverPort,
      token: value, proxies: this.config.proxies });
  }

  private addProxy(): void {
    const proxies: FrpProxy[] = this.config.proxies.slice();
    const number: number = proxies.length + 1;
    proxies.push({ name: `proxy-${number}`, type: 'tcp', localIP: '127.0.0.1', localPort: 0, remotePort: 0 });
    this.updateConfig({ serverAddr: this.config.serverAddr, serverPort: this.config.serverPort,
      token: this.config.token, proxies: proxies });
    const ids: string[] = this.proxyIds.slice();
    ids.push(`frp-proxy-${this.nextProxyId++}`);
    this.proxyIds = ids;
  }

  private removeProxy(index: number): void {
    const proxies: FrpProxy[] = [];
    for (let proxyIndex: number = 0; proxyIndex < this.config.proxies.length; proxyIndex++) {
      if (proxyIndex !== index) proxies.push(this.config.proxies[proxyIndex]);
    }
    const ids: string[] = [];
    for (let proxyIndex: number = 0; proxyIndex < this.proxyIds.length; proxyIndex++) {
      if (proxyIndex !== index) ids.push(this.proxyIds[proxyIndex]);
    }
    this.proxyIds = ids;
    this.updateConfig({ serverAddr: this.config.serverAddr, serverPort: this.config.serverPort,
      token: this.config.token, proxies: proxies });
  }

  private confirm(title: string, message: string, action: () => void): void {
    this.getUIContext().showAlertDialog({
      title: title,
      message: message,
      primaryButton: { value: '继续', action: action },
      secondaryButton: { value: '取消', action: () => {} }
    });
  }

  private saveConfig(): void {
    try {
      if (this.textMode) {
        const parsed = parseFrpToml(this.tomlText);
        this.config = parsed.config;
        this.unknownTextFields = parsed.hasUnknownFields;
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.tomlText = this.textMode ? this.tomlText : serializeFrpToml(this.config);
      FrpGateway.save(context.filesDir, this.tomlText);
      this.statusError = this.unknownTextFields ? '高级字段已原样保留；表单模式无法无损编辑此配置。' : '';
      this.statusText = '配置已保存到应用私有目录';
    } catch (error) {
      this.statusError = (error as Error).message;
    }
  }

  private switchToForm(): void {
    try {
      const parsed = parseFrpToml(this.tomlText);
      if (parsed.hasUnknownFields) {
        this.unknownTextFields = true;
        this.statusError = `无法无损转换：${parsed.warnings.join('；')}。请留在文本模式。`;
        return;
      }
      this.config = parsed.config;
      this.resetProxyIds();
      this.textMode = false;
      this.unknownTextFields = false;
      this.statusError = '';
    } catch (error) {
      this.statusError = (error as Error).message;
    }
  }

  private switchToText(): void {
    this.confirm('切换为 TOML 文本', '表单字段将重新序列化为 TOML。确认继续？', () => {
      this.tomlText = serializeFrpToml(this.config);
      this.textMode = true;
      this.unknownTextFields = false;
      this.statusError = '';
    });
  }

  private async importConfig(): Promise<void> {
    let file: fileIo.File | undefined = undefined;
    try {
      const documentPicker = new picker.DocumentViewPicker(this.getUIContext().getHostContext() as common.UIAbilityContext);
      const uris: string[] = await documentPicker.select(new picker.DocumentSelectOptions());
      if (uris.length === 0) return;
      file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(uris[0]);
      if (!stat.isFile() || stat.size < 0 || stat.size > MAX_CONFIG_BYTES) {
        throw new Error('配置文件必须是普通文件且不超过 256 KiB');
      }
      const contents: string = fileIo.readTextSync(uris[0], { length: stat.size });
      const parsed = parseFrpToml(contents);
      this.tomlText = contents;
      this.config = parsed.config;
      this.resetProxyIds();
      this.textMode = true;
      this.unknownTextFields = parsed.hasUnknownFields;
      this.statusError = parsed.hasUnknownFields ?
        `已导入；发现高级字段，禁止切换表单或覆盖文本：${parsed.warnings.join('；')}` : '';
      this.statusText = '已导入到编辑器；不会自动启动，保存后才写入应用配置';
    } catch (error) {
      this.statusError = (error as Error).message;
    } finally {
      if (file !== undefined) {
        try { fileIo.closeSync(file); } catch (_error) {}
      }
    }
  }

  private async startFrp(): Promise<void> {
    if (this.busy || !this.statusReady ||
      (this.nativeState !== 'stopped' && this.nativeState !== 'failed')) return;
    if (this.textMode) {
      try {
        const parsed = parseFrpToml(this.tomlText);
        this.config = parsed.config;
      } catch (error) {
        this.statusError = (error as Error).message;
        return;
      }
    }
    const errors: string[] = validateFrpConfig(this.config);
    if (errors.length > 0) {
      this.statusError = errors.join('；');
      return;
    }
    const mappings: string = this.config.proxies.map((proxy: FrpProxy) =>
      `${proxy.type.toUpperCase()} ${proxy.localIP}:${proxy.localPort} → 公网 ${proxy.remotePort}`).join('\n');
    this.confirm('确认启动 frpc 客户端？',
      `frpc 是客户端；公网端口须由 frps 服务器许可。启动后将把本机服务映射到公网，请确认信任服务器并核对映射：\n${mappings}`,
      () => this.performStart());
  }

  private async performStart(): Promise<void> {
    this.busy = true;
    const generation: number = this.generation;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const configText: string = this.textMode ? this.tomlText : serializeFrpToml(this.config);
      const state: FrpRuntimeStatus = await FrpGateway.start(context, this.config, configText);
      if (generation === this.generation) {
        this.nativeState = state.state;
        this.running = state.serviceRunning;
        this.statusText = this.stateLabel(state);
        this.statusError = state.error;
      }
    } catch (error) {
      if (generation === this.generation) this.statusError = (error as Error).message;
    } finally {
      this.busy = false;
    }
  }

  private async stopFrp(): Promise<void> {
    if (this.busy || !this.statusReady || this.nativeState === 'stopped' || this.nativeState === 'failed') return;
    this.busy = true;
    const generation: number = this.generation;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const state: FrpRuntimeStatus = await FrpGateway.stop(context);
      if (generation === this.generation) {
        this.nativeState = state.state;
        this.running = state.serviceRunning;
        this.statusText = this.stateLabel(state);
        this.statusError = state.error;
      }
    } catch (error) {
      if (generation === this.generation) this.statusError = (error as Error).message;
    } finally {
      this.busy = false;
    }
  }

  private updateProxy(index: number, key: string, value: string): void {
    const proxies: FrpProxy[] = this.config.proxies.slice();
    const current: FrpProxy = proxies[index];
    const proxy: FrpProxy = { name: current.name, type: current.type, localIP: current.localIP,
      localPort: current.localPort, remotePort: current.remotePort };
    if (key === 'name') proxy.name = value;
    else if (key === 'localIP') proxy.localIP = value;
    else if (key === 'localPort') proxy.localPort = Number(value);
    else if (key === 'remotePort') proxy.remotePort = Number(value);
    proxies[index] = proxy;
    this.updateConfig({ serverAddr: this.config.serverAddr, serverPort: this.config.serverPort,
      token: this.config.token, proxies: proxies });
  }

  @Builder
  private TextField(label: string, value: string, fieldId: string, onChange: (value: string) => void,
    halfWidth: boolean = false, secret: boolean = false) {
    Column({ space: 5 }) {
      Text(label).fontSize(12).fontColor($r('sys.color.font_secondary'))
      TextInput({ text: value, placeholder: label })
        .id(fieldId)
        .type(secret ? InputType.Password : InputType.Normal)
        .onChange(onChange)
        .width('100%')
        .padding(10)
        .backgroundColor($r('sys.color.comp_background_primary'))
        .borderRadius(10)
    }
    .width(halfWidth ? '47%' : '100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private ProxyCard(proxy: FrpProxy, index: number) {
    Column({ space: 10 }) {
      Row() {
        Text(`代理 ${index + 1}`).fontSize(14).fontWeight(FontWeight.Medium).layoutWeight(1)
        Select([{ value: 'TCP' }, { value: 'UDP' }]).id(`frp-proxy-${index}-type`)
          .selected(proxy.type === 'tcp' ? 0 : 1)
          .value(proxy.type.toUpperCase())
          .onSelect((choice: number) => {
            const proxies: FrpProxy[] = this.config.proxies.slice();
            proxies[index] = { name: proxy.name, type: choice === 0 ? 'tcp' : 'udp',
              localIP: proxy.localIP, localPort: proxy.localPort, remotePort: proxy.remotePort };
            this.updateConfig({ serverAddr: this.config.serverAddr, serverPort: this.config.serverPort,
              token: this.config.token, proxies: proxies });
          })
        Button('移除').id(`frp-proxy-${index}-remove`).onClick(() => this.removeProxy(index))
      }
      this.TextField('代理名称', proxy.name, `frp-proxy-${index}-name-input`,
        (value: string) => this.updateProxy(index, 'name', value))
      this.TextField('本机 IP（默认仅本机）', proxy.localIP, `frp-proxy-${index}-local-ip-input`,
        (value: string) => this.updateProxy(index, 'localIP', value))
      Row({ space: 8 }) {
        this.TextField('本机端口', `${proxy.localPort || ''}`, `frp-proxy-${index}-local-port-input`,
          (value: string) => this.updateProxy(index, 'localPort', value), true)
        this.TextField('公网 remotePort', `${proxy.remotePort || ''}`, `frp-proxy-${index}-remote-port-input`,
          (value: string) => this.updateProxy(index, 'remotePort', value), true)
      }
    }
    .width('100%')
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(14)
  }

  build() {
    Column({ space: 12 }) {
      if (!this.configurationOnly) {
        Row() {
          Column({ space: 3 }) {
            Text('FRP 客户端').fontSize(19).fontWeight(FontWeight.Bold)
            Text(this.statusText).id('frp-status').fontSize(12)
              .fontColor(this.running ? Color.Green : $r('sys.color.font_secondary'))
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button(this.canStop() ? '停止' : '启动').id('frp-start-stop-button')
            .enabled(!this.busy && this.statusReady)
            .onClick(() => this.canStop() ? this.stopFrp() : this.startFrp())
        }
      }
      Text('frpc 是客户端：连接由本机发起，frps 负责对外提供端口。远端端口需要服务器管理员预先许可。')
        .fontSize(12).fontColor($r('sys.color.font_secondary'))
      Text('安全提示：本机地址默认 127.0.0.1；避免绑定 0.0.0.0。公网映射会暴露本机服务，请只连接可信 frps。Token 以密码控件显示。')
        .fontSize(12).fontColor($r('sys.color.font_secondary'))
        .padding(10).backgroundColor($r('sys.color.comp_background_primary')).borderRadius(10)
      Row({ space: 8 }) {
        Button(this.textMode ? '表格' : 'TOML 文本').id('frp-mode-toggle')
          .onClick(() => this.textMode ? this.switchToForm() : this.switchToText())
        Button('导入文件').id('frp-import-config').onClick(() => this.importConfig())
        Button('保存配置').id('frp-save-config').onClick(() => this.saveConfig())
      }.width('100%').justifyContent(FlexAlign.SpaceBetween)
      if (this.textMode) {
        TextArea({ text: this.tomlText, placeholder: '粘贴 frpc TOML 配置' })
          .id('frp-toml-editor')
          .onChange((value: string) => { this.tomlText = value; })
          .width('100%').height(360).textAlign(TextAlign.Start)
          .backgroundColor($r('sys.color.comp_background_primary')).borderRadius(12).padding(12)
      } else {
        this.TextField('frps 地址 serverAddr', this.config.serverAddr, 'frp-server-addr-input',
          (value: string) => this.updateServerAddress(value))
        this.TextField('frps 端口 serverPort', `${this.config.serverPort}`, 'frp-server-port-input',
          (value: string) => this.updateServerPort(value))
        this.TextField('Token', this.config.token, 'frp-token-input',
          (value: string) => this.updateToken(value), false, true)
        ForEach(this.config.proxies, (proxy: FrpProxy, index: number) => {
          this.ProxyCard(proxy, index)
        }, (_proxy: FrpProxy, index: number) => this.proxyIds[index])
        Button('添加 TCP/UDP 映射').id('frp-add-proxy').width('100%').onClick(() => this.addProxy())
      }
      if (this.statusError.length > 0) {
        Text(this.statusError).fontSize(12).fontColor(Color.Red).width('100%').id('frp-error')
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 28 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(18)
    .id('frp-settings')
  }
}
