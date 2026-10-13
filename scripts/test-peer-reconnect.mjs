import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

// Exercise the production controller methods without loading ArkUI builders.
const source = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');
function method(name) {
  const start = source.indexOf(`  private ${name}(`);
  assert.ok(start >= 0, name);
  const end = source.indexOf('\n  }', start) + 4;
  return source.slice(start, end);
}
const methods = ['meshConnected', 'peerEffectivelyOnline', 'peerCardStatus', 'streamingState',
  'copyStreamingState', 'updateStreamingState', 'applyPeers', 'refreshHomeLatency',
  'autoProbeConnectedPeerServices'].map(method).join('\n');
const js = stripTypeScriptTypes(`class Controller { ${methods} }`);
const peer = (online = true) => ({ key: 'peer-test', online, addresses: ['100.64.0.1'] });
function fixture() {
  const sandbox = { $r: name => name };
  vm.runInNewContext(js + '\nglobalThis.Controller = Controller;', sandbox);
  const c = new sandbox.Controller();
  const invalidations = [];
  const probe = () => ({
    cancel: key => invalidations.push(`cancel:${key}`),
    clearCache: key => invalidations.push(`cache:${key}`)
  });
  Object.assign(c, {
    peers: [peer()], streamingStates: [], mediaStates: [], selectedPeerKey: '',
    streamingRequestIds: new Map(), mediaRequestIds: new Map(),
    autoProbedPeerSessions: new Map(), autoSunshineFailureCounts: new Map(),
    autoMediaFailureCounts: new Map(), peerServiceRefreshInFlight: new Set(),
    sunshineProbeService: probe(), peerPathService: probe(), mediaServiceProbeService: probe(),
    peerDataSource: { replaceAll() {} }, mergePeers: peers => peers,
    logServiceStatusIfChanged() {}, scheduleLifecycleTask() {},
    isConnected: () => true, isConnecting: () => false,
    appShellReady: true, lifecycleGeneration: 1, trafficSession: 1,
    backendStatus: 'state=Running', clashUserspaceActive: false,
    refreshPeerSnapshot() {}, ensureStreamingServices() {}
  });
  return { c, invalidations };
}
function path(c, type, checkedAt, errorMessage) {
  return c.copyStreamingState(c.streamingState('peer-test'), undefined,
    { type, checkedAt, errorMessage }, false);
}
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };

test('an online peer with a failed path probe remains online instead of being marked recovering', () => {
  const { c } = fixture();
  for (const reason of ['no_response', 'peer_offline', 'peer_not_found']) {
    c.streamingStates = [path(c, 'unreachable', 10, reason)];
    assert.equal(c.peerEffectivelyOnline(peer()), true, reason);
    assert.equal(c.peerCardStatus(peer()), 'app.string.peer_online');
  }
  assert.equal(c.peerEffectivelyOnline(peer(false)), false);
  assert.equal(c.peerCardStatus(peer(false)), 'app.string.peer_offline');
});

test('offline then online invalidates pending results and lets the same VPN session rediscover services', () => {
  const { c, invalidations } = fixture();
  c.streamingStates = [path(c, 'unreachable', 10, 'no_response')];
  c.autoProbedPeerSessions.set('peer-test', 1);
  c.streamingRequestIds.set('peer-test', 123);
  c.mediaRequestIds.set('peer-test', 123);
  c.applyPeers([peer(false)]);
  assert.equal(c.streamingRequestIds.has('peer-test'), false);
  assert.equal(c.mediaRequestIds.has('peer-test'), false);
  assert.ok(invalidations.includes('cache:peer-test'));
  c.applyPeers([peer()]);
  let probes = 0;
  c.refreshPeerServices = () => probes++;
  c.autoProbeConnectedPeerServices();
  assert.equal(probes, 1);
  assert.equal(c.peerEffectivelyOnline(c.peers[0]), true);
});

test('a busy old service request does not consume the reconnect discovery attempt', () => {
  const { c } = fixture(); let probes = 0;
  c.refreshPeerServices = () => probes++;
  c.peerServiceRefreshInFlight.add('peer-test');
  c.autoProbeConnectedPeerServices();
  assert.equal(c.autoProbedPeerSessions.has('peer-test'), false);
  c.peerServiceRefreshInFlight.clear();
  c.autoProbeConnectedPeerServices();
  assert.equal(probes, 1);
});

test('a slow service response cannot overwrite a more recent recovered path', () => {
  const { c } = fixture();
  c.updateStreamingState('peer-test', path(c, 'direct', 20));
  const old = path(c, 'unreachable', 10, 'no_response');
  old.sunshine = { state: 'available', checkedAt: 21 };
  c.updateStreamingState('peer-test', old);
  assert.equal(c.streamingState('peer-test').path.type, 'direct');
  assert.equal(c.streamingState('peer-test').sunshine.state, 'available');
});

for (const scenario of ['offline', 'new_session', 'new_lifecycle', 'cancelled', 'removed']) {
  test(`an obsolete home probe cannot reintroduce a path after ${scenario}`, async () => {
    const { c } = fixture(); let resolve;
    c.peerPathService.probe = () => new Promise(r => resolve = r);
    c.refreshHomeLatency();
    if (scenario === 'offline') c.peers = [peer(false)];
    if (scenario === 'removed') c.peers = [];
    if (scenario === 'new_session') c.trafficSession++;
    if (scenario === 'new_lifecycle') c.lifecycleGeneration++;
    resolve({ type: 'unknown', checkedAt: 10,
      errorMessage: scenario === 'cancelled' ? 'cancelled' : 'no_response' });
    await flush();
    assert.equal(c.streamingStates.length, 0);
    assert.equal(c.homeLatencyRefreshInFlight, false);
  });
}

test('home polling retries an online peer despite an old unreachable path', async () => {
  const { c } = fixture();
  c.streamingStates = [path(c, 'unreachable', 10, 'no_response')];
  c.peerPathService.probe = async () => ({ type: 'derp', checkedAt: 20 });
  c.refreshHomeLatency(); await flush();
  assert.equal(c.streamingState('peer-test').path.type, 'derp');
  assert.equal(c.peerEffectivelyOnline(peer()), true);
});
