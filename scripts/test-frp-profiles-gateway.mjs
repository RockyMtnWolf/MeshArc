import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/services/FrpProfilesGateway.ets', import.meta.url), 'utf8');
const executable = stripTypeScriptTypes(source.replace(/^import .*\r?\n/gm, '').replace(/^export /gm, ''));

function setup() {
  const states = new Map();
  const owners = [];
  const stopped = [];
  let failOwnerOnce = false;
  const status = (profileId, running = false) => ({
    profileId, state: running ? 'running' : 'stopped', error: '', proxyCount: 1,
    serviceRunning: running, connectedToFrps: running
  });
  const sandbox = {
    nativeBridge: {
      async frpProfileStartAsync(raw) {
        const { profileId } = JSON.parse(raw);
        const next = status(profileId, true);
        states.set(profileId, next);
        return JSON.stringify(next);
      },
      async frpProfileStopAsync(profileId) {
        stopped.push(profileId);
        const next = status(profileId);
        states.set(profileId, next);
        return JSON.stringify(next);
      },
      async frpProfilesStatusAsync() { return JSON.stringify([...states.values()]); }
    },
    sharedVpnBackgroundTask: {
      async setFrpActive(context, active) {
        if (failOwnerOnce) {
          failOwnerOnce = false;
          throw new Error('background failed');
        }
        owners.push(active);
        return { taskActive: active, activeModes: active ? ['dataTransfer'] : [], error: '' };
      }
    },
    parseFrpToml: () => ({ config: {} }),
    validateFrpConfig: () => [],
    awaitVpnOperation: promise => promise,
    setTimeout
  };
  vm.runInNewContext(`${executable}\nthis.gateway = FrpProfilesGateway;`, sandbox);
  return { gateway: sandbox.gateway, states, owners, stopped, status,
    failOwner: () => { failOwnerOnce = true; } };
}

const profile = id => ({ id, name: id, toml: 'dummy configuration', updatedAt: 0 });

test('stopping one profile preserves another running instance and its keepalive owner', async () => {
  const state = setup();
  await state.gateway.start({}, profile('first'));
  await state.gateway.start({}, profile('second'));
  await state.gateway.stop({}, 'first');
  assert.equal(state.states.get('second').serviceRunning, true);
  assert.equal(state.owners.at(-1), true);
  assert.deepEqual(state.stopped, ['first']);
  await state.gateway.stop({}, 'second');
  assert.equal(state.owners.at(-1), false);
});

test('background setup failure rolls back only the newly started profile', async () => {
  const state = setup();
  await state.gateway.start({}, profile('existing'));
  state.failOwner();
  await assert.rejects(state.gateway.start({}, profile('new')), /background failed/);
  assert.equal(state.states.get('existing').serviceRunning, true);
  assert.deepEqual(state.stopped, ['new']);
  assert.equal(state.owners.at(-1), true);
});

test('malformed native status does not release existing background ownership', async () => {
  const state = setup();
  await state.gateway.start({}, profile('active'));
  state.states.set('active', { profileId: 'active', state: 'unknown' });
  const previous = state.owners.length;
  await assert.rejects(state.gateway.statuses({}), /状态无效/);
  assert.equal(state.owners.length, previous);
  assert.equal(state.owners.at(-1), true);
});

test('failed terminal instances release the FRP owner only when no other instance is active', async () => {
  const state = setup();
  state.states.set('failed', { ...state.status('failed'), state: 'failed', error: 'EOF' });
  await state.gateway.statuses({});
  assert.equal(state.owners.at(-1), false);
  state.states.set('another', state.status('another', true));
  await state.gateway.statuses({});
  assert.equal(state.owners.at(-1), true);
});
