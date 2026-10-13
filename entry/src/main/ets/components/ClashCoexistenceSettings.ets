import nativeBridge from 'libtailscale_ohos.so';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { ClashConfigRepairGateway } from '../services/ClashConfigRepairGateway';
import { sharedVpnBackgroundTask } from '../services/BackgroundKeepaliveController';
import { awaitVpnOperation } from '../services/VpnCommandGateway';

interface CoexistenceStatus {
  active: boolean;
  address: string;
  error: string;
  inboundTCPPorts: number[];
  inboundTCPEnabled: boolean;
  inboundTCPAllowAll: boolean;
}

const CLASH_RULES: string = 'proxies:\n  - name: MeshArc-Tailnet\n    type: socks5\n    server: 127.0.0.1\n    port: 1055\n    udp: true\nrules:\n  - IP-CIDR,100.64.0.0/10,MeshArc-Tailnet,no-resolve\n  - IP-CIDR6,fd7a:115c:a1e0::/48,MeshArc-Tailnet,no-resolve\n# 将两条规则插入 rules 列表开头；子网请另加准确 CIDR。\n# 不要覆盖已有 proxies/rules，合并到当前 ClashBox 配置。';

@Component
export struct ClashCoexistenceSettings {
  @State private active: boolean = false;
  @State private busy: boolean = false;
  @State private message: string = '';
  @State private inboundTCPEnabled: boolean = false;
  @State private inboundTCPPorts: number[] = [];
  @State private inboundTCPAllowAll: boolean = false;
  @State private inboundTCPPortDrafts: string[] = [];
  @State private inboundTCPPortDraftIds: string[] = [];
  private timer: number = -1;
  private generation: number = 0;
  private refreshInFlight: boolean = false;
  private inboundPortsDraftDirty: boolean = false;
  private nextInboundPortDraftId: number = 1;

  aboutToAppear(): void {
    this.busy = false;
    this.generation++;
    void this.refresh();
    this.timer = setInterval(() => { if (!this.busy) { void this.refresh(); } }, 3000);
  }

  aboutToDisappear(): void {
    this.generation++;
    clearInterval(this.timer);
    this.timer = -1;
  }

  private async refresh(): Promise<void> {
    if (this.busy || this.refreshInFlight) {
      return;
    }
    this.refreshInFlight = true;
    const generation: number = this.generation;
    try {
      const state: CoexistenceStatus = await this.readStatus(await awaitVpnOperation(
        nativeBridge.coexistenceStatusAsync(), 'SOCKS status'));
      if (generation === this.generation) {
        this.applyStatus(state);
        if (state.error.length > 0) this.message = state.error;
      }
    } catch (_error) {
      if (generation === this.generation) {
        this.message = '无法读取用户态代理状态。';
      }
    } finally {
      this.refreshInFlight = false;
    }
  }

  private async setActive(enabled: boolean): Promise<void> {
    if (this.busy || enabled === this.active) {
      return;
    }
    this.busy = true;
    const generation: number = ++this.generation;
    try {
      const state: CoexistenceStatus = this.readStatus(await awaitVpnOperation(enabled ?
        nativeBridge.coexistenceStartAsync() : nativeBridge.coexistenceStopAsync(),
        'SOCKS control', 15000));
      this.applyStatus(state);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await sharedVpnBackgroundTask.setUserspaceActive(context, state.active);
      if (generation === this.generation) {
        this.message = state.error.length > 0 ? state.error :
          (state.active ? '本地 SOCKS 已监听；尚需合并 ClashBox 规则并验证流量。' : '用户态 SOCKS 已停止，未停止 ClashBox。');
      }
    } catch (_error) {
      if (generation === this.generation) {
        this.message = '用户态代理操作失败或超时，请刷新实际状态后重试。';
      }
    } finally {
      if (generation === this.generation) {
        this.busy = false;
      }
    }
  }

  private readStatus(raw: string): CoexistenceStatus {
    const state: CoexistenceStatus = JSON.parse(raw) as CoexistenceStatus;
    if (typeof state.active !== 'boolean' || typeof state.address !== 'string' ||
      typeof state.error !== 'string' || typeof state.inboundTCPEnabled !== 'boolean' ||
      typeof state.inboundTCPAllowAll !== 'boolean' ||
      !Array.isArray(state.inboundTCPPorts)) {
      throw new Error('共存状态格式无效');
    }
    for (const port of state.inboundTCPPorts) {
      if (!Number.isInteger(port) || port < 1 || port > 65535) {
        throw new Error('入站 TCP 端口状态无效');
      }
    }
    return state;
  }

  private applyStatus(state: CoexistenceStatus, forceDraftSync: boolean = false): void {
    this.active = state.active;
    this.inboundTCPEnabled = state.inboundTCPEnabled;
    this.inboundTCPPorts = state.inboundTCPPorts;
    this.inboundTCPAllowAll = state.inboundTCPAllowAll;
    if (forceDraftSync || !this.inboundPortsDraftDirty) {
      this.syncInboundPortDrafts(state.inboundTCPPorts);
    }
    AppStorage.setOrCreate('clashUserspaceActive', state.active);
  }

