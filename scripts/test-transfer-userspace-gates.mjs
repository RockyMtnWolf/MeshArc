import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const bridgeSource = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');
const gatewaySource = readFileSync(new URL('../entry/src/main/ets/services/HomeReadOnlyGateway.ets', import.meta.url), 'utf8');
function method(source, name) {
  const plainStart = source.indexOf(`  private ${name}(`);
  const start = plainStart >= 0 ? plainStart : source.indexOf(`  private async ${name}(`);
  assert.ok(start >= 0, name);
  const end = source.indexOf('\n  }', start) + 4;
  return source.slice(start, end);
}

const methods = ['isConnected', 'meshConnected', 'performLocalSendRefresh']
  .map(name => method(bridgeSource, name)).join('\n');
const js = stripTypeScriptTypes(`class Controller { ${methods} }`);

function fixture({ vpnRunning, userspaceActive, backendRunning }) {
  const sandbox = {};
  vm.runInNewContext(`${js}\nglobalThis.Controller = Controller;`, sandbox);
  const controller = new sandbox.Controller();
  const calls = [];
  Object.assign(controller, {
    vpnStatus: vpnRunning ? 'state=Running' : 'VPN Extension Stopped',
    clashUserspaceActive: userspaceActive,
    backendStatus: backendRunning ? 'state=Running' : 'STOPPED',
    homeReadOnlyGateway: { refreshLocalSend: async () => calls.push('native-local-send') },
    refreshBackendStatus: async () => calls.push('backend-snapshot')
  });
  return { controller, calls };
}

test('userspace mode refreshes LocalSend through native NAPI and the backend snapshot', async () => {
  const { controller, calls } = fixture({ vpnRunning: false, userspaceActive: true, backendRunning: true });
  await controller.performLocalSendRefresh();
  assert.deepEqual(calls, ['native-local-send', 'backend-snapshot']);
});

test('a stopped backend does not attempt LocalSend refresh', async () => {
  const { controller, calls } = fixture({ vpnRunning: false, userspaceActive: true, backendRunning: false });
  await controller.performLocalSendRefresh();
  assert.deepEqual(calls, ['backend-snapshot']);
});

test('HomeReadOnlyGateway invokes direct native refresh instead of extension command files', () => {
  assert.match(gatewaySource, /refreshLocalSend\(\): Promise<string>[\s\S]*?nativeBridge\.backendLocalSendRefreshAsync\(\)/);
  const refresh = method(bridgeSource, 'performLocalSendRefresh');
  assert.match(refresh, /this\.meshConnected\(\)/);
  assert.match(refresh, /if \(this\.clashUserspaceActive && !this\.isConnected\(\)\)/);
  assert.match(refresh, /LOCAL_SEND_REFRESH_REQUEST_FILE_NAME/);
  assert.match(bridgeSource, /if \(this\.clashUserspaceActive && !this\.isConnected\(\)\) \{\s*this\.refreshBackendStatus\(\);\s*return;/);
});

test('peer path probe failure does not mark an online control-plane peer offline', () => {
  const status = method(bridgeSource, 'peerCardStatus');
  assert.match(status, /if \(!this\.peerEffectivelyOnline\(peer\)\)[\s\S]*?peer_offline/);
  assert.doesNotMatch(status, /connection_recovering/);
  assert.match(bridgeSource, /private peerEffectivelyOnline\(peer: PeerSummary\): boolean \{[\s\S]*?return peer\.online;/);
});
