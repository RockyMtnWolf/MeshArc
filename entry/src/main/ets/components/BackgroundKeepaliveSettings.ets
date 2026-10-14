import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BackgroundKeepaliveMode, BackgroundKeepalivePreferences } from '../services/BackgroundKeepalivePreferences';
import { sharedBackgroundKeepaliveController } from '../services/BackgroundKeepaliveController';

@Component
export struct BackgroundKeepaliveSettings {
  @State private mode: BackgroundKeepaliveMode = 'off';
  @State private busy: boolean = false;
  @State private status: string = '';
  private generation: number = 0;
  private statusTimer: number = -1;

  aboutToAppear(): void {
    this.busy = false;
    const generation: number = ++this.generation;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    sharedBackgroundKeepaliveController.selectedMode(context).then((mode: BackgroundKeepaliveMode) => {
      if (generation === this.generation) {
        this.mode = mode;
      }
    });
    this.statusTimer = setInterval(() => {
      if (!this.busy) {
        this.status = sharedBackgroundKeepaliveController.getState().message;
      }
    }, 2000);
  }

  aboutToDisappear(): void {
    this.generation++;
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
  }

  private async selectMode(mode: BackgroundKeepaliveMode): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const generation: number = this.generation;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      const result = mode === 'off' ? await sharedBackgroundKeepaliveController.deactivate(context) :
        await sharedBackgroundKeepaliveController.activate(context, mode);
      if (generation === this.generation) {
        this.status = result.message;
        if (result.ok || result.selected) {
          this.mode = result.mode;
        }
      }
    } catch (error) {
      if (generation === this.generation) {
        this.status = `保活操作失败，code=${(error as BusinessError).code ?? -1}`;
      }
    } finally {
      if (generation === this.generation) {
        this.busy = false;
      }
    }
  }

  @Builder
  private ModeOption(mode: BackgroundKeepaliveMode, title: string, description: string) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(title).fontSize(15).fontColor($r('sys.color.font_primary'))
        Text(description).fontSize(12).fontColor($r('sys.color.font_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.mode === mode })
        .id(`background-keepalive-${mode}`)
        .enabled(!this.busy)
        .onChange((enabled: boolean) => this.selectMode(enabled ? mode : 'off'))
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  build() {
    Column({ space: 6 }) {
      Text('可选模拟保活').fontSize(17).fontWeight(FontWeight.Medium)
      Text('默认关闭。保活会增加耗电，系统仍可能回收应用。')
        .fontSize(12).fontColor($r('sys.color.font_secondary'))
      this.ModeOption('download', '模拟下载', '使用长时数据传输任务；不下载文件、不产生虚假进度或网络请求。')
      Divider()
      if (BackgroundKeepalivePreferences.supportsTaskKeeping()) {
        this.ModeOption('taskKeeping', '系统任务维持', '仅 PC/2-in-1 可用。使用系统任务维持类别；会耗电，系统仍可能结束任务。')
      } else {
        Text('系统任务维持仅支持 PC/2-in-1；手机和平板需要系统 ACL 授权，本应用不会申请。可选择模拟下载任务。')
          .fontSize(12).fontColor($r('sys.color.font_secondary'))
      }
      if (this.status.length > 0) {
        Text(this.status).fontSize(12).fontColor($r('sys.color.font_secondary'))
          .id('background-keepalive-status')
      }
    }
    .id('background-keepalive-settings')
    .width('100%')
    .padding(14)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(16)
  }
}
