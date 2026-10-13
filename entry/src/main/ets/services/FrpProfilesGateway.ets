import nativeBridge from 'libtailscale_ohos.so';
import { common } from '@kit.AbilityKit';
import { FrpProfile } from './FrpProfileStore';
import { parseFrpToml, validateFrpConfig } from './FrpConfig';
import { FrpRuntimeStatus } from './FrpGateway';
import { sharedVpnBackgroundTask } from './BackgroundKeepaliveController';
import { awaitVpnOperation } from './VpnCommandGateway';

export interface FrpProfileRuntimeStatus extends FrpRuntimeStatus {
  profileId: string;
}

interface FrpProfileStartRequest {
  profileId: string;
  config: string;
}

const CALL_TIMEOUT_MS: number = 8000;
const STOP_TIMEOUT_MS: number = 15000;

export class FrpProfilesGateway {
  private static queue: Promise<void> = Promise.resolve();

  static start(context: common.UIAbilityContext, profile: FrpProfile): Promise<FrpProfileRuntimeStatus> {
    return FrpProfilesGateway.execute(async (): Promise<FrpProfileRuntimeStatus> => {
      const parsed = parseFrpToml(profile.toml);
      const errors: string[] = validateFrpConfig(parsed.config);
      if (errors.length > 0) throw new Error(errors.join('；'));
      const request: FrpProfileStartRequest = { profileId: profile.id, config: profile.toml };
      const state: FrpProfileRuntimeStatus = FrpProfilesGateway.parseStatus(await awaitVpnOperation(
        nativeBridge.frpProfileStartAsync(JSON.stringify(request)), 'frpc profile start', CALL_TIMEOUT_MS));
      if (state.profileId !== profile.id) throw new Error('frpc 返回了其他配置的状态');
      if (!FrpProfilesGateway.isActive(state)) {
        await FrpProfilesGateway.synchronizeOwner(context);
        throw new Error(state.error || 'frpc 配置未启动');
      }
      try {
        const task = await sharedVpnBackgroundTask.setFrpActive(context, true);
        if (!task.taskActive || !task.activeModes.includes('dataTransfer') || task.error.length > 0) {
          throw new Error(task.error || '系统未确认 FRP 后台持续任务');
        }
      } catch (error) {
        try {
          await FrpProfilesGateway.stopNative(profile.id);
          await FrpProfilesGateway.synchronizeOwner(context);
        } catch (_cleanupError) {
        }
        throw new Error((error as Error).message || 'FRP 后台持续任务启动失败');
      }
      return state;
    });
  }

  static stop(context: common.UIAbilityContext, profileId: string): Promise<FrpProfileRuntimeStatus> {
    return FrpProfilesGateway.execute(async (): Promise<FrpProfileRuntimeStatus> => {
      const state: FrpProfileRuntimeStatus = await FrpProfilesGateway.stopNative(profileId);
      await FrpProfilesGateway.synchronizeOwner(context);
      return state;
    });
  }

  static statuses(context: common.UIAbilityContext): Promise<FrpProfileRuntimeStatus[]> {
    return FrpProfilesGateway.execute(() => FrpProfilesGateway.synchronizeOwner(context));
  }

  private static async stopNative(profileId: string): Promise<FrpProfileRuntimeStatus> {
    let state: FrpProfileRuntimeStatus = FrpProfilesGateway.parseStatus(await awaitVpnOperation(
      nativeBridge.frpProfileStopAsync(profileId), 'frpc profile stop', CALL_TIMEOUT_MS));
    const deadline: number = Date.now() + STOP_TIMEOUT_MS;
    while (FrpProfilesGateway.isActive(state) && Date.now() < deadline) {
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, 300));
      const all: FrpProfileRuntimeStatus[] = await FrpProfilesGateway.readStatuses();
      const current: FrpProfileRuntimeStatus | undefined = all.find((item: FrpProfileRuntimeStatus) =>
        item.profileId === profileId);
      if (current === undefined) throw new Error('停止过程中配置状态丢失，不能确认已停止');
      state = current;
    }
    if (state.profileId !== profileId) throw new Error('停止结果的配置标识不匹配');
    if (FrpProfilesGateway.isActive(state)) throw new Error('等待此 FRP 实例停止超时，后台所有权仍保留');
    return state;
  }

  private static async synchronizeOwner(context: common.UIAbilityContext): Promise<FrpProfileRuntimeStatus[]> {
    const statuses: FrpProfileRuntimeStatus[] = await FrpProfilesGateway.readStatuses();
    await sharedVpnBackgroundTask.setFrpActive(context,
      statuses.some((state: FrpProfileRuntimeStatus) => FrpProfilesGateway.isActive(state)));
    return statuses;
  }

  private static async readStatuses(): Promise<FrpProfileRuntimeStatus[]> {
    const parsed: FrpProfileRuntimeStatus[] = JSON.parse(await awaitVpnOperation(
      nativeBridge.frpProfilesStatusAsync(), 'frpc profiles status', CALL_TIMEOUT_MS)) as FrpProfileRuntimeStatus[];
    if (!Array.isArray(parsed) || parsed.length > 32) throw new Error('frpc 配置状态列表无效');
    const ids: Set<string> = new Set<string>();
    for (const state of parsed) {
      FrpProfilesGateway.validateStatus(state);
      if (ids.has(state.profileId)) throw new Error('frpc 返回重复配置状态');
      ids.add(state.profileId);
    }
    return parsed;
  }

  private static parseStatus(raw: string): FrpProfileRuntimeStatus {
    const state: FrpProfileRuntimeStatus = JSON.parse(raw) as FrpProfileRuntimeStatus;
    FrpProfilesGateway.validateStatus(state);
    return state;
  }

  private static validateStatus(state: FrpProfileRuntimeStatus): void {
    if (typeof state.profileId !== 'string' || state.profileId.length === 0 ||
      typeof state.state !== 'string' || typeof state.error !== 'string' ||
      !Number.isInteger(state.proxyCount) || state.proxyCount < 0 ||
      typeof state.serviceRunning !== 'boolean' || typeof state.connectedToFrps !== 'boolean' ||
      !['starting', 'running', 'stopping', 'stopped', 'failed'].includes(state.state)) {
      throw new Error('frpc 配置运行状态无效');
    }
  }

  private static isActive(state: FrpProfileRuntimeStatus): boolean {
    return state.serviceRunning || ['starting', 'running', 'stopping'].includes(state.state);
  }

  private static execute<T>(operation: () => Promise<T>): Promise<T> {
    const result: Promise<T> = FrpProfilesGateway.queue.then(operation);
    FrpProfilesGateway.queue = result.then(() => {}, () => {});
    return result;
  }
}
