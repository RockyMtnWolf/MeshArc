import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');

function method(name) {
  const start = source.indexOf(`  private ${name}(`);
  const nextMethod = source.indexOf('\n  private ', start + 1);
  const end = nextMethod < 0 ? source.length : nextMethod;
  assert.ok(start >= 0 && end > start);
  return source.slice(start, end);
}

const javascript = stripTypeScriptTypes(`class HomeStatusHarness {
${method('isConnected')}
${method('meshConnected')}
${method('connectionTitle')}
${method('connectionDescription')}
${method('connectionColor')}
${method('peerEffectivelyOnline')}
${method('peerCardStatus')}
${method('refreshHomeLatency')}
${method('autoProbeConnectedPeerServices')}
${method('refreshUserspaceModeFromNative')}
}
globalThis.Harness = HomeStatusHarness;`);
const storage = new Map();
const sandbox = {
  $r: (key) => key,
  AppStorage: { setOrCreate: (key, value) => storage.set(key, value) },
  USERSPACE_MODE_STATUS_SYNC_INTERVAL_MS: 3000
};
vm.runInNewContext(javascript, sandbox);

function fixture({ clashActive, vpnRunning, backendRunning }) {
  const harness = new sandbox.Harness();
  harness.clashUserspaceActive = clashActive;
  harness.vpnStatus = vpnRunning ? 'OK | state=Running | tun=true' : 'HarmonyOS VPN Extension Stopped';
  harness.vpnHeartbeatConfirmed = vpnRunning;
  harness.backendStatus = backendRunning ? 'state=Running' : 'Tailscale Backend Stopped';
  harness.controlServerConfirmed = true;
  harness.accountSummary = { keyExpired: false };
  harness.isBackendLoading = () => false;
  harness.deviceNeedsApproval = () => false;
  harness.isConnecting = () => false;
  harness.hasConnectionProblem = () => false;
  harness.needsLogin = () => false;
  harness.peers = [];
  harness.autoProbedPeerSessions = new Map();
  harness.peerServiceRefreshInFlight = new Set();
  harness.trafficSession = 0;
  return harness;
}

test('userspace mode uses its backend while system VPN uses the confirmed extension tunnel', () => {
  assert.match(source, /@StorageLink\('clashUserspaceActive'\)/);
  const userspace = fixture({ clashActive: true, vpnRunning: false, backendRunning: true });
  assert.equal(userspace.isConnected(), false);
  assert.equal(userspace.meshConnected(), true);
  assert.equal(userspace.connectionTitle(), 'app.string.connection_connected');
  assert.equal(userspace.connectionDescription(), '用户态共存模式 · 系统 VPN 未启用');
  assert.equal(userspace.connectionColor(), 'app.color.status_success');

  const systemVpn = fixture({ clashActive: false, vpnRunning: true, backendRunning: true });
  assert.equal(systemVpn.isConnected(), true);
  assert.equal(systemVpn.meshConnected(), true);
  assert.equal(systemVpn.connectionTitle(), 'app.string.connection_connected');
  assert.equal(systemVpn.connectionDescription(), '系统 VPN 模式');
});

test('backend-down and mode-off never report mesh connected or count the local device online', () => {
  const harness = fixture({ clashActive: true, vpnRunning: false, backendRunning: false });
  assert.equal(harness.meshConnected(), false);
  assert.equal(harness.connectionTitle(), 'app.string.connection_disconnected');

  harness.clashUserspaceActive = false;
  assert.equal(harness.meshConnected(), false);
  assert.equal(harness.isConnected(), false);

  const laggingBackend = fixture({ clashActive: false, vpnRunning: true, backendRunning: false });
  assert.equal(laggingBackend.isConnected(), true);
  assert.equal(laggingBackend.meshConnected(), true);
  assert.equal(laggingBackend.connectionTitle(), 'app.string.connection_connected');
});

test('online peer presence remains online when path is unprobed, never falsely direct or waiting for VPN', () => {
  const harness = fixture({ clashActive: true, vpnRunning: false, backendRunning: true });
  const peer = { online: true, key: 'peer-a' };
  harness.streamingState = () => ({ checking: false, path: { checkedAt: 0, type: 'unknown' } });
  harness.peerEffectivelyOnline = (item) => item.online;
  assert.equal(harness.peerCardStatus(peer), 'app.string.peer_online');

  harness.streamingState = () => ({ checking: false, path: { checkedAt: 1, type: 'direct', latencyMs: 8 } });
  assert.equal(harness.peerCardStatus(peer), 'app.string.device_path_direct');
  assert.equal(harness.peerCardStatus({ online: false, key: 'peer-b' }), 'app.string.peer_offline');
});

test('home latency and automatic read-only peer probes use userspace mode without VPN status', async () => {
  const harness = fixture({ clashActive: true, vpnRunning: false, backendRunning: true });
  const peer = { online: true, key: 'peer-a', addresses: ['100.64.0.1'] };
  harness.peers = [peer];
  harness.appShellReady = true;
  harness.lifecycleGeneration = 9;
  harness.refreshPeerSnapshot = () => {};
  harness.ensureStreamingServices = () => {};
  harness.homeLatencyRefreshInFlight = false;
  harness.streamingState = () => ({ path: { checkedAt: 0, type: 'unknown' } });
  harness.copyStreamingState = (_state, _sunshine, path) => ({ path });
  const pathResult = { checkedAt: 3, type: 'direct', latencyMs: 12 };
  let latencyProbes = 0;
  harness.peerPathService = { probe: async () => { latencyProbes++; return pathResult; } };
  harness.updateStreamingState = () => {};
  harness.refreshHomeLatency();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(latencyProbes, 1);

  let serviceProbes = 0;
  harness.refreshPeerServices = () => { serviceProbes++; };
  harness.autoProbeConnectedPeerServices();
  assert.equal(serviceProbes, 1);
});

