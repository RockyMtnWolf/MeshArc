import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import nativeBridge from 'libtailscale_ohos.so';
import { FrpConfig, validateFrpConfig } from './FrpConfig';
import { sharedVpnBackgroundTask } from './BackgroundKeepaliveController';
import { BackgroundTaskModeState } from './VpnBackgroundTaskManager';
import { awaitVpnOperation } from './VpnCommandGateway';

const FRP_NATIVE_CALL_TIMEOUT_MS: number = 8000;
const FRP_STOP_WAIT_TIMEOUT_MS: number = 15000;
const FRP_STATUS_INTERVAL_MS: number = 400;

export interface FrpRuntimeStatus {
  state: string;
  error: string;
  proxyCount: number;
  serviceRunning: boolean;
  connectedToFrps: boolean;
}

const CONFIG_NAME: string = 'frpc-config.toml';

function parseStatus(raw: string): FrpRuntimeStatus {
  const value = JSON.parse(raw) as FrpRuntimeStatus;
  if (typeof value.state !== 'string' || typeof value.error !== 'string' ||
    !Number.isInteger(value.proxyCount) || typeof value.serviceRunning !== 'boolean' ||
    typeof value.connectedToFrps !== 'boolean') {
    throw new Error('frpc 状态响应格式无效');
  }
  return value;
}

export class FrpGateway {
  static load(filesDir: string): string {
    const path: string = `${filesDir}/${CONFIG_NAME}`;
    return fileIo.accessSync(path) ? fileIo.readTextSync(path) : '';
  }

  static save(filesDir: string, toml: string): void {
    const path: string = `${filesDir}/${CONFIG_NAME}`;
    const temporaryPath: string = `${path}.tmp`;
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(temporaryPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, toml);
      fileIo.closeSync(file);
      file = undefined;
      fileIo.renameSync(temporaryPath, path);
    } catch (error) {
      if (file !== undefined) {
        try { fileIo.closeSync(file); } catch (_closeError) {}
      }
      try { if (fileIo.accessSync(temporaryPath)) fileIo.unlinkSync(temporaryPath); } catch (_cleanupError) {}
      throw new Error((error as Error).message ?? 'FRP 配置保存失败');
    }
  }

  static async start(context: common.UIAbilityContext, config: FrpConfig,
    configText: string): Promise<FrpRuntimeStatus> {
    const errors: string[] = validateFrpConfig(config);
    if (errors.length > 0) throw new Error(errors.join('；'));
    const initial: FrpRuntimeStatus = parseStatus(await awaitVpnOperation(
      nativeBridge.frpStartAsync(configText), 'frpc start', FRP_NATIVE_CALL_TIMEOUT_MS));
    if (initial.state !== 'starting' && initial.state !== 'running') {
      throw new Error(initial.error || `frpc 启动失败（${initial.state}）`);
    }
    try {
      const taskState: BackgroundTaskModeState = await sharedVpnBackgroundTask.setFrpActive(context, true);
      if (!taskState.taskActive || !taskState.activeModes.includes('dataTransfer') || taskState.error.length > 0) {
        throw new Error(taskState.error || 'frpc 已启动，但系统未确认后台持续任务');
      }
    } catch (error) {
      try {
        await FrpGateway.stop(context);
      } catch (_stopError) {
      }
      throw new Error((error as Error).message ?? 'FRP 后台任务启动失败');
    }
    return initial;
  }

  static async stop(context: common.UIAbilityContext): Promise<FrpRuntimeStatus> {
    const initial: FrpRuntimeStatus = parseStatus(await awaitVpnOperation(
      nativeBridge.frpStopAsync(), 'frpc stop', FRP_NATIVE_CALL_TIMEOUT_MS));
    if (initial.state === 'stopped') {
      await sharedVpnBackgroundTask.setFrpActive(context, false);
      return initial;
    }
    if (initial.state === 'failed') return await FrpGateway.waitForStop(context);
    if (initial.state !== 'stopping' && initial.state !== 'starting' && initial.state !== 'running') {
      throw new Error(initial.error || `frpc 停止状态未知（${initial.state}）`);
    }
    return await FrpGateway.waitForStop(context);
  }

  static async status(context: common.UIAbilityContext): Promise<FrpRuntimeStatus> {
    const state: FrpRuntimeStatus = await FrpGateway.readStatus(FRP_NATIVE_CALL_TIMEOUT_MS);
    if (state.state === 'failed') {
      try {
        await sharedVpnBackgroundTask.setFrpActive(context, false);
      } catch (error) {
        return { state: state.state, proxyCount: state.proxyCount,
          serviceRunning: state.serviceRunning, connectedToFrps: state.connectedToFrps,
          error: `${state.error}${state.error.length > 0 ? '；' : ''}后台任务释放失败：${(error as Error).message}` };
      }
    }
    return state;
  }

  private static async waitForStop(context: common.UIAbilityContext): Promise<FrpRuntimeStatus> {
    const deadline: number = Date.now() + FRP_STOP_WAIT_TIMEOUT_MS;
    while (Date.now() < deadline) {
      const state: FrpRuntimeStatus = await FrpGateway.readStatus(
        Math.min(FRP_NATIVE_CALL_TIMEOUT_MS, deadline - Date.now()));
      if (state.state === 'stopped' || state.state === 'failed') {
        await sharedVpnBackgroundTask.setFrpActive(context, false);
        return state;
      }
      if (state.state !== 'stopping' && state.state !== 'starting' && state.state !== 'running') {
        throw new Error(state.error || `frpc 返回未知状态（${state.state}）`);
      }
      await FrpGateway.pause(deadline);
    }
    throw new Error('等待 frpc 停止超时；后台任务所有权仍保留，运行状态待确认');
  }

  private static async readStatus(timeoutMs: number): Promise<FrpRuntimeStatus> {
    const raw: string = await awaitVpnOperation(nativeBridge.frpStatusAsync(), 'frpc status', timeoutMs);
    return parseStatus(raw);
  }

  private static async pause(deadline: number): Promise<void> {
    const waitMs: number = Math.min(FRP_STATUS_INTERVAL_MS, deadline - Date.now());
    if (waitMs > 0) {
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, waitMs));
    }
  }
}
