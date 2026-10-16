import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import nativeBridge from 'libtailscale_ohos.so';
import { awaitVpnOperation } from './VpnCommandGateway';

export const INBOUND_TCP_OWNER_FILE: string = 'inbound-tcp-owner.json';
export const INBOUND_TCP_REQUEST_FILE: string = 'inbound-tcp-request.json';
export const INBOUND_TCP_RESPONSE_FILE: string = 'inbound-tcp-response.json';

const VPN_PROBE_STATUS_FILE: string = 'vpn-probe-status.txt';
const HEARTBEAT_FRESHNESS_MS: number = 2500;
const RPC_TIMEOUT_MS: number = 12000;
const RPC_EXPIRY_MS: number = 10000;
const RPC_POLL_INTERVAL_MS: number = 100;
const OWNER_READ_ATTEMPTS: number = 6;
const OWNER_READ_RETRY_MS: number = 50;

let lastInboundTCPRequestId: number = 0;

function nextInboundTCPRequestId(): number {
  lastInboundTCPRequestId = Math.max(Date.now(), lastInboundTCPRequestId + 1);
  return lastInboundTCPRequestId;
}

export interface InboundTCPOwnerSession {
  ownerSession: string;
  createdAtMs: number;
  heartbeatMs: number;
  tun: boolean;
  valid: boolean;
}

export interface InboundTCPRpcRequest {
  ownerSession: string;
  requestId: number;
  expiresAtMs: number;
  operation: string;
  payload: string;
}

export interface InboundTCPRpcResponse {
  ownerSession: string;
  requestId: number;
  result: string;
  error: string;
}

export interface InboundTCPRpcDecision {
  kind: string;
  request?: InboundTCPRpcRequest;
  response?: InboundTCPRpcResponse;
}

export interface InboundTCPGatewayStatus {
  raw: string;
  userspace: boolean;
}

export class InboundTCPRpcProtocol {
  private readonly ownerSession: string;
  private lastRequestId: number = 0;
  private lastResponse?: InboundTCPRpcResponse;

  constructor(ownerSession: string) {
    this.ownerSession = ownerSession;
  }

  evaluate(requestText: string, currentOwnerSession: string, now: number): InboundTCPRpcDecision {
    if (currentOwnerSession !== this.ownerSession) {
      return { kind: 'owner_changed' };
    }
    let request: InboundTCPRpcRequest;
    try {
      request = JSON.parse(requestText) as InboundTCPRpcRequest;
    } catch (_error) {
      return { kind: 'invalid' };
    }
    if (request.ownerSession !== this.ownerSession || !Number.isSafeInteger(request.requestId) ||
      request.requestId <= 0 || !Number.isFinite(request.expiresAtMs) ||
      (request.operation !== 'status' && request.operation !== 'setPolicy') ||
      typeof request.payload !== 'string') {
      return { kind: 'invalid' };
    }
    if (request.expiresAtMs <= now) {
      this.lastRequestId = Math.max(this.lastRequestId, request.requestId);
      this.lastResponse = {
        ownerSession: this.ownerSession,
        requestId: request.requestId,
        result: '',
        error: '入站策略请求已过期。'
      };
      return { kind: 'expired', request: request };
    }
    if (request.requestId === this.lastRequestId && this.lastResponse !== undefined) {
      return { kind: 'duplicate', request: request, response: this.lastResponse };
    }
    if (request.requestId <= this.lastRequestId) {
      return { kind: 'stale', request: request };
    }
    return { kind: 'process', request: request };
  }

  complete(request: InboundTCPRpcRequest, result: string, error: string): InboundTCPRpcResponse | undefined {
    if (request.ownerSession !== this.ownerSession || request.requestId <= this.lastRequestId) {
      return undefined;
    }
    const response: InboundTCPRpcResponse = {
      ownerSession: this.ownerSession,
      requestId: request.requestId,
      result: result,
      error: error
    };
    this.lastRequestId = request.requestId;
    this.lastResponse = response;
    return response;
  }
}