test('native userspace status periodically refreshes AppStorage without requiring settings to stay mounted', async () => {
  const harness = fixture({ clashActive: false, vpnRunning: false, backendRunning: true });
  harness.lifecycleGeneration = 7;
  harness.userspaceModeStatusSyncInFlight = false;
  harness.lastUserspaceModeStatusSyncAtMs = 0;
  harness.homeReadOnlyGateway = { readUserspaceModeActive: async () => true };
  storage.clear();

  harness.refreshUserspaceModeFromNative();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(harness.clashUserspaceActive, true);
  assert.equal(storage.get('clashUserspaceActive'), true);
  assert.match(source, /this\.refreshUserspaceModeFromNative\(\);\s*const vpnIsLive/);
  assert.match(source, /vpnIsLive \? this\.refreshBackendStatus\(\)/);
});

test('system VPN predicate remains tied exclusively to its extension status', () => {
  const harness = fixture({ clashActive: true, vpnRunning: false, backendRunning: true });
  assert.equal(harness.isConnected(), false);
  harness.vpnStatus = 'OK | state=Running | tun=true';
  harness.vpnHeartbeatConfirmed = true;
  harness.backendStatus = 'Tailscale Backend Stopped';
  assert.equal(harness.isConnected(), true);
  assert.equal(harness.meshConnected(), false);
});

test('backend Running alone is not system VPN, and extension confirmation requires a live heartbeat and TUN', () => {
  const backendOnly = fixture({ clashActive: false, vpnRunning: false, backendRunning: true });
  backendOnly.vpnStatus = 'OK | state=Running | tun=true';
  backendOnly.vpnHeartbeatConfirmed = false;
  assert.equal(backendOnly.isConnected(), false);
  assert.equal(backendOnly.meshConnected(), false);

  const missingTun = fixture({ clashActive: false, vpnRunning: true, backendRunning: true });
  missingTun.vpnStatus = 'OK | state=Running | tun=false';
  assert.equal(missingTun.isConnected(), false);
  assert.equal(missingTun.meshConnected(), false);
});

test('local device card passes one reactive state object to dot, label, and font', () => {
  const localRowStart = source.indexOf('private LocalDeviceRow($$: LocalDeviceConnectionState)');
  const localRowEnd = source.indexOf('\n  @Builder', localRowStart + 1);
  const localRow = source.slice(localRowStart, localRowEnd);
  assert.match(localRow,
    /backgroundColor\(\$\$\.connected \? \$r\('app\.color\.status_success'\) :\s*\$r\('sys\.color\.icon_secondary'\)\)/);
  assert.match(localRow,
    /Text\(\$\$\.connected \? \$r\('app\.string\.connection_connected'\) :\s*\$r\('app\.string\.connection_disconnected'\)\)/);
  assert.match(localRow, /fontColor\(\$\$\.connected \? \$r\('app\.color\.status_success'\)/);
  assert.doesNotMatch(localRow, /this\.meshConnected\(\)/);

  const panelStart = source.indexOf('private DevicesPanel()');
  const panelEnd = source.indexOf('\n  @Builder', panelStart + 1);
  const panel = source.slice(panelStart, panelEnd);
  assert.match(panel, /this\.LocalDeviceRow\(\{\s*connected:\s*this\.clashUserspaceActive\s*\?/);
  assert.match(panel,
    /this\.backendStatus\.includes\('state=Running'\)[\s\S]*this\.vpnHeartbeatConfirmed && this\.vpnStatus\.includes\('state=Running'\) &&\s*this\.vpnStatus\.includes\('tun=true'\)/);
  assert.doesNotMatch(panel, /const\s+\w+\s*=\s*this\.clashUserspaceActive/);
  assert.doesNotMatch(localRow, /localDeviceCardStatus\(/);
});

test('first heartbeat confirmation invalidates an initially disconnected local card', () => {
  assert.match(source, /@State private vpnHeartbeatConfirmed: boolean = false;/);
  const harness = fixture({ clashActive: false, vpnRunning: true, backendRunning: false });
  let confirmed = false;
  const dependencies = new Set();
  Object.defineProperty(harness, 'vpnHeartbeatConfirmed', {
    get() {
      dependencies.add('vpnHeartbeatConfirmed');
      return confirmed;
    }
  });
  assert.equal(harness.meshConnected(), false);
  assert.ok(dependencies.has('vpnHeartbeatConfirmed'));
  confirmed = true;
  assert.equal(harness.meshConnected(), true);
  assert.equal(harness.connectionTitle(), 'app.string.connection_connected');
  confirmed = false;
  assert.equal(harness.meshConnected(), false);
  assert.equal(harness.connectionTitle(), 'app.string.connection_disconnected');
});

test('update-log popup and settings entry are absent while core update actions remain', () => {
  assert.doesNotMatch(source, /showUpdateChangelogIfNeeded|update-changelog-settings-action|updateChangelogVisible/);
  assert.match(source, /CoreUpdateSettings\(/);
});
