import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/services/VpnCommandGateway.ets', import.meta.url), 'utf8');
const bridgeSource = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');
const connectMethodStart = bridgeSource.indexOf('  private async beginVpnConnectionAfterExitNodeUpdate(');
const connectMethodEnd = bridgeSource.indexOf('\n  private async startVpnProbe(', connectMethodStart);
const stopMethodStart = bridgeSource.indexOf('  private finishVpnExtensionStop(');
const stopMethodEnd = bridgeSource.indexOf('\n  private confirmLogout()', stopMethodStart);
assert.notEqual(connectMethodStart, -1);
assert.notEqual(connectMethodEnd, -1);
assert.notEqual(stopMethodStart, -1);
assert.notEqual(stopMethodEnd, -1);
const javascript = stripTypeScriptTypes(source.replace(/^import .*;\r?$/gm, '')
  .replace('VPN_OPERATION_TIMEOUT_MS: number = 8000', 'VPN_OPERATION_TIMEOUT_MS: number = 5')
  .replace(/export enum VpnCommandState \{[\s\S]*?\n\}/,
    "const VpnCommandState = { STOPPED: 'stopped', STARTING: 'starting', NEEDS_LOGIN: 'needs_login', " +
    "RUNNING: 'running', STOPPING: 'stopping', TIMED_OUT: 'timed_out' };")
  .replace(/export enum VpnCoreCommand \{[\s\S]*?\n\}/,
    "const VpnCoreCommand = { CONNECT: 'connect', LOGIN: 'login', DISCONNECT: 'disconnect' };")
  .replace('export function awaitVpnOperation', 'function awaitVpnOperation')
  .replace(/export class /g, 'class ')
  .replace(/export interface VpnConnectConfigHandoff \{[\s\S]*?\n\}/, ''));
const connectMethod = bridgeSource.slice(connectMethodStart, connectMethodEnd)
  .replace('private async beginVpnConnectionAfterExitNodeUpdate', 'async beginVpnConnectionAfterExitNodeUpdate');
const stopMethod = bridgeSource.slice(stopMethodStart, stopMethodEnd)
  .replace('private finishVpnExtensionStop', 'finishVpnExtensionStop')
  .replaceAll('VPN_EXTENSION_STOP_TIMEOUT_MS', '5');
const bridgeHarnessSource = stripTypeScriptTypes(`class BridgeHarness {\n${connectMethod}\n${stopMethod}\n}`);
const platform = {
  configPromise: Promise.resolve('config'),
  statusPromise: Promise.resolve('status'),
  stopPromise: Promise.resolve()
};
const sandbox = {
  setTimeout,
  clearTimeout,
  nativeBridge: {
    backendVpnConfigAsync: () => platform.configPromise,
    backendStatusAsync: () => platform.statusPromise,
    backendStatus: () => 'OK | state=Running'
  },
  vpnExtension: { stopVpnExtensionAbility: () => platform.stopPromise }
};
vm.runInNewContext(javascript + '\n' + bridgeHarnessSource +
  '\nglobalThis.Machine = VpnCommandStateMachine; globalThis.State = VpnCommandState; ' +
  'globalThis.Command = VpnCoreCommand; globalThis.Gateway = VpnCommandGateway; ' +
  'globalThis.awaitVpnOperation = awaitVpnOperation; globalThis.BridgeHarness = BridgeHarness;', sandbox);
const flush = async () => { for (let index = 0; index < 20; index++) await Promise.resolve(); };

