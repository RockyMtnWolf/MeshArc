import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'MeshArcStatusBarPage';

@Entry
@Component
struct StatusBarPage {
  private openApplication(): void {
    const context = this.getUIContext().getHostContext() as common.UIExtensionContext | undefined;
    if (context === undefined) {
      return;
    }
    context.startAbility({
      bundleName: context.applicationInfo.name,
      abilityName: 'EntryAbility',
      parameters: { desktopTrayAction: 'open' }
    })
      .catch((error: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'Unable to open MeshArc. code=%{public}d', error.code ?? -1);
    });
  }

  build() {
    Column({ space: 16 }) {
      Text('TunnelArk')
        .fontSize(18)
        .fontWeight(600)
      Button('打开 TunnelArk')
        .onClick(() => this.openApplication())
    }
    .width('100%')
    .height('100%')
    .padding(20)
  }
}
