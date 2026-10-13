import nativeBridge from 'libtailscale_ohos.so';
import { Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';

const VPN_OPERATION_TIMEOUT_MS: number = 8000;

export function awaitVpnOperation(promise: Promise<string>, operation: string,
  timeoutMs: number = VPN_OPERATION_TIMEOUT_MS): Promise<string> {
  return new Promise<string>((resolve: (value: string) => void, reject: (reason: Error) => void) => {
    const timer: number = setTimeout(() => {
      reject(new Error(`${operation} timed out after ${timeoutMs} ms`));
    }, timeoutMs);
    promise.then((value: string) => {
      clearTimeout(timer);
      resolve(value);
    }, (error: Error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

export enum VpnCommandState {
  STOPPED = 'stopped',
  STARTING = 'starting',
  NEEDS_LOGIN = 'needs_login',
  RUNNING = 'running',
  STOPPING = 'stopping',
  TIMED_OUT = 'timed_out'
}

export enum VpnCoreCommand {
  CONNECT = 'connect',
  LOGIN = 'login',
  DISCONNECT = 'disconnect'
}

/**
 * Single owner for core VPN command generations. UI lifecycle invalidation
 * rejects late Promise completions without changing the VPN's own lifecycle.
 */
export class VpnCommandStateMachine {
  private lifecycleGeneration: number = 0;
  private activeCommandId: number = 0;
  private timedOutCommandId: number = 0;
  private nextCommandId: number = 1;
  private state: VpnCommandState = VpnCommandState.STOPPED;

  begin(command: VpnCoreCommand): number {
    if (this.activeCommandId > 0) {
      return 0;
    }
    this.timedOutCommandId = 0;
    this.activeCommandId = this.nextCommandId++;
    if (command === VpnCoreCommand.CONNECT) {
      this.state = VpnCommandState.STARTING;
    } else if (command === VpnCoreCommand.LOGIN) {
      this.state = VpnCommandState.NEEDS_LOGIN;
    } else {
      this.state = VpnCommandState.STOPPING;
    }
    return this.activeCommandId;
  }

  isActive(commandId: number): boolean {
    return commandId > 0 && commandId === this.activeCommandId;
  }

  isTimedOut(commandId: number): boolean {
    return commandId > 0 && commandId === this.timedOutCommandId;
  }

  complete(commandId: number, state: VpnCommandState): boolean {
    if (this.isActive(commandId)) {
      this.activeCommandId = 0;
    } else if (this.isTimedOut(commandId)) {
      this.timedOutCommandId = 0;
    } else {
      return false;
    }
    this.state = state;
    return true;
  }

  timeout(commandId: number): boolean {
    if (!this.isActive(commandId)) {
      return false;
    }
    this.activeCommandId = 0;
    this.timedOutCommandId = commandId;
    this.state = VpnCommandState.TIMED_OUT;
    return true;
  }

  invalidateLifecycle(): void {
    this.lifecycleGeneration++;
    this.activeCommandId = 0;
    this.timedOutCommandId = 0;
    this.state = VpnCommandState.STOPPED;
  }

  currentState(): VpnCommandState {
    return this.state;
  }

  currentLifecycleGeneration(): number {
    return this.lifecycleGeneration;
  }
}

/** Owns M4A Native, VPN Extension, and command-file IPC operations. */
export class VpnCommandGateway {
  private writeTextFile(path: string, content: string): boolean {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
      return true;
    } catch (_error) {
      return false;
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (_closeError) {
          // A failed write may already have closed the descriptor.
        }
      }
    }
  }

  startBackend(stateDir: string, deviceModel: string, osVersion: string, controlUrl: string): string {
    return nativeBridge.backendStart(stateDir, deviceModel, osVersion, controlUrl);
  }

  async stopBackend(): Promise<string> {
    return await nativeBridge.backendStopAsync();
  }

  backendStatus(): string {
    return nativeBridge.backendStatus();
  }

  async requestBackendStatus(): Promise<string> {
    return await awaitVpnOperation(nativeBridge.backendStatusAsync(), 'backend status request');
  }

  async requestVpnConfig(): Promise<string> {
    return await awaitVpnOperation(nativeBridge.backendVpnConfigAsync(), 'VPN config request');
  }

  async requestLoginUrl(): Promise<string> {
    return await nativeBridge.backendAuthURLAsync();
  }

  async startVpnExtension(want: Want): Promise<void> {
    await vpnExtension.startVpnExtensionAbility(want);
  }

  async stopVpnExtension(want: Want): Promise<void> {
    await awaitVpnOperation(vpnExtension.stopVpnExtensionAbility(want).then(() => 'OK'),
      'VPN Extension stop');
  }

  stageConnectConfig(filesDir: string, fileName: string, config: string): boolean {
    const path: string = `${filesDir}/${fileName}`;
    const temporaryPath: string = `${path}.tmp`;
    const handoff: VpnConnectConfigHandoff = { createdAtMs: Date.now(), config: config };
    try {
      if (!this.writeTextFile(temporaryPath, JSON.stringify(handoff))) {
        return false;
      }
      fileIo.renameSync(temporaryPath, path);
      return true;
    } catch (_error) {
      try {
        if (fileIo.accessSync(temporaryPath)) {
          fileIo.unlinkSync(temporaryPath);
        }
      } catch (_cleanupError) {
        // The next command replaces a leftover temporary handoff.
      }
      return false;
    }
  }

  readConnectConfig(filesDir: string, fileName: string): VpnConnectConfigHandoff | undefined {
    try {
      const path: string = `${filesDir}/${fileName}`;
      if (!fileIo.accessSync(path)) {
        return undefined;
      }
      return JSON.parse(fileIo.readTextSync(path)) as VpnConnectConfigHandoff;
    } catch (_error) {
      return undefined;
    }
  }

  writeCommandFile(filesDir: string, fileName: string, content: string): boolean {
    return this.writeTextFile(`${filesDir}/${fileName}`, content);
  }

  readCommandFile(filesDir: string, fileName: string): string | undefined {
    try {
      const path: string = `${filesDir}/${fileName}`;
      if (!fileIo.accessSync(path)) {
        return undefined;
      }
      return fileIo.readTextSync(path);
    } catch (_error) {
      return undefined;
    }
  }
}

export interface VpnConnectConfigHandoff {
  createdAtMs: number;
  config: string;
}