function bridgeHarness() {
  const harness = new sandbox.BridgeHarness();
  harness.vpnCommandStateMachine = new sandbox.Machine();
  harness.disconnectInProgress = true;
  harness.homeTitleCompact = true;
  harness.vpnStatus = '';
  harness.events = [];
  harness.pollingStops = 0;
  harness.stopPromise = new Promise((resolve, reject) => {
    harness.resolveStop = resolve;
    harness.rejectStop = reject;
  });
  harness.vpnCommandGateway = { stopVpnExtension: () => harness.stopPromise };
  harness.vpnWant = () => ({});
  harness.stopVpnStopPolling = () => {};
  harness.setConnectInProgress = (value) => { harness.connectInProgress = value; };
  harness.recordDiagnosticEvent = (...event) => harness.events.push(event);
  harness.stopConnectionPolling = () => { harness.pollingStops++; };
  harness.deferBackendRestart = () => true;
  harness.scheduleLifecycleTask = () => {};
  return harness;
}

test('failed exit node preparation completes the active connect command', async () => {
  const harness = bridgeHarness();
  harness.controlServerConfirmed = true;
  harness.connectInProgress = true;
  harness.exitNodeStatus = 'FAILED | exit node update';
  harness.connectCommandId = harness.vpnCommandStateMachine.begin(sandbox.Command.CONNECT);
  harness.exitNodeUpdatePromise = undefined;
  harness.routeAllUpdatePromise = undefined;
  harness.exitNodeLanUpdatePromise = undefined;

  await harness.beginVpnConnectionAfterExitNodeUpdate();

  assert.equal(harness.connectInProgress, false);
  assert.equal(harness.vpnCommandStateMachine.isActive(harness.connectCommandId), false);
  assert.equal(harness.vpnCommandStateMachine.currentState(), sandbox.State.STOPPED);
});

test('only the active command can complete the current generation', () => {
  const machine = new sandbox.Machine();
  const connectId = machine.begin(sandbox.Command.CONNECT);
  assert.equal(machine.begin(sandbox.Command.DISCONNECT), 0);
  assert.equal(machine.complete(connectId, sandbox.State.RUNNING), true);

  const disconnectId = machine.begin(sandbox.Command.DISCONNECT);
  assert.equal(machine.complete(connectId, sandbox.State.STOPPED), false);
  assert.equal(machine.isActive(disconnectId), true);
  assert.equal(machine.currentState(), sandbox.State.STOPPING);
});

test('lifecycle invalidation clears a timed out command and rejects its late completion', () => {
  const machine = new sandbox.Machine();
  const commandId = machine.begin(sandbox.Command.DISCONNECT);
  assert.equal(machine.timeout(commandId), true);
  assert.equal(machine.currentState(), sandbox.State.TIMED_OUT);
  machine.invalidateLifecycle();

  assert.equal(machine.currentState(), sandbox.State.STOPPED);
  assert.equal(machine.complete(commandId, sandbox.State.STOPPED), false);
});

test('a newer command invalidates the previous timed out command ID', () => {
  const machine = new sandbox.Machine();
  const oldId = machine.begin(sandbox.Command.DISCONNECT);
  assert.equal(machine.timeout(oldId), true);
  const newId = machine.begin(sandbox.Command.CONNECT);

  assert.equal(machine.complete(oldId, sandbox.State.STOPPED), false);
  assert.equal(machine.isActive(newId), true);
  assert.equal(machine.currentState(), sandbox.State.STARTING);
});

test('the matching late stop completion settles its timed out command', async () => {
  const harness = bridgeHarness();
  const commandId = harness.vpnCommandStateMachine.begin(sandbox.Command.DISCONNECT);
  assert.equal(harness.vpnCommandStateMachine.timeout(commandId), true);
  harness.finishVpnExtensionStop(commandId);
  harness.resolveStop();
  await flush();

  assert.equal(harness.vpnStatus, 'HarmonyOS VPN Extension stopped');
  assert.equal(harness.disconnectInProgress, false);
  assert.equal(harness.vpnCommandStateMachine.currentState(), sandbox.State.STOPPED);
});

