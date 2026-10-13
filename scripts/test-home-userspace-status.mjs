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
${method('localDeviceCardStatus')}
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
  harness.vpnStatus = vpnRunning ? 'state=Running' : 'HarmonyOS VPN Extension Stopped';
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

test('userspace and system VPN modes both display connected only with a running backend', () => {
  assert.match(source, /@StorageLink\('clashUserspaceActive'\)/);
  const userspace = fixture({ clashActive: true, vpnRunning: false, backendRunning: true });
  assert.equal(userspace.isConnected(), false);
  assert.equal(userspace.meshConnected(), true);
  assert.equal(userspace.connectionTitle(), 'app.string.connection_connected');
  assert.equal(userspace.connectionDescription(), '用户态共存模式 · 系统 VPN 未启用');
  assert.equal(userspace.connectionColor(), 'app.color.status_success');
  assert.equal(userspace.localDeviceCardStatus(), 'app.string.connection_connected');

  const systemVpn = fixture({ clashActive: false, vpnRunning: true, backendRunning: true });
  assert.equal(systemVpn.isConnected(), true);
  assert.equal(systemVpn.meshConnected(), true);
  assert.equal(systemVpn.connectionTitle(), 'app.string.connection_connected');
  assert.equal(systemVpn.connectionDescription(), '系统 VPN 模式');
  assert.equal(systemVpn.localDeviceCardStatus(), 'app.string.connection_connected');
});

test('backend-down and mode-off never report mesh connected or count the local device online', () => {
  const harness = fixture({ clashActive: true, vpnRunning: false, backendRunning: false });
  assert.equal(harness.meshConnected(), false);
  assert.equal(harness.connectionTitle(), 'app.string.connection_disconnected');
  assert.equal(harness.localDeviceCardStatus(), 'app.string.connection_disconnected');

  harness.clashUserspaceActive = false;
  assert.equal(harness.meshConnected(), false);
  assert.equal(harness.isConnected(), false);

  const staleBackend = fixture({ clashActive: false, vpnRunning: true, backendRunning: false });
  assert.equal(staleBackend.isConnected(), true);
  assert.equal(staleBackend.meshConnected(), false);
  assert.equal(staleBackend.connectionTitle(), 'app.string.connection_disconnected');
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
  harness.vpnStatus = 'state=Running';
  harness.backendStatus = 'Tailscale Backend Stopped';
  assert.equal(harness.isConnected(), true);
  assert.equal(harness.meshConnected(), false);
});

test('update-log popup and settings entry are absent while core update actions remain', () => {
  assert.doesNotMatch(source, /showUpdateChangelogIfNeeded|update-changelog-settings-action|updateChangelogVisible/);
  assert.match(source, /CoreUpdateSettings\(/);
});
