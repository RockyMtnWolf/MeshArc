import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const componentSource = readFileSync(new URL('../entry/src/main/ets/components/ClashCoexistenceSettings.ets', import.meta.url), 'utf8');
const gatewaySource = readFileSync(new URL('../entry/src/main/ets/services/InboundTCPGateway.ets', import.meta.url), 'utf8');
const extensionSource = readFileSync(new URL('../entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets', import.meta.url), 'utf8');

const extractBody = (source, signature) => {
  const match = source.match(new RegExp(`${signature}\\s*\\{([\\s\\S]*?)\\n  \\}`));
  assert.ok(match, `source method exists: ${signature}`);
  return match[1];
};

const componentMethod = (methodName, parameters = '') => {
  const signature = `  (?:private )?(?:async )?${methodName}\\([^\\n]*\\): [^{]+`;
  const body = extractBody(componentSource, signature).replace(/: number(?=\s*=)/g, '');
  return vm.runInNewContext(`(function(${parameters}) {${body}\n})`, {
    AppStorage: { setOrCreate: () => {} },
    clearInterval: () => {},
    setInterval: () => 1
  });
};

const gatewayMethod = (methodName, parameters, dependencies) => {
  const signature = `  (?:private )?(?:async )?${methodName}\\([^\\n]*\\): [^{]+`;
  const body = extractBody(gatewaySource, signature)
    .replace(/: (?:InboundTCPRpcRequest|InboundTCPRpcResponse)(?=\s*[=;])/g, '')
    .replace(/: (?:InboundTCPOwnerSession(?: \| undefined)?|string|number|boolean|RegExpMatchArray \| null)(?=\s*[=;])/g, '')
    .replace(/\s+as InboundTCPRpcRequest/g, '');
  return vm.runInNewContext(`(function(${parameters}) {${body}\n})`, dependencies);
};

test('state hydration is silent; cancellation stays off; a real off/on edge reconfirms', () => {
  let alert;
  let dialogs = 0;
  const submitted = [];
  const component = {
    busy: false,
    inboundTCPAvailable: true,
    inboundTCPAllowAll: false,
    inboundTCPPorts: [3240],
    inboundTCPEnabled: false,
    inboundPortsDraftDirty: true,
    lifecycleGeneration: 1,
    allowAllConfirmationPending: false,
    active: false,
    timer: 1,
    generation: 0,
    syncInboundPortDrafts: () => {},
    refresh: () => {},
    getUIContext: () => ({ showAlertDialog: (options) => { alert = options; dialogs++; } }),
    setInboundTCPPolicy: (allowAll, ports) => {
      submitted.push({ allowAll, ports });
      return Promise.resolve();
    }
  };
  component.applyStatus = componentMethod('applyStatus', 'state, forceDraftSync = false');
  component.confirmAllowAllInboundTCP = componentMethod('confirmAllowAllInboundTCP');
  component.aboutToAppear = componentMethod('aboutToAppear');
  component.aboutToDisappear = componentMethod('aboutToDisappear');
  const onChange = componentSource.match(/\.onChange\(\(enabled: boolean\) => \{([\s\S]*?)\n          \}\)/);
  assert.ok(onChange);
  component.handleToggleChange = vm.runInNewContext(`(function(enabled) {${onChange[1]}\n})`, {});
  const state = {
    active: false,
    inboundTCPAvailable: true,
    address: '',
    error: '',
    inboundTCPEnabled: true,
    inboundTCPPorts: [3240],
    inboundTCPAllowAll: true
  };

  component.applyStatus(state);
  component.handleToggleChange(true);
  assert.equal(dialogs, 0);
  component.applyStatus({ ...state, inboundTCPAllowAll: false });
  component.handleToggleChange(false);
  assert.equal(dialogs, 0);
  component.handleToggleChange(true);
  assert.equal(dialogs, 1);
  alert.secondaryButton.action();
  assert.equal(component.inboundTCPAllowAll, false);
  component.handleToggleChange(true);
  assert.equal(dialogs, 2);
  alert.primaryButton.action();
  assert.deepEqual(submitted, [{ allowAll: true, ports: [3240] }]);
  component.applyStatus({ ...state, inboundTCPAllowAll: true });
  component.handleToggleChange(true);
  assert.equal(dialogs, 2);
  component.handleToggleChange(false);
  component.applyStatus({ ...state, inboundTCPAllowAll: false });
  component.handleToggleChange(true);
  assert.equal(dialogs, 3);
});

