import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { notificationManager } from '@kit.NotificationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { StoragePaths } from './StoragePaths';
import { DiagnosticEventStore } from './DiagnosticEventStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'VpnBackgroundTask';
const BUNDLE_NAME: string = 'io.github.rockymtnwolf.mesharc';
const ENTRY_ABILITY_NAME: string = 'EntryAbility';
const VPN_STATUS_FRESH_MS: number = 15000;
const VPN_STATUS_GRACE_MS: number = 60000;
const CONNECTION_CHECK_INTERVAL_MS: number = 1000;
const NOTIFICATION_UPDATE_INTERVAL_MS: number = 30000;
const START_RETRY_BASE_MS: number = 30000;
const START_RETRY_MAX_MS: number = 300000;

interface VpnRuntimeStatus {
  state: string;
  txBytes: number;
  rxBytes: number;
}

export type BackgroundKeepaliveTaskMode = 'off' | 'download' | 'audio';

export interface BackgroundTaskModeState {
  selectedMode: BackgroundKeepaliveTaskMode;
  taskActive: boolean;
  activeModes: string[];
  error: string;
}

export class VpnBackgroundTaskManager {
  private context?: common.UIAbilityContext;
  private monitoring: boolean = false;
  private operationInFlight: boolean = false;
  private reconciliationPending: boolean = false;
  private listenerRegistered: boolean = false;
  private suspendListenerRegistered: boolean = false;
  private lifecycleGeneration: number = 0;
  private cancellationRevision: number = 0;
  private monitorTimer: number = -1;
  private task?: backgroundTaskManager.ContinuousTaskNotification;
  private stopping: boolean = false;
  private suppressedUntilDisconnect: boolean = false;
  private nextStartAtMs: number = 0;
  private retryCount: number = 0;
  private lastLiveAtMs: number = 0;
  private nextNotificationAtMs: number = 0;
  private keepaliveMode: BackgroundKeepaliveTaskMode = 'off';
  private frpActive: boolean = false;
  private userspaceActive: boolean = false;
  private activeModes: string[] = [];
  private lastOperationError: string = '';

  async setKeepaliveMode(mode: BackgroundKeepaliveTaskMode): Promise<BackgroundTaskModeState> {
    this.keepaliveMode = mode;
    this.lastOperationError = '';
    if (this.context !== undefined) {
      await this.reconcile(this.context);
    }
    return this.getKeepaliveTaskState();
  }

  async setFrpActive(context: common.UIAbilityContext, active: boolean): Promise<BackgroundTaskModeState> {
    this.context = context;
    this.frpActive = active;
    await this.reconcile(context);
    return this.getKeepaliveTaskState();
  }

  async setUserspaceActive(context: common.UIAbilityContext, active: boolean): Promise<BackgroundTaskModeState> {
    this.context = context;
    this.userspaceActive = active;
    await this.reconcile(context);
    return this.getKeepaliveTaskState();
  }

  getKeepaliveTaskState(): BackgroundTaskModeState {
    return {
      selectedMode: this.keepaliveMode,
      taskActive: this.task !== undefined,
      activeModes: this.activeModes.slice(),
      error: this.lastOperationError
    };
  }

  private readonly cancelCallback =
    (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      if (this.stopping || (this.task?.continuousTaskId !== undefined &&
        info.id !== this.task.continuousTaskId)) {
        return;
      }
      // Cancellation can arrive before startBackgroundRunning resolves.
      this.cancellationRevision++;
      this.task = undefined;
      const userCancelled: boolean =
        info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL ||
        info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL_REMOVE_NOTIFICATION;
      this.suppressedUntilDisconnect = userCancelled;
      if (!userCancelled) {
        this.scheduleRetry();
      }
      this.record(userCancelled ? 'background_user_cancelled' : 'background_system_cancelled', info.reason);
      hilog.info(DOMAIN, TAG, 'VPN background task cancelled. id=%{public}d reason=%{public}d',
        info.id, info.reason);
    };

