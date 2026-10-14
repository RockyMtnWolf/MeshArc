import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const readSource = path => readFileSync(new URL(path, import.meta.url), 'utf8')
  .replace(/^import .*;\r?$/gm, '');

function controllerFixture(options = {}) {
  const f = { preference: options.preference ?? 'off', saved: [], taskModes: [], taskError: '',
    deviceType: options.deviceType ?? '2in1', taskGate: null };
  const modesFor = mode => mode === 'download' ? ['dataTransfer'] :
    (mode === 'taskKeeping' ? ['taskKeeping'] : []);
  const taskManager = {
    async setKeepaliveMode(mode) {
      f.taskModes.push(mode);
      if (mode === 'taskKeeping' && f.taskGate) await f.taskGate.promise;
      const activeModes = modesFor(mode);
      return { selectedMode: mode, taskActive: mode !== 'off' && f.taskError.length === 0,
        activeModes: f.taskError.length === 0 ? activeModes : [], error: f.taskError };
    },
    getKeepaliveTaskState() {
      const mode = f.taskModes.at(-1) ?? 'off';
      const activeModes = modesFor(mode);
      return { selectedMode: mode, taskActive: mode !== 'off' && f.taskError.length === 0,
        activeModes: f.taskError.length === 0 ? activeModes : [], error: f.taskError };
    }
  };
  const sandbox = {
    VpnBackgroundTaskManager: class {},
    deviceInfo: { deviceType: f.deviceType, DeviceTypes: { TYPE_2IN1: '2in1' } },
    preferences: { getPreferences: async () => ({
      getSync: (_key, fallback) => f.preference ?? fallback,
      putSync: (_key, mode) => { f.preference = mode; f.saved.push(mode); },
      flush: async () => {}
    }) },
    setInterval: () => 1,
    clearInterval: () => {}
  };
  const preferencesSource = readSource('../entry/src/main/ets/services/BackgroundKeepalivePreferences.ets')
    .replace('export class BackgroundKeepalivePreferences', 'class BackgroundKeepalivePreferences');
  const controllerSource = readSource('../entry/src/main/ets/services/BackgroundKeepaliveController.ets')
    .replace('export class BackgroundKeepaliveController', 'class BackgroundKeepaliveController')
    .replace('export const sharedVpnBackgroundTask', 'const sharedVpnBackgroundTask')
    .replace('export const sharedBackgroundKeepaliveController', 'const sharedBackgroundKeepaliveController');
  vm.runInNewContext(`${stripTypeScriptTypes(preferencesSource)}\n${stripTypeScriptTypes(controllerSource)}\n` +
    'globalThis.Controller = BackgroundKeepaliveController;', sandbox);
  f.context = {};
  f.controller = new sandbox.Controller(taskManager);
  f.taskManager = taskManager;
  return f;
}

test('default off performs no keepalive task', async () => {
  const f = controllerFixture();
  assert.equal(await f.controller.selectedMode(f.context), 'off');
  assert.equal(f.taskModes.length, 0);
});

test('download mode requests and confirms dataTransfer before persisting', async () => {
  const f = controllerFixture();
  const result = await f.controller.activate(f.context, 'download');
  assert.equal(result.ok, true);
  assert.equal(result.taskActive, true);
  assert.deepEqual(f.taskModes, ['download']);
  assert.equal(f.preference, 'download');
});

test('taskKeeping mode persists only after system confirmation on PC', async () => {
  const f = controllerFixture();
  const result = await f.controller.activate(f.context, 'taskKeeping');
  assert.equal(result.ok, true);
  assert.equal(result.taskActive, true);
  assert.deepEqual(f.taskModes, ['taskKeeping']);
  assert.equal(f.preference, 'taskKeeping');
});

test('taskKeeping is rejected on non-PC without requesting ACL or system task', async () => {
  const f = controllerFixture({ deviceType: 'phone' });
  const result = await f.controller.activate(f.context, 'taskKeeping');
  assert.equal(result.ok, false);
  assert.match(result.message, /PC\/2-in-1/);
  assert.deepEqual(f.taskModes, []);
  assert.equal(f.preference, 'off');
});

test('a failed system task is visible and is not persisted', async () => {
  const f = controllerFixture();
  f.taskError = 'taskKeeping rejected';
  const result = await f.controller.activate(f.context, 'taskKeeping');
  assert.equal(result.ok, false);
  assert.equal(result.taskActive, false);
  assert.match(result.message, /taskKeeping rejected/);
  assert.equal(f.preference, 'off');
});

test('switching from taskKeeping to download replaces the requested mode', async () => {
  const f = controllerFixture();
  await f.controller.activate(f.context, 'taskKeeping');
  const result = await f.controller.activate(f.context, 'download');
  assert.equal(result.ok, true);
  assert.deepEqual(f.taskModes, ['taskKeeping', 'download']);
  assert.equal(f.preference, 'download');
});

test('legacy audio preference migrates to taskKeeping on PC and off on non-PC', async () => {
  const pc = controllerFixture({ preference: 'audio', deviceType: '2in1' });
  assert.equal(await pc.controller.selectedMode(pc.context), 'taskKeeping');
  assert.equal(pc.preference, 'taskKeeping');
  assert.deepEqual(pc.saved, ['taskKeeping']);
  const phone = controllerFixture({ preference: 'audio', deviceType: 'phone' });
  assert.equal(await phone.controller.selectedMode(phone.context), 'off');
  assert.equal(phone.preference, 'off');
  assert.deepEqual(phone.saved, ['off']);
});

test('legacy location and PiP preferences migrate to off', async () => {
  for (const legacyMode of ['location', 'pip']) {
    const f = controllerFixture({ preference: legacyMode });
    assert.equal(await f.controller.selectedMode(f.context), 'off');
    assert.equal(f.preference, 'off');
    assert.deepEqual(f.saved, ['off']);
  }
});

test('deactivate and dispose retain the controller lifecycle', async () => {
  const f = controllerFixture();
  await f.controller.activate(f.context, 'taskKeeping');
  const stopped = await f.controller.deactivate(f.context);
  assert.equal(stopped.mode, 'off');
  assert.equal(f.preference, 'off');
  await f.controller.activate(f.context, 'taskKeeping');
  await f.controller.dispose();
});

test('late task confirmation cannot replace a newer off generation', async () => {
  let release;
  const f = controllerFixture();
  f.taskGate = { promise: new Promise(resolve => { release = resolve; }) };
  const pending = f.controller.activate(f.context, 'taskKeeping');
  await Promise.resolve();
  await Promise.resolve();
  const off = f.controller.deactivate(f.context);
  release();
  const staleResult = await pending;
  const offResult = await off;
  assert.equal(staleResult.ok, false);
  assert.match(staleResult.message, /取消/);
  assert.equal(offResult.mode, 'off');
  assert.deepEqual(f.taskModes, ['taskKeeping', 'off']);
  assert.equal(f.preference, 'off');
});

test('background callback during transition observes current state without canceling its generation', async () => {
  let release;
  const f = controllerFixture();
  f.taskGate = { promise: new Promise(resolve => { release = resolve; }) };
  const pending = f.controller.activate(f.context, 'taskKeeping');
  await Promise.resolve();
  await Promise.resolve();
  const backgroundState = await f.controller.onBackground(f.context);
  assert.equal(backgroundState.mode, 'off');
  assert.deepEqual(f.taskModes, ['taskKeeping']);
  release();
  assert.equal((await pending).ok, true);
  assert.deepEqual(f.taskModes, ['taskKeeping']);
});
