import { common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';

export type BackgroundKeepaliveMode = 'off' | 'download' | 'taskKeeping';

const STORE_NAME: string = 'mesh_arc_background_keepalive';
const MODE_KEY: string = 'selected_mode';

export class BackgroundKeepalivePreferences {
  static supportsTaskKeeping(): boolean {
    return deviceInfo.deviceType === deviceInfo.DeviceTypes.TYPE_2IN1;
  }

  static async load(context: common.Context): Promise<BackgroundKeepaliveMode> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const storedMode: string = store.getSync(MODE_KEY, 'off') as string;
      const mode: BackgroundKeepaliveMode = BackgroundKeepalivePreferences.normalize(storedMode);
      if (mode !== storedMode) {
        store.putSync(MODE_KEY, mode);
        await store.flush();
      }
      return mode;
    } catch (_error) {
      return 'off';
    }
  }

  static async save(context: common.Context, mode: BackgroundKeepaliveMode): Promise<void> {
    const store = await preferences.getPreferences(context, STORE_NAME);
    store.putSync(MODE_KEY, BackgroundKeepalivePreferences.normalize(mode));
    await store.flush();
  }

  private static normalize(mode: string): BackgroundKeepaliveMode {
    if (mode === 'download') {
      return mode;
    }
    if (mode === 'taskKeeping' || mode === 'audio') {
      return BackgroundKeepalivePreferences.supportsTaskKeeping() ? 'taskKeeping' : 'off';
    }
    return 'off';
  }
}
