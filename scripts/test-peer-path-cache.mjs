import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const src = readFileSync(new URL('../entry/src/main/ets/services/PeerPathService.ets', import.meta.url), 'utf8');
const js = stripTypeScriptTypes(src.replace(/^import .*;\r?$/gm, '')
  .replace('export class PeerPathService', 'class PeerPathService'));
function fixture() {
  const f = { now: 10000, calls: 0, type: 'derp' };
  const sandbox = { Date: { now: () => f.now },
    nativeBridge: { backendPeerConnectivityAsync: async () => {
      f.nativeCalls = (f.nativeCalls || 0) + 1;
      return JSON.stringify({ state: 'reachable', pathType: 'direct' });
    } }, awaitVpnOperation: async operation => operation };
  vm.runInNewContext(js + '\nglobalThis.Service = PeerPathService;', sandbox);
  f.service = new sandbox.Service({ filesDir: '/files' });
  f.service.requestThroughVpnExtension = async () => {
    f.calls++; return JSON.stringify({ state: 'reachable', reason: '', pathType: f.type });
  };
  return f;
}

test('a transient relay cache expires so a later direct response can replace it', async () => {
  const f = fixture(); assert.equal((await f.service.probe('peer', true)).type, 'derp');
  f.now += 2000; f.type = 'direct'; await f.service.probe('peer', true); assert.equal(f.calls, 1);
  f.now += 1001; assert.equal((await f.service.probe('peer', true)).type, 'direct'); assert.equal(f.calls, 2);
  f.now += 20000; await f.service.probe('peer', true); assert.equal(f.calls, 2);
});

test('disconnect overrides a previously cached direct path', async () => {
  const f = fixture(); f.type = 'direct'; await f.service.probe('peer', true);
  const result = await f.service.probe('peer', false);
  assert.equal(result.type, 'unknown'); assert.equal(result.errorMessage, 'mesh_disconnected');
});

test('userspace path probes call the live native backend instead of the VPN extension', async () => {
  const harness = fixture();
  const result = await harness.service.probe('peer', true, true, true);
  assert.equal(result.type, 'direct');
  assert.equal(harness.nativeCalls, 1);
  assert.equal(harness.calls, 0);
});
