import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo, picker } from '@kit.CoreFileKit';
import { CoreUpdateCandidate, CoreUpdateGateway, PROJECT_ENGINE_VERSION, PROJECT_GO_VERSION } from '../services/CoreUpdateGateway';

@Component
export struct CoreUpdateSettings {
  @State private busy: boolean = false;
  @State private autoCheck: boolean = false;
  @State private status: string = '';
  @State private candidate: CoreUpdateCandidate | undefined = undefined;
  private generation: number = 0;
  private readonly gateway: CoreUpdateGateway = new CoreUpdateGateway();

  aboutToAppear(): void {
    const generation: number = ++this.generation;
    this.busy = false;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    preferences.getPreferences(context, 'core_update_settings').then((store) => {
      if (generation !== this.generation) {
        return;
      }
      this.autoCheck = store.getSync('auto_check', false) as boolean;
      if (this.autoCheck) {
        this.checkUpdate();
      }
    }).catch(() => {
      if (generation === this.generation) {
        this.status = '无法读取自动检查设置。';
      }
    });
  }

  aboutToDisappear(): void {
    this.generation++;
  }

  private async setAutoCheck(enabled: boolean): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const store = await preferences.getPreferences(context, 'core_update_settings');
      await store.put('auto_check', enabled);
      await store.flush();
      this.autoCheck = enabled;
      if (enabled) {
        await this.checkUpdate();
      }
    } catch (_error) {
      this.status = '保存自动检查设置失败。';
    }
  }

  private async checkUpdate(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const generation: number = this.generation;
    this.status = '正在读取 Tailscale 官方稳定版及 Go 要求…';
    try {
      const candidate: CoreUpdateCandidate = await this.gateway.checkLatest();
      if (generation === this.generation) {
        this.candidate = candidate;
        this.status = candidate.compatibleWithCurrentToolchain ?
          '版本信息已验证；仍需验证鸿蒙 PC 构建、补丁迁移和签名链。' :
          `目标要求 Go ${candidate.goVersion}，当前鸿蒙 Go ${PROJECT_GO_VERSION} 不兼容，不能直接替换内核。`;
      }
    } catch (error) {
      if (generation === this.generation) {
        this.candidate = undefined;
        this.status = `检查失败：${(error as Error).message}`;
      }
    } finally {
      if (generation === this.generation) {
        this.busy = false;
      }
    }
  }

  private async exportRequest(): Promise<void> {
    if (this.candidate === undefined || this.busy) {
      return;
    }
    this.busy = true;
    const generation: number = this.generation;
    let file: fileIo.File | undefined = undefined;
    try {
      const content: string = this.gateway.exportBuildRequest(this.candidate);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const destinations: string[] = await documentPicker.save({
        newFileNames: ['tailscale-core-build-request.json'], fileSuffixChoices: ['JSON|.json']
      });
      if (destinations.length === 0) {
        return;
      }
      file = fileIo.openSync(destinations[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
      if (generation === this.generation) {
        this.status = '构建请求已导出，不含私钥。端侧自动拉取、编译、签名与安装尚未实现，未修改当前 VPN。';
      }
    } catch (_error) {
      if (generation === this.generation) {
        this.status = '导出构建请求失败。';
      }
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (_error) {
          if (generation === this.generation) {
            this.status = '构建请求写入后关闭文件失败，请检查导出文件。';
          }
        }
      }
      if (generation === this.generation) {
        this.busy = false;
      }
    }
  }

  build() {
    Column({ space: 12 }) {
      Text('Tailscale 内核更新').fontSize(17).fontWeight(FontWeight.Medium)
      Text(`项目固定内核 ${PROJECT_ENGINE_VERSION} · 鸿蒙 Go ${PROJECT_GO_VERSION}`)
        .fontSize(12).fontColor($r('sys.color.font_secondary'))
      Row({ space: 12 }) {
        Text('打开此设置页面时自动检查').layoutWeight(1).fontSize(14)
        Toggle({ type: ToggleType.Switch, isOn: this.autoCheck })
          .id('core-update-auto-check').enabled(!this.busy)
          .onChange((enabled: boolean) => this.setAutoCheck(enabled))
      }
      if (this.candidate !== undefined) {
        Text(`官方稳定版 ${this.candidate.version} · 最低 Go ${this.candidate.goVersion}`).fontSize(14)
      }
      Row({ space: 12 }) {
        Button(this.busy ? '处理中…' : '检查更新').id('core-update-check')
          .enabled(!this.busy).onClick(() => this.checkUpdate())
        Button('导出本机构建请求').id('core-update-export')
          .enabled(!this.busy && this.candidate !== undefined).onClick(() => this.exportRequest())
      }
      Text('更新需重新编译鸿蒙 arm64 内核、迁移补丁并签名 HAP；安装会中断 VPN，必须人工确认。')
        .fontSize(12).fontColor($r('sys.color.font_secondary'))
      if (this.status.length > 0) {
        Text(this.status).id('core-update-status').fontSize(12).fontColor($r('sys.color.font_secondary'))
      }
    }
    .id('core-update-settings')
    .width('100%')
    .padding(14)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(16)
  }
}
