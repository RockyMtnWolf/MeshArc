import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FrpConfig, FrpProxy, emptyFrpConfig, parseFrpToml, serializeFrpToml, validateFrpConfig } from '../services/FrpConfig';
import { FrpProfile, FrpProfileStore } from '../services/FrpProfileStore';
import { ConfigDocumentGateway } from '../services/ConfigDocumentGateway';
import { FrpProfilesGateway, FrpProfileRuntimeStatus } from '../services/FrpProfilesGateway';

const FRP_UI_LOG_DOMAIN: number = 0x0000;
const FRP_UI_LOG_TAG: string = 'FRPProfiles';

@Component
export struct FrpProfilesPage {
  private scroller: Scroller = new Scroller();
  @Prop bottomInset: number = 112;
  @Prop cardMaxWidth: number = 760;
  onEditorVisibilityChange: (visible: boolean) => void = (_visible: boolean) => {};
  @State private profiles: FrpProfile[] = [];
  @State private runtimes: FrpProfileRuntimeStatus[] = [];
  @State private loading: boolean = true;
  @State private refreshBusy: boolean = false;
  @State private busyIds: string[] = [];
  @State private message: string = '';
  @State @Watch('onModalOpenChanged') private modalOpen: boolean = false;
  @State private textMode: boolean = true;
  @State private importedName: string = '';
  @State private editId: string = '';
  @State private profileName: string = '';
  @State private tomlText: string = '';
  @State private advancedWarning: string = '';
  @State private serverAddr: string = '';
  @State private serverPort: string = '7000';
  @State private user: string = '';
  @State private token: string = '';
  @State private tlsEnable: boolean = false;
  @State private tlsDisableCustomTLSFirstByte: boolean = false;
  @State private proxies: FrpProxy[] = [];
  private timer: number = -1;
  private generation: number = 0;

  aboutToAppear(): void {
    this.generation++;
    this.loadProfiles();
    this.refreshStatuses();
    this.timer = setInterval(() => this.refreshStatuses(), 3000);
  }

