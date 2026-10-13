import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');
function method(name) {
  const start = source.indexOf(`  private ${name}(`);
  assert.ok(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
}
const sandbox = {};
vm.runInNewContext(stripTypeScriptTypes(`class Controller {
  ${method('localSendAvailableForPeer')}
  ${method('localSendStatusForPeer')}
  ${method('peerEffectivelyOnline')}
}\nglobalThis.Controller = Controller;`), sandbox);

test('a mounted detail sheet reads a fresh LocalSend result despite its captured old peer', () => {
  const c = new sandbox.Controller();
  c.meshConnected = () => true;
  const capturedPeer = { key: 'pc', online: true, localSend: { state: 'unavailable' } };
  c.peers = [capturedPeer];
  assert.equal(c.localSendAvailableForPeer(capturedPeer), false);
  c.peers = [{ key: 'pc', online: true, localSend: { state: 'available' } }];
  assert.equal(c.localSendAvailableForPeer(capturedPeer), true);
  assert.equal(c.localSendStatusForPeer('pc').state, 'available');
  c.peers = [{ key: 'pc', online: true, localSend: { state: 'unavailable' } }];
  assert.equal(c.localSendAvailableForPeer(capturedPeer), false);
});

test('current peer presence and VPN connection override an old available service', () => {
  const c = new sandbox.Controller();
  c.meshConnected = () => true;
  const capturedPeer = { key: 'pc', online: true, localSend: { state: 'available' } };
  c.peers = [{ ...capturedPeer, online: false }];
  assert.equal(c.localSendAvailableForPeer(capturedPeer), false);
  c.peers = [];
  assert.equal(c.localSendAvailableForPeer(capturedPeer), false);
  assert.equal(c.localSendStatusForPeer('pc'), undefined);
  c.peers = [capturedPeer];
  c.meshConnected = () => false;
  assert.equal(c.localSendAvailableForPeer(capturedPeer), false);
});