test('a stop promise that never settles is bounded and releases the disconnect command', async () => {
  const harness = bridgeHarness();
  const commandId = harness.vpnCommandStateMachine.begin(sandbox.Command.DISCONNECT);
  harness.finishVpnExtensionStop(commandId);
  await new Promise(resolve => setTimeout(resolve, 15));

  assert.equal(harness.vpnStatus, 'FAILED | VPN stop | timeout');
  assert.equal(harness.disconnectInProgress, false);
  assert.equal(harness.vpnCommandStateMachine.currentState(), sandbox.State.STOPPED);
  assert.equal(harness.pollingStops, 1);
});

test('a late stop result cannot mutate a newer timed out command', async () => {
  const harness = bridgeHarness();
  const oldCommandId = harness.vpnCommandStateMachine.begin(sandbox.Command.DISCONNECT);
  assert.equal(harness.vpnCommandStateMachine.timeout(oldCommandId), true);
  harness.finishVpnExtensionStop(oldCommandId);
  const newCommandId = harness.vpnCommandStateMachine.begin(sandbox.Command.DISCONNECT);
  assert.equal(harness.vpnCommandStateMachine.timeout(newCommandId), true);
  harness.resolveStop();
  await flush();

  assert.equal(harness.vpnStatus, '');
  assert.equal(harness.disconnectInProgress, true);
  assert.equal(harness.vpnCommandStateMachine.isTimedOut(newCommandId), true);
  assert.equal(harness.vpnCommandStateMachine.currentState(), sandbox.State.TIMED_OUT);
});

test('a stop result after lifecycle invalidation is ignored', async () => {
  const harness = bridgeHarness();
  const commandId = harness.vpnCommandStateMachine.begin(sandbox.Command.DISCONNECT);
  assert.equal(harness.vpnCommandStateMachine.timeout(commandId), true);
  harness.finishVpnExtensionStop(commandId);
  harness.vpnCommandStateMachine.invalidateLifecycle();
  harness.resolveStop();
  await flush();

  assert.equal(harness.vpnStatus, '');
  assert.equal(harness.disconnectInProgress, true);
  assert.equal(harness.vpnCommandStateMachine.currentState(), sandbox.State.STOPPED);
});

test('awaitVpnOperation returns successful values', async () => {
  assert.equal(await sandbox.awaitVpnOperation(Promise.resolve('ready'), 'backend snapshot', 20), 'ready');
});

test('awaitVpnOperation rejects after its deadline without canceling the operation', async () => {
  let settleOperation;
  const operation = new Promise(resolve => { settleOperation = resolve; });
  await assert.rejects(sandbox.awaitVpnOperation(operation, 'backend snapshot', 5), /timed out after 5 ms/);
  settleOperation('late result');
  await flush();

  let rejectOperation;
  const lateRejection = new Promise((_resolve, reject) => { rejectOperation = reject; });
  await assert.rejects(sandbox.awaitVpnOperation(lateRejection, 'backend snapshot', 5), /timed out after 5 ms/);
  rejectOperation(new Error('late native rejection'));
  await flush();
});

test('requestVpnConfig is bounded when native config never settles', async () => {
  platform.configPromise = new Promise(() => {});
  const gateway = new sandbox.Gateway();
  await assert.rejects(gateway.requestVpnConfig(), /VPN config request timed out after 5 ms/);
});

test('requestBackendStatus is bounded when native status never settles', async () => {
  platform.statusPromise = new Promise(() => {});
  const gateway = new sandbox.Gateway();
  await assert.rejects(gateway.requestBackendStatus(), /backend status request timed out after 5 ms/);
});

test('stopVpnExtension is bounded without treating timeout as native cancellation', async () => {
  let completeNativeStop;
  let stopCalls = 0;
  platform.stopPromise = new Promise(resolve => { completeNativeStop = resolve; });
  sandbox.vpnExtension.stopVpnExtensionAbility = () => { stopCalls++; return platform.stopPromise; };
  const gateway = new sandbox.Gateway();

  await assert.rejects(gateway.stopVpnExtension({}), /VPN Extension stop timed out after 5 ms/);
  assert.equal(stopCalls, 1);
  completeNativeStop();
  await flush();
});
