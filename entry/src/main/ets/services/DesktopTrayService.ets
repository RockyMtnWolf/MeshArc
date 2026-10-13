import { common } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { statusBarManager } from '@kit.DeskTopExtensionKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'DesktopTray';

export class DesktopTrayService {
  private registrationInFlight: boolean = false;
  private registered: boolean = false;
  private disposed: boolean = false;
  private whiteIcon?: image.PixelMap;
  private blackIcon?: image.PixelMap;

  isRegistered(): boolean {
    return this.registered && !this.disposed;
  }

  register(context: common.UIAbilityContext): void {
    if (this.registrationInFlight || this.registered || this.disposed) {
      return;
    }
    this.registrationInFlight = true;
    this.registerStatusBar(context).finally(() => {
      this.registrationInFlight = false;
    });
  }

  dispose(context: common.UIAbilityContext): void {
    this.disposed = true;
    if (this.registered) {
      try {
        statusBarManager.removeFromStatusBar(context);
      } catch (error) {
        const businessError = error as BusinessError;
        hilog.warn(DOMAIN, TAG, 'Status bar removal failed. code=%{public}d', businessError.code ?? -1);
      }
      this.registered = false;
    }
    this.releaseIcon(this.whiteIcon);
    this.releaseIcon(this.blackIcon);
    this.whiteIcon = undefined;
    this.blackIcon = undefined;
  }

  private async registerStatusBar(context: common.UIAbilityContext): Promise<void> {
    let whiteIcon: image.PixelMap | undefined;
    let blackIcon: image.PixelMap | undefined;
    try {
      if (deviceInfo.sdkApiVersion < 26 || deviceInfo.deviceType !== deviceInfo.DeviceTypes.TYPE_2IN1 ||
        typeof statusBarManager.isStatusBarCapabilitySupported !== 'function') {
        hilog.info(DOMAIN, TAG, 'Status bar skipped: unsupported platform');
        return;
      }
      if (!await statusBarManager.isStatusBarCapabilitySupported(context)) {
        hilog.info(DOMAIN, TAG, 'Status bar skipped: capability unavailable');
        return;
      }
      whiteIcon = await this.createIcon(context, 'mesh_arc_status_white.svg');
      blackIcon = await this.createIcon(context, 'mesh_arc_status_black.svg');
      if (this.disposed) {
        return;
      }
      const item: statusBarManager.StatusBarItem = {
        icons: { white: whiteIcon, black: blackIcon },
        quickOperation: {
          abilityName: 'MeshArcStatusBarAbility',
          moduleName: 'entry',
          title: 'MeshArc',
          height: 120
        },
        statusBarGroupMenu: [[{
          title: '打开 MeshArc',
          menuAction: { abilityName: 'EntryAbility', moduleName: 'entry' }
        }]],
        hoverTips: 'MeshArc'
      };
      statusBarManager.addToStatusBar(context, item);
      this.whiteIcon = whiteIcon;
      this.blackIcon = blackIcon;
      this.registered = true;
      hilog.info(DOMAIN, TAG, 'Status bar registered');
      whiteIcon = undefined;
      blackIcon = undefined;
    } catch (error) {
      const businessError = error as BusinessError;
      hilog.warn(DOMAIN, TAG, 'Status bar registration unavailable. code=%{public}d', businessError.code ?? -1);
    } finally {
      this.releaseIcon(whiteIcon);
      this.releaseIcon(blackIcon);
    }
  }

  private async createIcon(context: common.UIAbilityContext, fileName: string): Promise<image.PixelMap> {
    const rawFile = context.resourceManager.getRawFileContentSync(fileName);
    const source: image.ImageSource = image.createImageSource(rawFile.buffer);
    try {
      return await source.createPixelMap();
    } finally {
      await source.release();
    }
  }

  private releaseIcon(icon?: image.PixelMap): void {
    if (icon !== undefined) {
      icon.release().catch((error: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'Status bar icon release failed. code=%{public}d', error.code ?? -1);
      });
    }
  }
}