  private syncInboundPortDrafts(ports: number[]): void {
    const drafts: string[] = [];
    const ids: string[] = [];
    for (const port of ports) {
      drafts.push(`${port}`);
      ids.push(`clash-inbound-port-${this.nextInboundPortDraftId++}`);
    }
    this.inboundTCPPortDrafts = drafts;
    this.inboundTCPPortDraftIds = ids;
    this.inboundPortsDraftDirty = false;
  }

  private parseInboundTCPPorts(): number[] {
    const ports: number[] = [];
    for (const draft of this.inboundTCPPortDrafts) {
      const field: string = draft.trim();
      if (field.length === 0) continue;
      if (!/^\d+$/.test(field)) throw new Error(`端口格式无效：${field}`);
      const port: number = Number(field);
      if (!Number.isInteger(port) || port < 1 || port > 65535) {
        throw new Error(`端口须在 1–65535：${field}`);
      }
      if (ports.includes(port)) throw new Error(`端口重复：${port}`);
      ports.push(port);
    }
    if (ports.length > 16) throw new Error('最多允许选择 16 个入站 TCP 端口');
    return ports;
  }

  private confirmApplyInboundTCPPorts(): void {
    if (this.busy || !this.active) return;
    let ports: number[] = [];
    try {
      ports = this.parseInboundTCPPorts();
      if (ports.length === 0) {
        this.setInboundTCPPolicy(false, [], true);
        return;
      }
    } catch (error) {
      this.message = (error as Error).message;
      return;
    }
    const list: string = ports.map((port: number) => `127.0.0.1:${port}`).join('\n');
    this.getUIContext().showAlertDialog({
      title: '确认开放选定的入站 TCP 端口',
      message: `仅允许 Tailnet 中通过 ACL 的设备访问以下本机 loopback 服务；不会开放其他端口，也不会暴露到公网：\n${list}`,
      primaryButton: { value: '应用列表', action: () => this.setInboundTCPPolicy(false, ports, true) },
      secondaryButton: { value: '取消', action: () => {} }
    });
  }

  private confirmAllowAllInboundTCP(): void {
    if (this.busy || !this.active) return;
    this.getUIContext().showAlertDialog({
      title: '确认允许全部本机 TCP 入站？',
      message: '高风险：允许 Tailnet 中已通过 ACL 的设备连接本机所有 TCP 服务端口，并转发到本机 loopback。请确保本机服务已做认证与访问控制。此策略不对公网暴露；本应用内部 SOCKS 127.0.0.1:1055 不作为入站服务开放。此操作不会自动启用，需再次确认。',
      primaryButton: { value: '允许全部 TCP 入站', action: () =>
        this.setInboundTCPPolicy(true, this.inboundTCPPorts) },
      secondaryButton: { value: '取消', action: () => {} }
    });
  }

  private async setInboundTCPPolicy(allowAll: boolean, ports: number[], forceDraftSync: boolean = false): Promise<void> {
    if (this.busy || !this.active) return;
    this.busy = true;
    const generation: number = ++this.generation;
    try {
      const state: CoexistenceStatus = this.readStatus(await awaitVpnOperation(
        nativeBridge.coexistenceSetInboundTCPPolicyAsync(JSON.stringify({ allowAll: allowAll, ports: ports })),
        'inbound TCP policy', 15000));
      if (generation === this.generation) {
        this.applyStatus(state, forceDraftSync);
        this.message = state.error.length > 0 ? state.error :
          (state.inboundTCPAllowAll ? '已启用全部 TCP 入站策略。' :
            (state.inboundTCPEnabled ? `已应用端口列表：${state.inboundTCPPorts.join(', ')}` :
              '入站 TCP 端口已关闭。'));
      }
    } catch (error) {
      if (generation === this.generation) this.message = (error as Error).message;
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }

  private updateInboundPortDraft(index: number, value: string): void {
    const drafts: string[] = this.inboundTCPPortDrafts.slice();
    drafts[index] = value;
    this.inboundTCPPortDrafts = drafts;
    this.inboundPortsDraftDirty = true;
  }

  private addInboundPortDraft(): void {
    if (this.busy || !this.active || this.inboundTCPAllowAll) return;
    const drafts: string[] = this.inboundTCPPortDrafts.slice();
    drafts.push('');
    const ids: string[] = this.inboundTCPPortDraftIds.slice();
    ids.push(`clash-inbound-port-${this.nextInboundPortDraftId++}`);
    this.inboundTCPPortDrafts = drafts;
    this.inboundTCPPortDraftIds = ids;
    this.inboundPortsDraftDirty = true;
  }

  private removeInboundPortDraft(index: number): void {
    if (this.busy || !this.active || this.inboundTCPAllowAll) return;
    const drafts: string[] = [];
    const ids: string[] = [];
    for (let draftIndex: number = 0; draftIndex < this.inboundTCPPortDrafts.length; draftIndex++) {
      if (draftIndex !== index) {
        drafts.push(this.inboundTCPPortDrafts[draftIndex]);
        ids.push(this.inboundTCPPortDraftIds[draftIndex]);
      }
    }
    this.inboundTCPPortDrafts = drafts;
    this.inboundTCPPortDraftIds = ids;
    this.inboundPortsDraftDirty = true;
  }

  private async importAndExportClashConfig(): Promise<void> {
    if (this.busy) return;
    this.busy = true;
    const generation: number = ++this.generation;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result: string = await ClashConfigRepairGateway.importAndExport(context);
      if (generation === this.generation) this.message = result;
    } catch (error) {
      if (generation === this.generation) this.message = (error as Error).message;
    } finally {
      if (generation === this.generation) this.busy = false;
    }
  }