export class InboundTCPGateway {
  private readonly context: common.UIAbilityContext;
  private queue: Promise<void> = Promise.resolve();

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async readStatus(): Promise<InboundTCPGatewayStatus> {
    return this.enqueue(() => this.readStatusInternal());
  }

  async setPolicy(allowAll: boolean, ports: number[]): Promise<InboundTCPGatewayStatus> {
    return this.enqueue(() => this.setPolicyInternal(allowAll, ports));
  }

  private async readStatusInternal(): Promise<InboundTCPGatewayStatus> {
    const route: boolean = this.selectUserspaceRoute();
    const raw: string = route ? await awaitVpnOperation(nativeBridge.coexistenceStatusAsync(),
      'userspace inbound TCP status', RPC_TIMEOUT_MS) :
      await this.requestVpnExtension('status', '');
    return { raw: raw, userspace: route };
  }

  private async setPolicyInternal(allowAll: boolean, ports: number[]): Promise<InboundTCPGatewayStatus> {
    const route: boolean = this.selectUserspaceRoute();
    const payload: string = JSON.stringify({ allowAll: allowAll, ports: ports });
    const raw: string = route ? await awaitVpnOperation(
      nativeBridge.coexistenceSetInboundTCPPolicyAsync(payload), 'userspace inbound TCP policy', RPC_TIMEOUT_MS) :
      await this.requestVpnExtension('setPolicy', payload);
    return { raw: raw, userspace: route };
  }

  private selectUserspaceRoute(): boolean {
    const owner: InboundTCPOwnerSession | undefined = this.readOwnerSession();
    if (owner !== undefined && owner.valid) {
      const ageMs: number = Date.now() - owner.heartbeatMs;
      if (owner.tun && ageMs >= 0 && ageMs <= HEARTBEAT_FRESHNESS_MS) {
        return false;
      }
      if (!owner.tun && ageMs >= 0 && ageMs <= HEARTBEAT_FRESHNESS_MS) {
        throw new Error('系统 VPN 扩展仍持有当前会话，但 TUN 尚未就绪；入站策略未更改。');
      }
      throw new Error('系统 VPN 后端心跳已超时。请断开并重新连接本应用系统 VPN 后重试；当前未改写用户态策略。');
    }
    const statusPath: string = `${this.context.filesDir}/${VPN_PROBE_STATUS_FILE}`;
    let statusText: string = '';
    try {
      if (fileIo.accessSync(statusPath)) {
        statusText = fileIo.readTextSync(statusPath).trim();
      }
    } catch (_error) {
      statusText = '';
    }
    const heartbeatMatch: RegExpMatchArray | null = statusText.match(/heartbeatMs=(\d+)/);
    const heartbeatMs: number = heartbeatMatch === null ? 0 : Number(heartbeatMatch[1]);
    const fresh: boolean = heartbeatMs > 0 && Date.now() >= heartbeatMs &&
      Date.now() - heartbeatMs <= HEARTBEAT_FRESHNESS_MS;
    if (owner !== undefined && !owner.valid && fresh && statusText.includes('tun=true')) {
      throw new Error('系统 VPN 扩展正在切换会话，入站策略未更改。');
    }
    if (fresh && statusText.includes('tun=true')) {
      return false;
    }
    if (fresh && !statusText.includes('VPN extension destroyed')) {
      throw new Error('系统 VPN 正在运行但 TUN 尚未就绪，入站策略未更改。');
    }
    return true;
  }

