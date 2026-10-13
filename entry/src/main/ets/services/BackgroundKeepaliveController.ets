import { common } from '@kit.AbilityKit';
import { BackgroundKeepaliveMode, BackgroundKeepalivePreferences } from './BackgroundKeepalivePreferences';
import { BackgroundKeepaliveAudioService, BackgroundKeepaliveAudioState } from './BackgroundKeepaliveAudioService';
import { BackgroundKeepaliveTaskMode, BackgroundTaskModeState, VpnBackgroundTaskManager } from './VpnBackgroundTaskManager';

export interface BackgroundKeepaliveResult {
  ok: boolean;
  mode: BackgroundKeepaliveMode;
  message: string;
  selected: boolean;
  taskActive: boolean;
  audioActive: boolean;
  activeModes: string[];
}

export class BackgroundKeepaliveController {
  private readonly taskManager: VpnBackgroundTaskManager;
  private readonly audioService: BackgroundKeepaliveAudioService;
  private disposed: boolean = false;
  private generation: number = 0;
  private modeTransitionInProgress: boolean = false;
  private operationQueue: Promise<void> = Promise.resolve();
  private lastResult: BackgroundKeepaliveResult = {
    ok: true, mode: 'off', message: '模拟保活未启用。', selected: false,
    taskActive: false, audioActive: false, activeModes: []
  };

  constructor(taskManager: VpnBackgroundTaskManager,
    audioService: BackgroundKeepaliveAudioService = new BackgroundKeepaliveAudioService()) {
    this.taskManager = taskManager;
    this.audioService = audioService;
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
    if (mode === 'audio') {
      const audioState: BackgroundKeepaliveAudioState = await this.audioService.start();
      if (!this.isCurrent(generation)) {
        await this.audioService.stop();
        return this.result(false, mode, '音频启动已取消。');
      }
      if (!audioState.active) {
        return this.result(false, mode, `音频播放未启动：${audioState.error}`);
      }
    } else {
      const stoppedAudio: BackgroundKeepaliveAudioState = await this.audioService.stop();
      if (!this.isCurrent(generation)) {
        return this.result(false, mode, '模式切换已取消。');
      }
      if (stoppedAudio.error.length > 0) {
        return this.result(false, mode, `音频停止失败：${stoppedAudio.error}`);
      }
    }
    try {
      const taskMode: BackgroundKeepaliveTaskMode = mode;
      const state: BackgroundTaskModeState = await this.taskManager.setKeepaliveMode(taskMode);
      if (!this.isCurrent(generation)) {
        if (mode === 'audio') {
          await this.audioService.stop();
        }
        return this.result(false, mode, '模式切换已取消。');
      }
      const expectedMode: string = mode === 'audio' ? 'audioPlayback' : 'dataTransfer';
      const requestedModeActive: boolean = mode === 'off' ||
        (state.taskActive && state.activeModes.includes(expectedMode));
      const audioActive: boolean = mode !== 'audio' || this.audioService.getState().active;
      if (state.error.length > 0 || !requestedModeActive || !audioActive) {
        if (mode === 'audio') {
          await this.audioService.stop();
        }
        const detail: string = state.error.length > 0 ? state.error :
          (!audioActive ? '音频播放器未处于播放状态。' : '系统后台任务尚未确认。');
        return this.result(false, mode, `后台保活未确认：${detail}`);
      }
      await BackgroundKeepalivePreferences.save(context, mode);
      const message: string = mode === 'audio' ?
        '低音量本地旋律正在播放；会耗电，系统仍可能暂停或回收应用。' :
        (mode === 'download' ? '模拟下载保活（无实际下载、无假进度、无网络请求）。' : '模拟保活已关闭。');
      return this.result(true, mode, message);
    } catch (_error) {
      if (mode === 'audio') {
        await this.audioService.stop();
      }
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
    await this.audioService.stop();
  }

  getState(): BackgroundKeepaliveResult {
    const mode: BackgroundKeepaliveMode = this.lastResult.mode;
    const taskState: BackgroundTaskModeState = this.taskManager.getKeepaliveTaskState();
    const audioState: BackgroundKeepaliveAudioState = this.audioService.getState();
    const expectedMode: string = mode === 'audio' ? 'audioPlayback' : 'dataTransfer';
    const taskActive: boolean = mode !== 'off' && taskState.taskActive &&
      taskState.activeModes.includes(expectedMode) && (mode !== 'audio' || audioState.active);
    const error: string = taskState.error.length > 0 ? taskState.error : audioState.error;
    const message: string = error.length > 0 ? `保活失败：${error}` :
      (this.lastResult.selected && !taskActive && mode !== 'off' ? '模式已选择，但实际播放或后台任务未运行。' :
        this.lastResult.message);
    return { ok: mode === 'off' ? this.lastResult.ok : taskActive && error.length === 0,
      mode: mode, message: message, selected: this.lastResult.selected, taskActive: taskActive,
      audioActive: audioState.active, activeModes: taskState.activeModes.slice() };
  }

  private result(ok: boolean, mode: BackgroundKeepaliveMode, message: string): BackgroundKeepaliveResult {
    const taskState: BackgroundTaskModeState = this.taskManager.getKeepaliveTaskState();
    const audioState: BackgroundKeepaliveAudioState = this.audioService.getState();
    const expectedMode: string = mode === 'audio' ? 'audioPlayback' : 'dataTransfer';
    const taskActive: boolean = mode !== 'off' && taskState.taskActive &&
      taskState.activeModes.includes(expectedMode) && (mode !== 'audio' || audioState.active);
    const result: BackgroundKeepaliveResult = { ok: ok, mode: mode, message: message,
      selected: ok || mode === taskState.selectedMode, taskActive: taskActive,
      audioActive: audioState.active, activeModes: taskState.activeModes.slice() };
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