  aboutToDisappear(): void {
    this.generation++;
    this.onEditorVisibilityChange(false);
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private onModalOpenChanged(): void {
    this.onEditorVisibilityChange(this.modalOpen);
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private loadProfiles(): void {
    try {
      this.profiles = FrpProfileStore.load(this.context());
      this.message = '';
    } catch (error) {
      this.message = `读取配置失败：${(error as Error).message}`;
    } finally {
      this.loading = false;
    }
  }

  private async refreshStatuses(): Promise<void> {
    if (this.refreshBusy) return;
    this.refreshBusy = true;
    const generation: number = this.generation;
    try {
      const status: FrpProfileRuntimeStatus[] = await FrpProfilesGateway.statuses(this.context());
      if (generation === this.generation) this.runtimes = status;
    } catch (error) {
      if (generation === this.generation) this.message = `读取运行状态失败：${(error as Error).message}`;
    } finally {
      this.refreshBusy = false;
    }
  }

  private runtimeFor(id: string): FrpProfileRuntimeStatus | undefined {
    for (const item of this.runtimes) if (item.profileId === id) return item;
    return undefined;
  }

  private isRunning(item: FrpProfileRuntimeStatus | undefined): boolean {
    return item !== undefined && (item.serviceRunning || item.state === 'starting' ||
      item.state === 'running' || item.state === 'stopping');
  }

  private statusLabel(item: FrpProfileRuntimeStatus | undefined): string {
    if (item === undefined) return '已停止';
    if (item.state === 'failed') return '启动失败';
    if (item.state === 'stopping') return '正在停止';
    if (item.state === 'starting' && !item.serviceRunning) return '正在启动';
    if (item.serviceRunning && item.connectedToFrps) return '已连接 frps';
    if (item.serviceRunning) return 'frpc 运行中，正在连接 frps';
    return item.state === 'stopped' ? '已停止' : item.state;
  }

  private runtimeError(profileId: string): string {
    const item: FrpProfileRuntimeStatus | undefined = this.runtimeFor(profileId);
    return item === undefined ? '' : item.error;
  }

  private parseProfile(profile: FrpProfile): FrpConfig | undefined {
    try { return parseFrpToml(profile.toml).config; } catch (_error) { return undefined; }
  }

  private proxyCount(profile: FrpProfile): number {
    const config: FrpConfig | undefined = this.parseProfile(profile);
    return config === undefined ? 0 : config.proxies.length;
  }

  private serverName(profile: FrpProfile): string {
    const config: FrpConfig | undefined = this.parseProfile(profile);
    return config === undefined || config.serverAddr.length === 0 ? '服务器地址无效' :
      `${config.serverAddr}:${config.serverPort}`;
  }

  private setBusy(id: string, busy: boolean): void {
    const next: string[] = [];
    for (const value of this.busyIds) if (value !== id) next.push(value);
    if (busy) next.push(id);
    this.busyIds = next;
  }

  private isBusy(id: string): boolean {
    return this.busyIds.indexOf(id) >= 0;
  }

  private async toggleProfile(profile: FrpProfile, shouldRun: boolean): Promise<void> {
    const current: FrpProfileRuntimeStatus | undefined = this.runtimeFor(profile.id);
    const running: boolean = this.isRunning(current);
    hilog.info(FRP_UI_LOG_DOMAIN, FRP_UI_LOG_TAG,
      'toggle event profileId=%{private}s requested=%{public}d running=%{public}d',
      profile.id, shouldRun ? 1 : 0, running ? 1 : 0);
    if (shouldRun === running) {
      hilog.info(FRP_UI_LOG_DOMAIN, FRP_UI_LOG_TAG,
        'toggle ignored because requested state already matches profileId=%{private}s', profile.id);
      return;
    }
    if (this.isBusy(profile.id)) {
      hilog.info(FRP_UI_LOG_DOMAIN, FRP_UI_LOG_TAG,
        'toggle ignored while operation is busy profileId=%{private}s', profile.id);
      return;
    }
    this.setBusy(profile.id, true);
    this.message = '';
    const generation: number = this.generation;
    try {
      let next: FrpProfileRuntimeStatus;
      if (shouldRun) {
        const parsed = parseFrpToml(profile.toml);
        const errors: string[] = validateFrpConfig(parsed.config);
        if (errors.length > 0) throw new Error(errors.join('；'));
        hilog.info(FRP_UI_LOG_DOMAIN, FRP_UI_LOG_TAG,
          'start requested profileId=%{private}s', profile.id);
        next = await FrpProfilesGateway.start(this.context(), profile);
      } else {
        hilog.info(FRP_UI_LOG_DOMAIN, FRP_UI_LOG_TAG,
          'stop requested profileId=%{private}s', profile.id);
        next = await FrpProfilesGateway.stop(this.context(), profile.id);
      }
      if (generation === this.generation) this.upsertStatus(next);
      hilog.info(FRP_UI_LOG_DOMAIN, FRP_UI_LOG_TAG,
        'operation completed profileId=%{private}s state=%{public}s worker=%{public}d connected=%{public}d',
        profile.id, next.state, next.serviceRunning ? 1 : 0, next.connectedToFrps ? 1 : 0);
      if (next.error.length > 0) this.message = next.error;
    } catch (error) {
      hilog.error(FRP_UI_LOG_DOMAIN, FRP_UI_LOG_TAG,
        'operation failed profileId=%{private}s', profile.id);
      if (generation === this.generation) this.message = `${profile.name}：${(error as Error).message}`;
    } finally {
      this.setBusy(profile.id, false);
      if (generation === this.generation) this.refreshStatuses();
    }
  }

  private upsertStatus(status: FrpProfileRuntimeStatus): void {
    const next: FrpProfileRuntimeStatus[] = [];
    let found: boolean = false;
    for (const item of this.runtimes) {
      if (item.profileId === status.profileId) { next.push(status); found = true; }
      else next.push(item);
    }
    if (!found) next.push(status);
    this.runtimes = next;
  }

  private deleteProfile(profile: FrpProfile): void {
    if (this.isRunning(this.runtimeFor(profile.id)) || this.isBusy(profile.id)) return;
    this.getUIContext().showAlertDialog({
      title: '删除配置', message: `确定删除「${profile.name}」？`,
      primaryButton: { value: '删除', action: () => {
        const next: FrpProfile[] = [];
        for (const item of this.profiles) if (item.id !== profile.id) next.push(item);
        try { FrpProfileStore.save(this.context(), next); this.profiles = next; }
        catch (error) { this.message = `删除失败：${(error as Error).message}`; }
      } }, secondaryButton: { value: '取消', action: () => {} }
    });
  }

  private newProfile(): void {
    this.editId = '';
    this.profileName = '';
    this.tomlText = '';
    this.importedName = '';
    this.advancedWarning = '';
    this.textMode = true;
    this.resetForm();
    this.modalOpen = true;
  }

  private editProfile(profile: FrpProfile): void {
    this.editId = profile.id;
    this.profileName = profile.name;
    this.tomlText = profile.toml;
    this.importedName = '';
    this.advancedWarning = '';
    this.textMode = true;
    this.resetForm();
    this.modalOpen = true;
  }

  private resetForm(): void {
    const config: FrpConfig = emptyFrpConfig();
    config.tlsEnable = true;
    config.proxies.push({ name: '', type: 'tcp', localIP: '127.0.0.1', localPort: 0, remotePort: 0 });
    this.serverAddr = config.serverAddr;
    this.serverPort = `${config.serverPort}`;
    this.user = '';
    this.token = '';
    this.tlsEnable = true;
    this.tlsDisableCustomTLSFirstByte = false;
    this.proxies = config.proxies;
    if (this.tomlText.length > 0) {
      try {
        const parsed = parseFrpToml(this.tomlText);
        if (!parsed.hasUnknownFields) this.loadForm(parsed.config);
        else this.advancedWarning = '包含表单不支持的高级字段；请保持文本模式编辑，避免有损转换。';
      } catch (_error) { this.advancedWarning = '配置无法解析为表单，请使用文本模式修复。'; }
    }
  }

  private loadForm(config: FrpConfig): void {
    this.serverAddr = config.serverAddr;
    this.serverPort = `${config.serverPort}`;
    this.user = config.user === undefined ? '' : config.user;
    this.token = config.token;
    this.tlsEnable = config.tlsEnable !== false;
    this.tlsDisableCustomTLSFirstByte = config.tlsDisableCustomTLSFirstByte === true;
    const copied: FrpProxy[] = [];
    for (const proxy of config.proxies) copied.push({ name: proxy.name, type: proxy.type,
      localIP: proxy.localIP, localPort: proxy.localPort, remotePort: proxy.remotePort });
    while (copied.length < 1) copied.push({ name: '', type: 'tcp', localIP: '127.0.0.1', localPort: 0, remotePort: 0 });
    this.proxies = copied;
  }

  private async importText(): Promise<void> {
    try {
      const document = await ConfigDocumentGateway.pickText(this.context(), 256 * 1024);
      if (document === undefined) return;
      this.tomlText = document.text;
      if (this.profileName.length === 0) this.profileName = document.name.replace(/\.[^.]+$/, '');
      try {
        const parsed = parseFrpToml(document.text);
        this.advancedWarning = parsed.hasUnknownFields ?
          '检测到高级字段，仅可在文本模式中无损保存；切换表单前必须确认。' : '';
      } catch (error) { this.advancedWarning = `配置解析提示：${(error as Error).message}`; }
    } catch (error) { this.message = `导入失败：${(error as Error).message}`; }
  }

  private toConfig(): FrpConfig {
    const config: FrpConfig = { serverAddr: this.serverAddr, serverPort: Number(this.serverPort),
      token: this.token, proxies: [], user: this.user, tlsEnable: this.tlsEnable,
      tlsDisableCustomTLSFirstByte: this.tlsDisableCustomTLSFirstByte };
    for (const proxy of this.proxies) config.proxies.push({ name: proxy.name, type: proxy.type,
      localIP: proxy.localIP, localPort: proxy.localPort, remotePort: proxy.remotePort });
    return config;
  }

  private syncFormText(): void {
    this.tomlText = serializeFrpToml(this.toConfig());
  }

  private switchMode(toText: boolean): void {
    if (toText === this.textMode) return;
    if (toText) {
      this.getUIContext().showAlertDialog({ title: '生成文本配置',
        message: '表单将转换为 TOML 文本。保存文本后将以该文本为准。',
        primaryButton: { value: '转换', action: () => { this.syncFormText(); this.textMode = true; } },
        secondaryButton: { value: '取消', action: () => {} } });
      return;
    }
    if (this.tomlText.trim().length === 0) {
      this.textMode = false;
      this.advancedWarning = '';
      return;
    }
    try {
      const parsed = parseFrpToml(this.tomlText);
      if (parsed.hasUnknownFields) {
        this.advancedWarning = '含有表单无法保留的高级字段，禁止转换；请继续使用 TOML 文本模式。';
        return;
      }
      this.loadForm(parsed.config);
      this.textMode = false;
      this.advancedWarning = '';
    } catch (error) { this.advancedWarning = `无法转换为表单：${(error as Error).message}`; }
  }

  private updateProxy(index: number, key: string, value: string): void {
    const next: FrpProxy[] = [];
    for (const item of this.proxies) next.push({ name: item.name, type: item.type,
      localIP: item.localIP, localPort: item.localPort, remotePort: item.remotePort });
    const item: FrpProxy = next[index];
    if (key === 'name') item.name = value;
    else if (key === 'type') item.type = value === 'udp' ? 'udp' : 'tcp';
    else if (key === 'localIP') item.localIP = value;
    else if (key === 'localPort') item.localPort = value.length === 0 ? 0 : Number(value);
    else if (key === 'remotePort') item.remotePort = value.length === 0 ? 0 : Number(value);
    this.proxies = next;
  }

  private addProxy(): void {
    const next: FrpProxy[] = [];
    for (const proxy of this.proxies) next.push(proxy);
    next.push({ name: '', type: 'tcp', localIP: '127.0.0.1', localPort: 0, remotePort: 0 });
    this.proxies = next;
  }

  private removeProxy(index: number): void {
    if (this.proxies.length <= 1) return;
    const next: FrpProxy[] = [];
    for (let i: number = 0; i < this.proxies.length; i++) if (i !== index) next.push(this.proxies[i]);
    this.proxies = next;
  }

  private saveProfile(): void {
    const name: string = this.profileName.trim();
    if (name.length === 0) { this.message = '请填写配置名称'; return; }
    let toml: string = this.tomlText;
    try {
      if (!this.textMode) toml = serializeFrpToml(this.toConfig());
      const parsed = parseFrpToml(toml);
      const errors: string[] = validateFrpConfig(parsed.config);
      if (errors.length > 0) throw new Error(errors.join('；'));
      const id: string = this.editId.length > 0 ? this.editId : `frp-${Date.now().toString(36)}-${Math.floor(Math.random() * 100000).toString(36)}`;
      const updated: FrpProfile = { id: id, name: name, toml: toml, updatedAt: Date.now() };
      const next: FrpProfile[] = [];
      let found: boolean = false;
      for (const profile of this.profiles) {
        if (profile.id === id) { next.push(updated); found = true; } else next.push(profile);
      }
      if (!found) next.push(updated);
      FrpProfileStore.save(this.context(), next);
      this.profiles = next;
      this.modalOpen = false;
      this.message = '配置已保存；保存不会启动或修改正在运行的 worker。';
    } catch (error) { this.message = `保存失败：${(error as Error).message}`; }
  }

  @Builder
  private field(label: string, value: string, id: string, onChange: (value: string) => void,
    password: boolean = false, weight: number = 1): void {
    Column({ space: 5 }) {
      Text(label).fontSize(12).fontColor($r('sys.color.font_secondary'))
      TextInput({ text: value, placeholder: label }).id(id).width('100%')
        .type(password ? InputType.Password : InputType.Normal).onChange(onChange)
    }.alignItems(HorizontalAlign.Start).layoutWeight(weight)
  }

  build() {
    Stack() {
      Scroll(this.scroller) {
        Column() {
          Column({ space: 16 }) {
          Row() {
            Column({ space: 4 }) {
              Text('FRP 配置').fontSize(24).fontWeight(FontWeight.Bold)
              Text('frpc 客户端 · 每份配置可独立运行；最多保存 32 份配置（不是 32 条隧道）')
                .fontSize(13).fontColor($r('sys.color.font_secondary'))
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button('刷新').id('frp-profiles-refresh').enabled(!this.refreshBusy)
              .onClick(() => this.refreshStatuses())
          }.width('100%')
          Button('+ 添加配置').id('frp-add-profile').width('100%').onClick(() => this.newProfile())
          Text('公网端口须由 frps 管理员许可。单份配置可含多条映射，服务商实际隧道数量以套餐为准。')
            .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
          if (this.message.length > 0) Text(this.message).id('frp-profiles-message').fontSize(13)
            .fontColor($r('app.color.status_error')).width('100%')
          if (this.loading) Text('读取配置中…').width('100%')
          ForEach(this.profiles, (profile: FrpProfile) => {
            this.profileCard(profile)
          }, (profile: FrpProfile) => profile.id)
          if (!this.loading && this.profiles.length === 0) {
            Text('还没有配置。添加或导入 TOML 后保存，再从对应卡片启动。')
              .fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%').padding(20)
          }
          }.width('100%').constraintSize({ maxWidth: this.cardMaxWidth })
            .padding({ left: 18, right: 18, top: 18, bottom: this.bottomInset })
        }.width('100%').alignItems(HorizontalAlign.Center)
      }.width('100%').height('100%')
      if (this.modalOpen) this.editorModal()
    }.width('100%').height('100%')
  }

  @Builder
  private profileCard(profile: FrpProfile) {
    Column({ space: 12 }) {
      Row({ space: 10 }) {
        Column({ space: 5 }) {
          Text(profile.name).id(`frp-profile-name-${profile.id}`).fontSize(18).fontWeight(FontWeight.Bold)
          Text(this.serverName(profile)).fontSize(13).fontColor($r('sys.color.font_secondary'))
          Text(`${this.proxyCount(profile)} 条端口映射`).fontSize(12).fontColor($r('sys.color.font_secondary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Button('编辑').id(`frp-profile-edit-${profile.id}`).onClick(() => this.editProfile(profile))
      }.width('100%')
      Row({ space: 10 }) {
        Text(this.statusLabel(this.runtimeFor(profile.id))).id(`frp-profile-status-${profile.id}`)
          .fontSize(13).layoutWeight(1).fontColor(this.isRunning(this.runtimeFor(profile.id)) ?
            $r('app.color.status_success') :
            $r('sys.color.font_secondary'))
        Toggle({ type: ToggleType.Switch, isOn: this.isRunning(this.runtimeFor(profile.id)) })
          .id(`frp-profile-toggle-${profile.id}`).enabled(!this.isBusy(profile.id))
          .onChange((enabled: boolean) => this.toggleProfile(profile, enabled))
      }.width('100%')
      if (this.runtimeError(profile.id).length > 0) {
        Text(this.runtimeError(profile.id)).id(`frp-profile-error-${profile.id}`)
          .fontSize(12).fontColor($r('app.color.status_error')).width('100%')
      }
      Row() {
        Text('本机服务仅按已保存配置映射；编辑不会更改当前 worker。')
          .fontSize(11).fontColor($r('sys.color.font_secondary')).layoutWeight(1)
        Button('删除').id(`frp-profile-delete-${profile.id}`)
          .enabled(!this.isRunning(this.runtimeFor(profile.id)) && !this.isBusy(profile.id))
          .onClick(() => this.deleteProfile(profile))
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(16)
      .backgroundColor($r('sys.color.comp_background_primary')).borderRadius(18)
  }

  @Builder
  private editorModal() {
    Stack() {
      Column().width('100%').height('100%').backgroundColor(Color.Transparent).onClick(() => {})
      Column() {
        Row() {
          Text(this.editId.length > 0 ? '编辑 FRP 配置' : '添加 FRP 配置')
            .fontSize(20).fontWeight(FontWeight.Bold).layoutWeight(1)
          Button('关闭').id('frp-profile-modal-close').onClick(() => this.modalOpen = false)
        }.width('100%').padding({ left: 18, right: 18, top: 14, bottom: 10 })
        Scroll() {
          Column({ space: 14 }) {
            Column({ space: 6 }) {
              Text('配置名称').fontSize(12).fontColor($r('sys.color.font_secondary'))
              TextInput({ text: this.profileName, placeholder: '例如 USBIP 测试' })
                .id('frp-profile-name-input').width('100%').onChange((value: string) => this.profileName = value)
            }.width('100%').alignItems(HorizontalAlign.Start)
            Row({ space: 8 }) {
              Button(this.textMode ? '切换表单' : '切换TOML').id('frp-profile-mode-toggle')
                .onClick(() => this.switchMode(!this.textMode))
              Button('导入文件').id('frp-profile-import').onClick(() => this.importText())
            }.width('100%')
            if (this.advancedWarning.length > 0) Text(this.advancedWarning).id('frp-profile-advanced-warning')
              .fontSize(12).fontColor($r('app.color.status_warning')).width('100%')
            if (this.textMode) {
              Text('保存只保存文本配置，不会启动 frpc。').fontSize(12)
                .fontColor($r('sys.color.font_secondary')).width('100%')
              TextArea({ text: this.tomlText, placeholder: '粘贴或编辑 frpc TOML' })
                .id('frp-profile-toml-input').width('100%').height(380)
                .onChange((value: string) => this.tomlText = value)
            } else {
              Row({ space: 10 }) {
                this.field('服务器地址', this.serverAddr, 'frp-profile-server-addr', (value: string) => this.serverAddr = value)
                this.field('服务器端口', this.serverPort, 'frp-profile-server-port', (value: string) => this.serverPort = value)
              }.width('100%')
              Row({ space: 10 }) {
                this.field('User（可选）', this.user, 'frp-profile-user', (value: string) => this.user = value)
                this.field('Token', this.token, 'frp-profile-token', (value: string) => this.token = value, true)
              }.width('100%')
              Row({ space: 8 }) {
                Toggle({ type: ToggleType.Switch, isOn: this.tlsEnable }).id('frp-profile-tls-enable')
                  .onChange((value: boolean) => this.tlsEnable = value)
                Text('启用 TLS').layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.tlsDisableCustomTLSFirstByte })
                  .id('frp-profile-tls-disable-first-byte')
                  .onChange((value: boolean) => this.tlsDisableCustomTLSFirstByte = value)
                Text('禁用自定义 TLS 首字节').layoutWeight(1)
              }.width('100%')
              Text('端口映射').fontSize(16).fontWeight(FontWeight.Medium).width('100%')
              ForEach(this.proxies, (proxy: FrpProxy, index: number) => {
                Column({ space: 10 }) {
                  Text(`映射 ${index + 1}`).fontSize(14).fontWeight(FontWeight.Medium).width('100%')
                  Row({ space: 10 }) {
                    this.field('名称', proxy.name, `frp-profile-proxy-${index}-name`,
                      (value: string) => this.updateProxy(index, 'name', value))
                    Column({ space: 5 }) {
                      Text('协议').fontSize(12).fontColor($r('sys.color.font_secondary'))
                      Select([{ value: 'TCP' }, { value: 'UDP' }])
                        .selected(proxy.type === 'tcp' ? 0 : 1).id(`frp-profile-proxy-${index}-protocol`)
                        .value(proxy.type === 'tcp' ? 'TCP' : 'UDP')
                        .onSelect((choice: number) => this.updateProxy(index, 'type', choice === 1 ? 'udp' : 'tcp'))
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  }.width('100%')
                  this.field('本机 IP（建议 127.0.0.1）', proxy.localIP, `frp-profile-proxy-${index}-local-ip`,
                    (value: string) => this.updateProxy(index, 'localIP', value), false, 0)
                  Row({ space: 10 }) {
                    this.field('本机端口', `${proxy.localPort || ''}`, `frp-profile-proxy-${index}-local-port`,
                      (value: string) => this.updateProxy(index, 'localPort', value))
                    this.field('frps 公网端口', `${proxy.remotePort || ''}`, `frp-profile-proxy-${index}-remote-port`,
                      (value: string) => this.updateProxy(index, 'remotePort', value))
                  }.width('100%')
                  Button('删除此映射').id(`frp-profile-proxy-${index}-delete`)
                    .enabled(this.proxies.length > 1).onClick(() => this.removeProxy(index))
                }.width('100%').alignItems(HorizontalAlign.Start).padding(14)
                  .backgroundColor($r('sys.color.comp_background_primary')).borderRadius(14)
              }, (_proxy: FrpProxy, index: number) => `proxy-${index}`)
              Button('+ 添加映射').id('frp-profile-add-mapping').width('100%').onClick(() => this.addProxy())
            }
            Text('frpc 是客户端。公网端口需服务器许可；不要映射不可信的本机服务。')
              .fontSize(12).fontColor($r('sys.color.font_secondary')).width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 18, right: 18, top: 8, bottom: 24 })
        }.layoutWeight(1).width('100%')
        Row({ space: 10 }) {
          Button('取消').id('frp-profile-cancel').layoutWeight(1).onClick(() => this.modalOpen = false)
          Button('保存配置').id('frp-profile-save').layoutWeight(1).onClick(() => this.saveProfile())
        }.width('100%').padding({ left: 18, right: 18, top: 10, bottom: 16 })
      }.width('92%').constraintSize({ maxWidth: 980, maxHeight: '85%' })
        .height('85%').backgroundColor($r('sys.color.comp_background_primary')).borderRadius(22)
        .shadow({ radius: 28, color: '#44000000', offsetY: 8 })
    }.width('100%').height('100%').alignContent(Alignment.Center)
  }
}