  private readonly suspendCallback =
    (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
      if (info.continuousTaskId !== this.task?.continuousTaskId) {
        return;
      }
      this.record(info.suspendState ? 'background_suspended' : 'background_resumed', info.suspendReason);
      hilog.info(DOMAIN, TAG, 'VPN background task suspend=%{public}s reason=%{public}d',
        `${info.suspendState}`, info.suspendReason);
    };

  register(context: common.UIAbilityContext): void {
    if (this.monitoring) {
      return;
    }
    this.context = context;
    try {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelCallback);
      this.listenerRegistered = true;
    } catch (error) {
      this.record('background_listener_failed', (error as BusinessError).code ?? -1);
    }
    try {
      backgroundTaskManager.on('continuousTaskSuspend', this.suspendCallback);
      this.suspendListenerRegistered = true;
    } catch (error) {
      this.record('background_suspend_listener_failed', (error as BusinessError).code ?? -1);
    }
    this.monitoring = true;
    ++this.lifecycleGeneration;
    this.reconcile(context);
    this.monitorTimer = setInterval(() => this.reconcile(context), CONNECTION_CHECK_INTERVAL_MS);
  }

  unregister(): void {
    this.monitoring = false;
    this.lifecycleGeneration++;
    if (this.monitorTimer >= 0) {
      clearInterval(this.monitorTimer);
      this.monitorTimer = -1;
    }
    if (this.listenerRegistered) {
      try {
        backgroundTaskManager.off('continuousTaskCancel', this.cancelCallback);
      } catch (_error) {
        // Ability destruction also releases this process's listeners.
      }
      this.listenerRegistered = false;
    }
    if (this.suspendListenerRegistered) {
      try {
        backgroundTaskManager.off('continuousTaskSuspend', this.suspendCallback);
      } catch (_error) {
        // Best-effort teardown.
      }
      this.suspendListenerRegistered = false;
    }
    if (this.context !== undefined) {
      this.reconcile(this.context);
    }
  }

  onBackground(context: common.UIAbilityContext): void {
    this.record('background_entered');
    this.reconcile(context);
  }

  onForeground(context: common.UIAbilityContext): void {
    // Foreground permits retrying a system failure, not undoing user dismissal.
    this.nextStartAtMs = 0;
    this.retryCount = 0;
    this.reconcile(context);
  }

  private async reconcile(context: common.UIAbilityContext): Promise<void> {
    if (this.operationInFlight) {
      this.reconciliationPending = true;
      return;
    }
    this.operationInFlight = true;
    const generation: number = this.lifecycleGeneration;
    try {
      if (!this.shouldMaintainTask()) {
        await this.stop(context);
        return;
      }
      const status: VpnRuntimeStatus = this.readStatus(context.filesDir);
      if (status.state === 'disconnected' && this.keepaliveMode === 'off' && !this.hasExternalOwner()) {
        this.suppressedUntilDisconnect = false;
        this.nextStartAtMs = 0;
        this.retryCount = 0;
        this.lastLiveAtMs = 0;
        await this.stop(context);
        return;
      }
      if (status.state !== 'connected' && this.keepaliveMode === 'off' && !this.hasExternalOwner()) {
        if (this.task !== undefined && Date.now() - this.lastLiveAtMs > VPN_STATUS_GRACE_MS) {
          this.record('background_status_timeout');
          await this.stop(context);
        }
        return;
      }
      const desiredModes: string[] = this.desiredModes(status);
      if (desiredModes.length === 0) {
        this.suppressedUntilDisconnect = false;
        this.nextStartAtMs = 0;
        this.retryCount = 0;
        this.lastLiveAtMs = 0;
        await this.stop(context);
        return;
      }
      if (status.state === 'connected') {
        this.lastLiveAtMs = Date.now();
      }
      if (this.task !== undefined && !this.sameModes(this.activeModes, desiredModes)) {
        await this.updateTaskModes(context, desiredModes);
      }
      if (this.task === undefined && !this.suppressedUntilDisconnect && Date.now() >= this.nextStartAtMs) {
        await this.start(context, generation);
      }
      if (this.monitoring && generation === this.lifecycleGeneration && this.task !== undefined &&
        this.activeModes.includes('dataTransfer')) {
        await this.updateNotification(context, status);
      }
    } catch (error) {
      this.lastOperationError = this.errorMessage(error);
      this.scheduleRetry();
      this.record('background_operation_failed', (error as BusinessError).code ?? -1);
    } finally {
      // Destruction may happen during any awaited operation.
      if (!this.shouldMaintainTask()) {
        await this.stop(context);
      }
      this.operationInFlight = false;
      if (this.reconciliationPending) {
        this.reconciliationPending = false;
        this.reconcile(context);
      }
    }
  }

  private async start(context: common.UIAbilityContext, generation: number): Promise<void> {
    const revision: number = this.cancellationRevision;
    const info: wantAgent.WantAgentInfo = {
      wants: [{ bundleName: BUNDLE_NAME, abilityName: ENTRY_ABILITY_NAME }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 1001,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    const agent: WantAgent = await wantAgent.getWantAgent(info);
    if (!this.shouldMaintainTask() || generation !== this.lifecycleGeneration ||
      revision !== this.cancellationRevision || this.desiredModes(this.readStatus(context.filesDir)).length === 0) {
      return;
    }
    // The numeric overload returns void and cannot supply the system-owned
    // notification ID needed for DATA_TRANSFER live-view updates.
    const task: backgroundTaskManager.ContinuousTaskNotification =
      await backgroundTaskManager.startBackgroundRunning(context, this.desiredModes(this.readStatus(context.filesDir)), agent);
    if (revision !== this.cancellationRevision) {
      return;
    }
    this.task = task;
    this.activeModes = this.desiredModes(this.readStatus(context.filesDir));
    this.lastOperationError = '';
    if (!this.shouldMaintainTask() || generation !== this.lifecycleGeneration ||
      this.desiredModes(this.readStatus(context.filesDir)).length === 0) {
      await this.stop(context);
      return;
    }
    this.nextNotificationAtMs = 0;
    this.record('background_started');
    hilog.info(DOMAIN, TAG, 'VPN DATA_TRANSFER background task started. id=%{public}d',
      task.continuousTaskId ?? -1);
  }

  private async updateTaskModes(context: common.UIAbilityContext, modes: string[]): Promise<void> {
    const updated = await backgroundTaskManager.updateBackgroundRunning(context, modes);
    this.task = updated;
    this.activeModes = modes;
    this.lastOperationError = '';
    this.nextNotificationAtMs = 0;
    this.record('background_modes_updated');
  }

  private desiredModes(status: VpnRuntimeStatus): string[] {
    const modes: string[] = [];
    if (status.state === 'connected' || this.keepaliveMode === 'download' || this.frpActive || this.userspaceActive) {
      modes.push('dataTransfer');
    }
    if (this.keepaliveMode === 'audio') {
      modes.push('audioPlayback');
    }
    return modes;
  }

  private hasExternalOwner(): boolean {
    return this.frpActive || this.userspaceActive;
  }

  private shouldMaintainTask(): boolean {
    return this.monitoring || this.hasExternalOwner();
  }

  private sameModes(left: string[], right: string[]): boolean {
    return left.length === right.length && left.every((mode: string) => right.includes(mode));
  }

  private async stop(context: common.UIAbilityContext): Promise<void> {
    if (this.task === undefined) {
      return;
    }
    this.stopping = true;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      this.task = undefined;
      this.activeModes = [];
      this.record('background_stopped');
    } catch (error) {
      this.lastOperationError = this.errorMessage(error);
      this.record('background_stop_failed', (error as BusinessError).code ?? -1);
    } finally {
      this.stopping = false;
    }
  }

  private async updateNotification(context: common.UIAbilityContext, status: VpnRuntimeStatus): Promise<void> {
    const task: backgroundTaskManager.ContinuousTaskNotification | undefined = this.task;
    if (task === undefined || Date.now() < this.nextNotificationAtMs) {
      return;
    }
    this.nextNotificationAtMs = Date.now() + NOTIFICATION_UPDATE_INTERVAL_MS;
    const title: string = context.resourceManager.getStringByNameSync('notification_vpn_background_title');
    const simulatedDownload: boolean = this.keepaliveMode === 'download';
    const traffic: string = simulatedDownload ? '模拟下载保活（无实际下载）' :
      (status.state === 'connected' ?
        `↑ ${this.formatBytes(status.txBytes)}  ↓ ${this.formatBytes(status.rxBytes)}` : '后台数据传输保活中');
    const request: notificationManager.NotificationRequest = {
      id: task.notificationId,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      isAlertOnce: true,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: { typeCode: 8, title: title, text: traffic }
      }
    };
    request.template = {
      name: 'downloadTemplate',
      data: { title: title, fileName: traffic, progressValue: 0 }
    };
    try {
      await notificationManager.publish(request);
    } catch (error) {
      this.record('background_notification_failed', (error as BusinessError).code ?? -1);
    }
  }

  private readStatus(filesDir: string): VpnRuntimeStatus {
    const result: VpnRuntimeStatus = { state: 'unknown', txBytes: 0, rxBytes: 0 };
    try {
      const status: string = fileIo.readTextSync(StoragePaths.vpnStatusPath(filesDir));
      const heartbeatMs: number = this.statusNumber(status, 'heartbeatMs');
      const ageMs: number = Date.now() - heartbeatMs;
      if (heartbeatMs <= 0 || ageMs < 0 || ageMs > VPN_STATUS_FRESH_MS) {
        return result;
      }
      const normalized: string = status.toLowerCase();
      if (normalized.includes('extension destroyed') || normalized.includes('vpn disconnected') ||
        normalized.includes('state=stopped') || normalized.startsWith('stopped') ||
        (normalized.startsWith('failed') && !normalized.includes('status unavailable'))) {
        result.state = 'disconnected';
      } else if (normalized.includes('state=running') && normalized.includes('tun=true')) {
        result.state = 'connected';
        result.txBytes = this.statusNumber(status, 'txBytes');
        result.rxBytes = this.statusNumber(status, 'rxBytes');
      }
    } catch (_error) {
      // Atomic file replacement or temporary I/O failure is uncertain state.
    }
    return result;
  }

  private statusNumber(status: string, field: string): number {
    const match: RegExpMatchArray | null = status.match(new RegExp(`(?:^|\\s)${field}=(\\d+)(?:\\s|$)`));
    const value: number = match === null ? 0 : Number(match[1]);
    return Number.isSafeInteger(value) && value >= 0 ? value : 0;
  }

  private formatBytes(bytes: number): string {
    if (bytes >= 1024 * 1024 * 1024) {
      return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GiB`;
    }
    if (bytes >= 1024 * 1024) {
      return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
    }
    return `${(bytes / 1024).toFixed(1)} KiB`;
  }

  private scheduleRetry(): void {
    this.nextStartAtMs = Date.now() + Math.min(START_RETRY_MAX_MS,
      START_RETRY_BASE_MS * Math.pow(2, Math.min(this.retryCount, 4)));
    this.retryCount++;
  }

  private errorMessage(error: Object): string {
    const businessError = error as BusinessError;
    return businessError.message ?? `后台任务失败，错误码 ${businessError.code ?? 'unknown'}`;
  }

  private record(event: string, code: number = 0): void {
    hilog.info(DOMAIN, TAG, '%{public}s code=%{public}d', event, code);
    if (this.context !== undefined) {
      DiagnosticEventStore.record(this.context.filesDir, 'ui', event, 'background', code);
    }
  }
}
