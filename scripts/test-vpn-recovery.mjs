import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');
function method(name, next) {
  const start = source.indexOf(`  private ${name}(`);
  const end = source.indexOf(`\n  private ${next}(`, start);
  assert.ok(start >= 0 && end > start);
  return source.slice(start, end);
}
const sandbox = {
  AppStorage: { get: () => false },
  Date: { now: () => 1000000 },
  fileIo: { accessSync: () => true, readTextSync: () => 'VPN backend starting | heartbeatMs=1000' },
  VpnCoreCommand: { CONNECT: 'connect' },
  VPN_HEARTBEAT_FRESH_MS: 15000,
  VPN_HEARTBEAT_CONFIRM_TIMEOUT_MS: 5000,
  VPN_CONNECT_TIMEOUT_MS: 90000,
  MIN_CONNECTION_LOADING_MS: 1000
};
const javascript = stripTypeScriptTypes(`class RecoveryHarness {
${method('beginVpnConnection', 'async beginVpnConnectionAfterExitNodeUpdate')}
${method('refreshVpnProbeStatus', 'clearVpnBackendHandoffFiles')}
}
globalThis.Harness = RecoveryHarness;`);
vm.runInNewContext(javascript, sandbox);

function fixture() {
  const harness = new sandbox.Harness();
  harness.controlServerConfirmed = true;
  harness.connectInProgress = false;
  harness.disconnectInProgress = false;
  harness.vpnStatus = 'VPN backend starting';
  harness.vpnHeartbeatConfirmed = false;
  harness.getUIContext = () => ({ getHostContext: () => ({ filesDir: '/files' }) });
  harness.preserveConfirmedVpnStatus = () => false;
  harness.processVpnBackendHandoffRequest = () => {};
  harness.resetTrafficMetrics = () => {};
  harness.resetTaildropSnapshot = () => {};
  harness.resetStreamingStatesForDisconnect = () => {};
  harness.syncHomeTitleCompact = () => {};
  harness.connectedHomeLayoutActive = () => false;
  harness.isConnecting = () => harness.connectInProgress || harness.vpnStatus.includes('starting');
  harness.setConnectInProgress = value => { harness.connectInProgress = value; };
  harness.beginVpnConnectionAfterExitNodeUpdate = async () => {};
  harness.scheduleLifecycleTask = (callback, delay) => { harness.deadline = callback; harness.delay = delay; };
  harness.clearConnectionCompletionTimer = () => {};
  harness.stopConnectionPolling = () => {};
  harness.recordDiagnosticEvent = () => {};
  harness.active = false;
  harness.vpnCommandStateMachine = {
    begin: () => { harness.active = true; return 1; },
    isActive: commandId => commandId === 1 && harness.active,
    timeout: () => { harness.active = false; }
  };
  return harness;
}

test('a dead extension cannot leave a persisted starting status blocking connect', () => {
  const harness = fixture();
  assert.equal(harness.refreshVpnProbeStatus(), false);
  assert.equal(harness.isConnecting(), false);
  assert.match(harness.vpnStatus, /Stopped/);
});

test('connect revalidates the stale extension and bounds the entire command', () => {
  const harness = fixture();
  harness.beginVpnConnection();
  assert.equal(harness.active, true);
  assert.equal(harness.connectInProgress, true);
  assert.equal(harness.delay, 90000);
  harness.deadline();
  assert.equal(harness.active, false);
  assert.equal(harness.connectInProgress, false);
  assert.equal(harness.vpnStatus, 'FAILED | VPN connect | timeout');
});

test('an expired deadline cannot replace a newer completed connection', () => {
  const harness = fixture();
  harness.beginVpnConnection();
  harness.active = false;
  harness.connectInProgress = false;
  harness.vpnStatus = 'state=Running | tun=true';
  harness.deadline();
  assert.equal(harness.vpnStatus, 'state=Running | tun=true');
});

test('userspace coexistence does not start a competing system VPN', () => {
  const harness = fixture();
  let prompted = false;
  harness.getUIContext = () => ({ showAlertDialog: () => { prompted = true; } });
  sandbox.AppStorage.get = () => true;
  try {
    harness.beginVpnConnection();
    assert.equal(prompted, true);
    assert.equal(harness.active, false);
  } finally {
    sandbox.AppStorage.get = () => false;
  }
});