test('RPC protocol rejects expired and switched-owner requests and deduplicates completed IDs', () => {
  assert.match(gatewaySource, /let lastInboundTCPRequestId: number = 0/);
  assert.match(gatewaySource, /writeAtomicText\(responsePath, ''\)[\s\S]*?writeAtomicText\(requestPath, JSON\.stringify\(request\)\)/);
  assert.match(gatewaySource, /private writeAtomicText\(path: string, content: string\): boolean/);
  assert.match(gatewaySource, /private async readOwnerSessionWithRetry\(\)/);
  const evaluate = gatewayMethod('evaluate', 'requestText, currentOwnerSession, now', {
    JSON,
    Number
  });
  const complete = gatewayMethod('complete', 'request, result, error, now', {});
  const protocol = { ownerSession: 'owner-a', lastRequestId: 0, lastResponse: undefined };
  const request = {
    ownerSession: 'owner-a',
    requestId: 44,
    expiresAtMs: 5000,
    operation: 'setPolicy',
    payload: '{"allowAll":true,"ports":[]}'
  };

  assert.equal(evaluate.call(protocol, JSON.stringify(request), 'owner-a', 5000).kind, 'expired');
  assert.equal(evaluate.call(protocol, JSON.stringify(request), 'owner-b', 4000).kind, 'owner_changed');
  assert.equal(evaluate.call(protocol, JSON.stringify({ ...request, expiresAtMs: 6000 }), 'owner-a', 4000).kind, 'duplicate');
  const nextRequest = { ...request, requestId: 45 };
  const accepted = evaluate.call(protocol, JSON.stringify(nextRequest), 'owner-a', 4000);
  assert.equal(accepted.kind, 'process');
  const response = complete.call(protocol, accepted.request, '{"inboundTCPAvailable":true}', '', 4500);
  assert.equal(response.requestId, 45);
  assert.equal(evaluate.call(protocol, JSON.stringify(nextRequest), 'owner-a', 4500).kind, 'duplicate');
  assert.equal(evaluate.call(protocol, JSON.stringify({ ...request, requestId: 43 }), 'owner-a', 4500).kind, 'stale');
});

test('route selection requires a fresh tun heartbeat and refuses a live unready VPN', () => {
  const gateway = { context: { filesDir: '/private' } };
  let status = `VPN interface established | tun=true | heartbeatMs=${Date.now()}`;
  const dependencies = {
    Date,
    HEARTBEAT_FRESHNESS_MS: 2500,
    VPN_PROBE_STATUS_FILE: 'vpn-probe-status.txt',
    fileIo: { accessSync: () => true, readTextSync: () => status }
  };
  const selectRoute = gatewayMethod('selectUserspaceRoute', '', dependencies);
  gateway.readOwnerSession = () => undefined;
  assert.equal(selectRoute.call(gateway), false);
  status = `VPN extension lifecycle entered | tun=false | heartbeatMs=${Date.now()}`;
  assert.throws(() => selectRoute.call(gateway), /TUN 尚未就绪/);
  status = 'VPN extension destroyed | tun=false | heartbeatMs=1';
  assert.equal(selectRoute.call(gateway), true);
  gateway.readOwnerSession = () => ({ ownerSession: 'live-owner', valid: true, tun: true, heartbeatMs: Date.now() });
  status = 'stale or missing heartbeat';
  assert.equal(selectRoute.call(gateway), false);
  gateway.readOwnerSession = () => ({ ownerSession: 'starting-owner', valid: true, tun: false, heartbeatMs: Date.now() });
  assert.throws(() => selectRoute.call(gateway), /扩展仍持有.*TUN 尚未就绪/);
});

test('stale VPN owner fails closed without writing another process policy', () => {
  const selectRoute = gatewayMethod('selectUserspaceRoute', '', { Date, HEARTBEAT_FRESHNESS_MS: 2500 });
  const gateway = { readOwnerSession: () => ({ valid: true, tun: true, heartbeatMs: Date.now() - 20000 }) };
  assert.throws(() => selectRoute.call(gateway), /请断开并重新连接本应用系统 VPN/);
});

test('extension owns, polls, serializes, and invalidates its private RPC session', () => {
  assert.match(extensionSource, /this\.inboundTCPOwnerSession = `\$\{Date\.now\(\)\}-\$\{Math\.floor\(Math\.random\(\) \* 1000000\)\}`/);
  assert.match(extensionSource, /this\.inboundTCPRequestTimer = setInterval\([\s\S]*?\}, 250\)/);
  assert.match(extensionSource, /this\.inboundTCPRequestInFlight = true/);
  assert.match(extensionSource, /this\.isCurrentInboundTCPOwner\(\)/);
  assert.match(extensionSource, /this\.writeInboundTCPOwnerSession\(false\)/);
  assert.match(extensionSource, /this\.writeAtomicTextFile\(responsePath, JSON\.stringify\(response\)\)/);
  assert.match(extensionSource, /if \(this\.inboundTCPRequestTimer >= 0\)[\s\S]*?clearInterval\(this\.inboundTCPRequestTimer\)/);
});

test('system authorization guidance opens only this app detail page when supported', () => {
  assert.match(componentSource, /应用内批准与系统入站授权独立；服务应用仍需在系统设置允许入站连接/);
  assert.match(componentSource, /settings\.openAppDetailSettingsPage\(context, context\.abilityInfo\.bundleName\)/);
  assert.match(componentSource, /deviceInfo\.sdkApiVersion >= 26 && canIUse\('SystemCapability\.Applications\.Settings\.Core'\)/);
  assert.doesNotMatch(componentSource, /MANAGE_NET_FIREWALL/);
});
