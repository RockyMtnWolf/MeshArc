import { common } from '@kit.AbilityKit';
import { BackgroundKeepaliveMode, BackgroundKeepalivePreferences } from './BackgroundKeepalivePreferences';
import { BackgroundKeepaliveTaskMode, BackgroundTaskModeState, VpnBackgroundTaskManager } from './VpnBackgroundTaskManager';

export interface BackgroundKeepaliveResult {
  ok: boolean;
  mode: BackgroundKeepaliveMode;
  message: string;
  selected: boolean;
  taskActive: boolean;
  activeModes: string[];
}

export class BackgroundKeepaliveController {
  private readonly taskManager: VpnBackgroundTaskManager;
  private disposed: boolean = false;
  private generation: number = 0;
  private modeTransitionInProgress: boolean = false;
  private operationQueue: Promise<void> = Promise.resolve();
  private lastResult: BackgroundKeepaliveResult = {
    ok: true, mode: 'off', message: '模拟保活未启用。', selected: false,
    taskActive: false, activeModes: []
  };

  constructor(taskManager: VpnBackgroundTaskManager) {
    this.taskManager = taskManager;
  }

  async selectedMode(context: common.Context): Promise<BackgroundKeepaliveMode> {
    return BackgroundKeepalivePreferences.load(context);
  }

  attach(): void {
    this.disposed = false;
    this.generation++;
  }

  async activate(context: common.UIAbilityContext, mode: BackgroundKeepaliveMode): Promise<BackgroundKeepaliveResult> {
    if (this.disposed) {
      return this.result(false, mode, '保活控制器已释放，请使用当前 Ability 的共享实例。');
    }
    if (mode === 'taskKeeping' && !BackgroundKeepalivePreferences.supportsTaskKeeping()) {
      return this.result(false, 'off', '任务维持仅支持 PC/2-in-1；当前设备不支持，应用不会申请系统 ACL 权限。可继续使用模拟下载任务。');
    }
    const generation: number = ++this.generation;
    this.modeTransitionInProgress = true;
    return this.serialize(async () => {
      try {
        return await this.activateInternal(context, mode, generation);
      } finally {
        if (generation === this.generation) {
          this.modeTransitionInProgress = false;
        }
      }
    });
  }

  private async activateInternal(context: common.UIAbilityContext, mode: BackgroundKeepaliveMode,
    generation: number): Promise<BackgroundKeepaliveResult> {
    if (!this.isCurrent(generation)) {
      return this.result(false, mode, '模式切换已取消。');
    }
    try {
      const taskMode: BackgroundKeepaliveTaskMode = mode;
      const state: BackgroundTaskModeState = await this.taskManager.setKeepaliveMode(taskMode);
      if (!this.isCurrent(generation)) {
        return this.result(false, mode, '模式切换已取消。');
      }
      const expectedMode: string = mode === 'taskKeeping' ? 'taskKeeping' : 'dataTransfer';
      const requestedModeActive: boolean = mode === 'off' ||
        (state.taskActive && state.activeModes.includes(expectedMode));
      if (state.error.length > 0 || !requestedModeActive) {
        const detail: string = state.error.length > 0 ? state.error :
          '系统后台任务尚未确认。';
        return this.result(false, mode, `后台保活未确认：${detail}`);
      }
      await BackgroundKeepalivePreferences.save(context, mode);
      const message: string = mode === 'taskKeeping' ?
        '系统任务维持已确认；会耗电，系统仍可能暂停或结束任务。' :
        (mode === 'download' ? '模拟下载保活（无实际下载、无假进度、无网络请求）。' : '模拟保活已关闭。');
      return this.result(true, mode, message);
    } catch (_error) {
      return this.result(false, mode, '后台保活操作失败；未确认任务已启动。');
    }
  }

  async deactivate(context: common.UIAbilityContext): Promise<BackgroundKeepaliveResult> {
    return this.activate(context, 'off');
  }

  async onBackground(context: common.UIAbilityContext): Promise<BackgroundKeepaliveResult> {
    if (this.modeTransitionInProgress) {
      return this.getState();
    }
    const generation: number = this.generation;
    const mode: BackgroundKeepaliveMode = await this.selectedMode(context);
    if (this.modeTransitionInProgress || generation !== this.generation) {
      return this.getState();
    }
    if (mode === 'off') {
      return this.result(true, 'off', '模拟保活未启用。');
    }
    return this.activate(context, mode);
  }

  async dispose(): Promise<void> {
    this.disposed = true;
    this.generation++;
    this.modeTransitionInProgress = false;
  }

  getState(): BackgroundKeepaliveResult {
    const mode: BackgroundKeepaliveMode = this.lastResult.mode;
    const taskState: BackgroundTaskModeState = this.taskManager.getKeepaliveTaskState();
    const expectedMode: string = mode === 'taskKeeping' ? 'taskKeeping' : 'dataTransfer';
    const taskActive: boolean = mode !== 'off' && taskState.taskActive &&
      taskState.activeModes.includes(expectedMode);
    const error: string = taskState.error;
    const message: string = error.length > 0 ? `保活失败：${error}` :
      (this.lastResult.selected && !taskActive && mode !== 'off' ? '模式已选择，但后台任务未运行。' :
        this.lastResult.message);
    return { ok: mode === 'off' ? this.lastResult.ok : taskActive && error.length === 0,
      mode: mode, message: message, selected: this.lastResult.selected, taskActive: taskActive,
      activeModes: taskState.activeModes.slice() };
  }

  private result(ok: boolean, mode: BackgroundKeepaliveMode, message: string): BackgroundKeepaliveResult {
    const taskState: BackgroundTaskModeState = this.taskManager.getKeepaliveTaskState();
    const expectedMode: string = mode === 'taskKeeping' ? 'taskKeeping' : 'dataTransfer';
    const taskActive: boolean = mode !== 'off' && taskState.taskActive &&
      taskState.activeModes.includes(expectedMode);
    const result: BackgroundKeepaliveResult = { ok: ok, mode: mode, message: message,
      selected: ok || mode === taskState.selectedMode, taskActive: taskActive,
      activeModes: taskState.activeModes.slice() };
    this.lastResult = result;
    return result;
  }

  private isCurrent(generation: number): boolean {
    return !this.disposed && generation === this.generation;
  }

  private serialize<T>(operation: () => Promise<T>): Promise<T> {
    const result: Promise<T> = this.operationQueue.then(operation, operation);
    this.operationQueue = result.then((): void => {}, (): void => {});
    return result;
  }
}

export const sharedVpnBackgroundTask = new VpnBackgroundTaskManager();
export const sharedBackgroundKeepaliveController = new BackgroundKeepaliveController(sharedVpnBackgroundTask);