  private async requestVpnExtension(operation: string, payload: string): Promise<string> {
    const requestPath: string = `${this.context.filesDir}/${INBOUND_TCP_REQUEST_FILE}`;
    const responsePath: string = `${this.context.filesDir}/${INBOUND_TCP_RESPONSE_FILE}`;
    const owner: InboundTCPOwnerSession = await this.readOwnerSessionWithRetry();
    if (!owner.valid || owner.ownerSession.length === 0) {
      throw new Error('系统 VPN 扩展当前不可用，入站策略未更改。');
    }
    const requestId: number = nextInboundTCPRequestId();
    const request: InboundTCPRpcRequest = {
      ownerSession: owner.ownerSession,
      requestId: requestId,
      expiresAtMs: Date.now() + RPC_EXPIRY_MS,
      operation: operation,
      payload: payload
    };
    if (!this.writeAtomicText(responsePath, '') || !this.writeAtomicText(requestPath, JSON.stringify(request))) {
      throw new Error('无法提交系统 VPN 入站策略请求。');
    }
    const startedAt: number = Date.now();
    while (Date.now() - startedAt < RPC_TIMEOUT_MS) {
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, RPC_POLL_INTERVAL_MS));
      let currentOwner: InboundTCPOwnerSession | undefined;
      try {
        currentOwner = this.readOwnerSession();
      } catch (_error) {
        continue;
      }
      if (currentOwner === undefined || !currentOwner.valid || currentOwner.ownerSession !== request.ownerSession) {
        throw new Error('系统 VPN 扩展进程已切换，请刷新状态后重试。');
      }
      const responseText: string = this.readText(responsePath).trim();
      if (responseText.length === 0) {
        continue;
      }
      let response: InboundTCPRpcResponse;
      try {
        response = JSON.parse(responseText) as InboundTCPRpcResponse;
      } catch (_error) {
        continue;
      }
      if (response.ownerSession !== request.ownerSession || response.requestId !== request.requestId) {
        continue;
      }
      this.writeAtomicText(responsePath, '');
      if (response.error.length > 0) {
        throw new Error(response.error);
      }
      return response.result;
    }
    throw new Error('等待系统 VPN 入站策略响应超时。');
  }

  private enqueue<T>(task: () => Promise<T>): Promise<T> {
    let release: () => void = () => {};
    const previous: Promise<void> = this.queue;
    this.queue = new Promise<void>((resolve: () => void) => { release = resolve; });
    return previous.then(task).finally(() => release());
  }

  private readOwnerSession(): InboundTCPOwnerSession | undefined {
    const ownerPath: string = `${this.context.filesDir}/${INBOUND_TCP_OWNER_FILE}`;
    if (!fileIo.accessSync(ownerPath)) {
      return undefined;
    }
    const owner: InboundTCPOwnerSession = JSON.parse(fileIo.readTextSync(ownerPath)) as InboundTCPOwnerSession;
    if (typeof owner.ownerSession !== 'string' || typeof owner.valid !== 'boolean' ||
      typeof owner.tun !== 'boolean' || !Number.isFinite(owner.heartbeatMs)) {
      throw new Error('系统 VPN owner 状态格式无效，请刷新后重试。');
    }
    return owner;
  }

  private async readOwnerSessionWithRetry(): Promise<InboundTCPOwnerSession> {
    for (let attempt: number = 0; attempt < OWNER_READ_ATTEMPTS; attempt++) {
      try {
        const owner: InboundTCPOwnerSession | undefined = this.readOwnerSession();
        if (owner !== undefined) {
          return owner;
        }
      } catch (_error) {
      }
      await new Promise<void>((resolve: () => void) => setTimeout(resolve, OWNER_READ_RETRY_MS));
    }
    throw new Error('系统 VPN 扩展 owner 状态暂不可读，请重试。');
  }

  private readText(path: string): string {
    try {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      return fileIo.readTextSync(path);
    } catch (_error) {
      return '';
    }
  }

  private writeText(path: string, content: string): boolean {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
      return true;
    } catch (_error) {
      return false;
    } finally {
      if (file !== undefined) {
        try { fileIo.closeSync(file); } catch (_error) {}
      }
    }
  }

  private writeAtomicText(path: string, content: string): boolean {
    const temporaryPath: string = `${path}.tmp`;
    if (!this.writeText(temporaryPath, content)) {
      return false;
    }
    try {
      fileIo.renameSync(temporaryPath, path);
      return true;
    } catch (_error) {
      try {
        if (fileIo.accessSync(temporaryPath)) {
          fileIo.unlinkSync(temporaryPath);
        }
      } catch (_cleanupError) {
      }
      return false;
    }
  }
}
