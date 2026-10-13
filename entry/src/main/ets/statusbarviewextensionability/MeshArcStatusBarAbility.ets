import { UIExtensionContentSession, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { StatusBarViewExtensionAbility } from '@kit.DeskTopExtensionKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'MeshArcStatusBar';

export default class MeshArcStatusBarAbility extends StatusBarViewExtensionAbility {
  onSessionCreate(_want: Want, session: UIExtensionContentSession): void {
    try {
      session.loadContent('pages/StatusBarPage');
      hilog.info(DOMAIN, TAG, 'Status bar quick operation page loaded');
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'Status bar quick operation page failed. code=%{public}d',
        businessError.code ?? -1);
    }
  }
}
