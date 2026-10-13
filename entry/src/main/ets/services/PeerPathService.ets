import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { ConnectionPathType, PeerPathResult } from './StreamingModels';
import nativeBridge from 'libtailscale_ohos.so';
import { awaitVpnOperation } from './VpnCommandGateway';

const REQUEST_FILE: string = 'peer-connectivity-request.json';
const RESPONSE_FILE: string = 'peer-connectivity-response.json';
const CACHE_TTL_MS: number = 25000;
// Native discovery has a shared ten-second budget including status lookup.
const TIMEOUT_MS: number = 12000;
const TRANSIENT_CACHE_TTL_MS: number = 3000;

interface PeerPathResponse {
  requestId: number;
  result: string;
}

interface NativePeerPathResult {
  state: string;
  reason: string;
  pathType?: string;
  latencyMs?: number;
  relayRegion?: string;
}

export class PeerPathService {
  private readonly cache: Map<string, PeerPathResult> = new Map();
  private readonly requestIds: Map<string, number> = new Map();
  private readonly context: common.UIAbilityContext;
  private queue: Promise<void> = Promise.resolve();
  private lastExtensionRequestId: number = 0;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  clearCache(peerKey?: string): void {
    if (peerKey === undefined) {
      this.cache.clear();
      return;
    }
    this.cache.delete(peerKey);
  }

  cancel(peerKey: string): void {
    this.requestIds.set(peerKey, (this.requestIds.get(peerKey) ?? 0) + 1);
  }

  async probe(peerKey: string, vpnConnected: boolean, force: boolean = false,
    userspace: boolean = false): Promise<PeerPathResult> {
    return this.enqueue(() => this.probeInternal(peerKey, vpnConnected, force, userspace));
  }

  private async probeInternal(peerKey: string, vpnConnected: boolean, force: boolean,
    userspace: boolean): Promise<PeerPathResult> {
    const cached: PeerPathResult | undefined = this.cache.get(peerKey);
    if (!vpnConnected) {
      this.cache.delete(peerKey);
      return { type: 'unknown', checkedAt: Date.now(), errorMessage: 'mesh_disconnected' };
    }
    if (!force && cached !== undefined && Date.now() - cached.checkedAt <
      (cached.type === 'direct' ? CACHE_TTL_MS : TRANSIENT_CACHE_TTL_MS)) {
      return cached;
    }
    const requestGeneration: number = (this.requestIds.get(peerKey) ?? 0) + 1;
    this.requestIds.set(peerKey, requestGeneration);
    let resultText: string;
    try {
      resultText = userspace ? await awaitVpnOperation(nativeBridge.backendPeerConnectivityAsync(peerKey),
        'userspace peer path', TIMEOUT_MS) : await this.requestThroughVpnExtension(
        peerKey, this.nextExtensionRequestId());
    } catch (_error) {
      resultText = '{"state":"failed","reason":"probe_error"}';
    }
    if (this.requestIds.get(peerKey) !== requestGeneration) {
      return { type: 'unknown', checkedAt: Date.now(), errorMessage: 'cancelled' };
    }
    const parsed: PeerPathResult = this.parse(resultText);
    this.cache.set(peerKey, parsed);
    return parsed;
  }

  private enqueue(task: () => Promise<PeerPathResult>): Promise<PeerPathResult> {
    let release: () => void = () => {};
    const previous: Promise<void> = this.queue;
    this.queue = new Promise<void>((resolve: () => void) => { release = resolve; });
    return previous.then(task).finally(() => release());
  }

  private nextExtensionRequestId(): number {
    this.lastExtensionRequestId = Math.max(Date.now(), this.lastExtensionRequestId + 1);
    return this.lastExtensionRequestId;
  }

  private async requestThroughVpnExtension(peerKey: string, requestId: number): Promise<string> {
    const responsePath: string = `${this.context.filesDir}/${RESPONSE_FILE}`;
    const requestPath: string = `${this.context.filesDir}/${REQUEST_FILE}`;
    try {
      this.writeText(responsePath, '');
      if (!this.writeText(requestPath, JSON.stringify({ requestId: requestId, peerKey: peerKey }))) {
        return '{"state":"failed","reason":"extension_error"}';
      }
      const startedAt: number = Date.now();
      while (Date.now() - startedAt < TIMEOUT_MS) {
        await new Promise<void>((resolve: () => void) => setTimeout(resolve, 150));
        if (!fileIo.accessSync(responsePath)) {
          continue;
        }
        const responseText: string = fileIo.readTextSync(responsePath).trim();
        if (responseText.length === 0) {
          continue;
        }
        const response: PeerPathResponse = JSON.parse(responseText) as PeerPathResponse;
        if (response.requestId !== requestId) {
          continue;
        }
        this.writeText(responsePath, '');
        return response.result;
      }
      return '{"state":"failed","reason":"timeout"}';
    } catch (_error) {
      return '{"state":"failed","reason":"extension_error"}';
    }
  }

  private parse(text: string): PeerPathResult {
    try {
      const result: NativePeerPathResult = JSON.parse(text) as NativePeerPathResult;
      const checkedAt: number = Date.now();
      if (result.state !== 'reachable' && result.state !== 'degraded') {
        const unreachable: boolean = result.reason === 'no_response' || result.reason === 'peer_offline' ||
          result.reason === 'peer_not_found';
        return {
          type: unreachable ? 'unreachable' : 'unknown',
          checkedAt: checkedAt,
          errorMessage: result.reason
        };
      }
      return {
        type: this.pathType(result.pathType),
        latencyMs: result.latencyMs,
        relayRegion: result.relayRegion,
        checkedAt: checkedAt
      };
    } catch (_error) {
      return { type: 'unknown', checkedAt: Date.now(), errorMessage: 'invalid_result' };
    }
  }

  private pathType(value?: string): ConnectionPathType {
    if (value === 'direct' || value === 'peerRelay' || value === 'derp' || value === 'unreachable') {
      return value;
    }
    return 'unknown';
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
}