  private async copyRules(): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, CLASH_RULES));
      this.message = '规则已复制：请将规则插入 ClashBox 的 rules 列表开头；不要覆盖原代理配置。';
    } catch (_error) {
      this.message = '复制失败。';
    }
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Text('ClashBox 共存（用户态）').fontSize(17).fontWeight(FontWeight.Medium).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.active })
          .id('clash-coexistence-toggle').enabled(!this.busy)
          .onChange((enabled: boolean) => this.setActive(enabled))
      }
      Text('保留 ClashBox VPN；先断开本应用系统 VPN，再开启本地 SOCKS 127.0.0.1:1055。此模式不创建第二个 TUN，不自动修改 ClashBox。')
        .fontSize(12).fontColor($r('sys.color.font_secondary'))
      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text('全部 TCP 入站端口').fontSize(15).fontWeight(FontWeight.Medium)
          Text('Tailnet ACL 内全部端口 · 高风险').fontSize(11)
            .fontColor($r('sys.color.font_secondary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.inboundTCPAllowAll })
          .id('clash-inbound-tcp-allow-all').enabled(!this.busy && this.active)
          .onChange((enabled: boolean) => enabled ? this.confirmAllowAllInboundTCP() :
            this.setInboundTCPPolicy(false, this.inboundTCPPorts))
      }
      Text(this.active ? (this.inboundTCPAllowAll ?
        `全部模式已启用。保留的端口列表：${this.inboundTCPPorts.join(', ') || '空'}。` :
        (this.inboundTCPEnabled ?
          `列表模式已启用：${this.inboundTCPPorts.join(', ')} → 本机 loopback。` :
          '入站关闭。编辑并应用端口列表以启用；示例：3240。')) :
        '共存关闭时入站策略不可用；启用后仍受 Tailnet ACL 限制，并仅转发到本机 loopback。')
        .id('clash-inbound-tcp-info').fontSize(12).fontColor($r('sys.color.font_secondary'))
      if (!this.inboundTCPAllowAll) {
        ForEach(this.inboundTCPPortDrafts, (port: string, index: number) => {
          Row({ space: 8 }) {
            TextInput({ text: port, placeholder: 'TCP 端口，例如 3240' })
              .id(this.inboundTCPPortDraftIds[index]).enabled(!this.busy && this.active)
              .type(InputType.Number)
              .onChange((value: string) => this.updateInboundPortDraft(index, value))
              .layoutWeight(1).padding(10)
              .backgroundColor($r('sys.color.comp_background_primary')).borderRadius(10)
            Button('删除').id(`${this.inboundTCPPortDraftIds[index]}-remove`)
              .enabled(!this.busy && this.active)
              .onClick(() => this.removeInboundPortDraft(index))
          }
          .width('100%')
        }, (_port: string, index: number) => this.inboundTCPPortDraftIds[index])
        Row({ space: 8 }) {
          Button('添加端口').id('clash-inbound-tcp-add')
            .enabled(!this.busy && this.active).onClick(() => this.addInboundPortDraft())
          Button('应用列表').id('clash-inbound-tcp-apply')
            .enabled(!this.busy && this.active)
            .onClick(() => this.confirmApplyInboundTCPPorts())
        }.width('100%').justifyContent(FlexAlign.SpaceBetween)
      }
      Button('复制 ClashBox 分流规则').id('clash-copy-rules').onClick(() => this.copyRules())
      Button('导入并导出修补副本').id('clash-config-repair')
        .enabled(!this.busy).onClick(() => this.importAndExportClashConfig())
      Text('配置修补会读取原文件并导出新副本，不修改原文件。')
        .id('clash-config-repair-note').fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
      Text('入口：配置页长按当前配置→编辑→元数据页再点“编辑配置”；先导出备份。')
        .fontSize(12).fontColor($r('sys.color.font_secondary'))
      Text('仅合并代理与规则到原配置；将规则插入 rules 列表开头，勿整体替换；订阅更新可能覆盖修改。SOCKS 监听不等于共存实测。')
        .fontSize(12).fontColor($r('sys.color.font_secondary'))
      if (this.message.length > 0) {
        Text(this.message).id('clash-coexistence-status').fontSize(12)
      }
    }
    .id('clash-coexistence-settings').width('100%').padding(14)
    .alignItems(HorizontalAlign.Start).backgroundColor($r('sys.color.comp_background_primary')).borderRadius(16)
  }
}
