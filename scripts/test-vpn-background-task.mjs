import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

// Run the real lifecycle coordinator with deterministic platform boundaries.
// ArkTS compilation is verified separately by the repository debug build.
const source = readFileSync(new URL('../entry/src/main/ets/services/VpnBackgroundTaskManager.ets', import.meta.url), 'utf8');
const javascript = stripTypeScriptTypes(source.replace(/^import .*;\r?$/gm, '')
  .replace('export class VpnBackgroundTaskManager', 'class VpnBackgroundTaskManager'));
const flush = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
function deferred() {
  let resolve;
  const promise = new Promise(r => { resolve = r; });
  return { promise, resolve };
}

function fixture() {
  const f = {
    now: 1000000, status: '', starts: [], updates: [], stops: 0, notifications: [], events: [],
    callbacks: new Map(), startGate: null, publishGate: null, startError: null,
    stopGate: null, readError: false
  };
  const context = { filesDir: '/files', resourceManager: { getStringByNameSync: () => 'VPN connected' } };
  const sandbox = {
    Date: { now: () => f.now }, setInterval: () => 1, clearInterval: () => {},
    wantAgent: { OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 },
      getWantAgent: async () => ({}) },
    backgroundTaskManager: {
      ContinuousTaskCancelReason: { USER_CANCEL: 1, USER_CANCEL_REMOVE_NOTIFICATION: 3 },
      on: (name, cb) => f.callbacks.set(name, cb), off: name => f.callbacks.delete(name),
      startBackgroundRunning: async (_ctx, modes) => {
        f.starts.push(modes);
        if (f.startError) throw f.startError;
        if (f.startGate) await f.startGate.promise;
        return { notificationId: 42, continuousTaskId: 7 };
      },
      updateBackgroundRunning: async (_ctx, modes) => {
        f.updates.push(modes);
        return { notificationId: 42, continuousTaskId: 7 };
      },
      stopBackgroundRunning: async () => { f.stops++; if (f.stopGate) await f.stopGate.promise; }
    },
    fileIo: { readTextSync: () => { if (f.readError) throw Error('temporary I/O'); return f.status; } },
    StoragePaths: { vpnStatusPath: dir => dir + '/vpn-probe-status.txt' },
    notificationManager: {
      SlotType: { LIVE_VIEW: 4 }, ContentType: { NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW: 5 },
      publish: async request => { f.notifications.push(request); if (f.publishGate) await f.publishGate.promise; }
    },
    hilog: { info: () => {} }, DiagnosticEventStore: { record: (...args) => f.events.push(args) }
  };
  vm.runInNewContext(javascript + '\nglobalThis.Manager = VpnBackgroundTaskManager;', sandbox);
  f.manager = new sandbox.Manager();
  f.live = () => { f.status = `OK | state=Running | tun=true | txBytes=2048 | rxBytes=1048576 | heartbeatMs=${f.now}`; };
  f.disconnected = () => { f.status = `VPN extension destroyed | heartbeatMs=${f.now}`; };
  f.tick = async () => { await f.manager.reconcile(context); await flush(); };
  f.start = async () => { f.live(); f.manager.register(context); await flush(); };
  f.cancel = (reason, id = 7) => f.callbacks.get('continuousTaskCancel')({ id, reason });
  f.context = context;
  return f;
}

test('acquires protection in foreground and updates the same system live view with real traffic', async () => {
  const f = fixture(); await f.start();
  assert.equal(f.starts.length, 1);
  assert.equal(f.starts[0][0], 'dataTransfer');
  assert.equal(f.notifications[0].id, 42);
  assert.match(f.notifications[0].content.systemLiveView.text, /2.0 KiB.*1.0 MiB/);
  assert.equal(f.notifications[0].template.data.progressValue, 0);
  f.manager.onBackground(f.context); await flush();
  assert.equal(f.stops, 0);
  assert.equal(f.starts.length, 1);
  assert.equal(f.notifications.length, 1);
  f.now += 30000; f.live(); await f.tick();
  assert.equal(f.notifications.length, 2);
  assert.equal(f.notifications[1].id, 42);
});

test('stale heartbeat and read errors retain acquired protection for a bounded grace period', async () => {
  const f = fixture(); await f.start();
  f.now += 16000; await f.tick(); assert.equal(f.stops, 0);
  f.readError = true; f.now += 20000; await f.tick(); assert.equal(f.stops, 0);
  f.now += 25000; await f.tick(); assert.equal(f.stops, 1);
  f.readError = false; f.live(); await f.tick(); assert.equal(f.starts.length, 2);
});

test('never starts from stale, future, missing heartbeat or missing TUN evidence', async () => {
  for (const status of ['OK | state=Running | tun=true',
    'OK | state=Running | tun=true | heartbeatMs=1',
    'OK | state=Running | tun=true | heartbeatMs=2000000',
    'OK | state=Running | tun=false | heartbeatMs=1000000']) {
    const f = fixture(); f.status = status; f.manager.register(f.context); await flush();
    assert.equal(f.starts.length, 0, status);
  }
});

test('explicit disconnect promptly releases the task', async () => {
  const f = fixture(); await f.start(); f.disconnected(); await f.tick();
  assert.equal(f.stops, 1);
  assert.equal(f.manager.task, undefined);
});

test('snapshot failure is uncertain and does not immediately revoke protection', async () => {
  const f = fixture(); await f.start();
  f.status = `FAILED | VPN backend | status unavailable | heartbeatMs=${f.now}`;
  await f.tick(); assert.equal(f.stops, 0);
});

test('user cancellation stays suppressed across stale telemetry and foreground until confirmed disconnect', async () => {
  const f = fixture(); await f.start(); f.cancel(1);
  f.now += 90000; await f.tick(); f.live();
  f.manager.onForeground(f.context); await flush(); assert.equal(f.starts.length, 1);
  f.disconnected(); await f.tick(); f.live(); await f.tick();
  assert.equal(f.starts.length, 2);
});

test('system cancellation retries with exponential backoff', async () => {
  const f = fixture(); await f.start(); f.cancel(2);
  f.now += 29999; f.live(); await f.tick(); assert.equal(f.starts.length, 1);
  f.now++; f.live(); await f.tick(); assert.equal(f.starts.length, 2);
  f.cancel(2); f.now += 30000; f.live(); await f.tick(); assert.equal(f.starts.length, 2);
  f.now += 30000; f.live(); await f.tick(); assert.equal(f.starts.length, 3);
});

test('unrelated cancellation does not discard the VPN task', async () => {
  const f = fixture(); await f.start(); f.cancel(1, 99); await f.tick();
  assert.equal(f.manager.task.continuousTaskId, 7);
});

test('a failed start is throttled instead of retried every second', async () => {
  const f = fixture(); f.startError = { code: 9800005 }; await f.start();
  for (let i = 0; i < 20; i++) { f.now += 1000; f.live(); await f.tick(); }
  assert.equal(f.starts.length, 1);
  f.now += 10000; f.live(); await f.tick(); assert.equal(f.starts.length, 2);
});

test('cancellation received during start cannot be overwritten by its late result', async () => {
  const f = fixture(); f.startGate = deferred(); await f.start(); f.cancel(1);
  f.startGate.resolve(); await flush();
  assert.equal(f.manager.task, undefined); assert.equal(f.notifications.length, 0);
  await f.tick(); assert.equal(f.starts.length, 1);
});

test('disconnect during start cleans up the late successful task without publishing', async () => {
  const f = fixture(); f.startGate = deferred(); await f.start(); f.disconnected();
  f.startGate.resolve(); await flush();
  assert.equal(f.stops, 1); assert.equal(f.notifications.length, 0);
});

test('destroy during start cleans up the late successful task', async () => {
  const f = fixture(); f.startGate = deferred(); await f.start(); f.manager.unregister();
  f.startGate.resolve(); await flush();
  assert.equal(f.stops, 1); assert.equal(f.notifications.length, 0);
  assert.equal(f.callbacks.size, 0);
});

test('destroy during notification update serializes cleanup after publish', async () => {
  const f = fixture(); f.publishGate = deferred(); await f.start(); f.manager.unregister();
  assert.equal(f.stops, 0);
  f.publishGate.resolve(); await flush(); assert.equal(f.stops, 1);
});

test('reconnect waits for in-flight stop before starting the next task', async () => {
  const f = fixture(); await f.start(); f.stopGate = deferred(); f.disconnected();
  const stopping = f.tick(); await flush(); f.live(); await f.tick();
  assert.equal(f.starts.length, 1);
  f.stopGate.resolve(); await stopping; await f.tick(); assert.equal(f.starts.length, 2);
});

test('default off preserves the existing connected-VPN dataTransfer lifecycle', async () => {
  const f = fixture(); await f.start();
  assert.equal(f.manager.getKeepaliveTaskState().selectedMode, 'off');
  assert.equal(JSON.stringify(f.starts), JSON.stringify([['dataTransfer']]));
  assert.equal(f.updates.length, 0);
  f.disconnected(); await f.tick();
  assert.equal(f.stops, 1);
});

test('download mode may request dataTransfer while VPN is disconnected without fake progress or network work', async () => {
  const f = fixture(); f.disconnected(); f.manager.register(f.context); await flush();
  const state = await f.manager.setKeepaliveMode('download'); await flush();
  assert.equal(JSON.stringify(f.starts), JSON.stringify([['dataTransfer']]));
  assert.equal(state.selectedMode, 'download');
  assert.equal(state.taskActive, true);
  assert.match(f.notifications.at(-1).content.systemLiveView.text, /模拟下载保活（无实际下载）/);
  assert.deepEqual(JSON.parse(JSON.stringify(f.notifications.at(-1).template)), {
    name: 'downloadTemplate',
    data: { title: 'VPN connected', fileName: '模拟下载保活（无实际下载）', progressValue: 0 }
  });
  assert.equal(f.updates.length, 0);
  assert.equal(f.stops, 0);
  await f.manager.setKeepaliveMode('off'); await flush();
  assert.equal(f.stops, 1);
});

test('audio mode uses audioPlayback and preserves connected VPN dataTransfer in the shared task', async () => {
  const f = fixture(); await f.start();
  const state = await f.manager.setKeepaliveMode('audio'); await flush();
  assert.equal(JSON.stringify(f.starts), JSON.stringify([['dataTransfer']]));
  assert.equal(JSON.stringify(f.updates), JSON.stringify([['dataTransfer', 'audioPlayback']]));
  assert.equal(state.taskActive, true);
  assert.equal(f.stops, 0);
  await f.manager.setKeepaliveMode('off'); await flush();
  assert.equal(JSON.stringify(f.updates.at(-1)), JSON.stringify(['dataTransfer']));
  assert.equal(f.stops, 0);
});

test('audio-only mode starts an audioPlayback task without requiring VPN connectivity', async () => {
  const f = fixture(); f.disconnected(); f.manager.register(f.context); await flush();
  const state = await f.manager.setKeepaliveMode('audio'); await flush();
  assert.deepEqual(JSON.parse(JSON.stringify(f.starts)), [['audioPlayback']]);
  assert.equal(state.taskActive, true);
  assert.equal(f.notifications.length, 0);
  assert.equal(f.stops, 0);
});

test('FRP and userspace owners are independent and onDestroy retains their shared task', async () => {
  const f = fixture(); f.disconnected(); f.manager.register(f.context); await flush();
  await f.manager.setFrpActive(f.context, true); await flush();
  assert.deepEqual(JSON.parse(JSON.stringify(f.starts)), [['dataTransfer']]);
  await f.manager.setUserspaceActive(f.context, true); await flush();
  assert.equal(f.updates.length, 0);
  await f.manager.setFrpActive(f.context, false); await flush();
  assert.equal(f.stops, 0);
  f.manager.unregister(); await flush();
  assert.equal(f.stops, 0);
  await f.manager.setUserspaceActive(f.context, false); await flush();
  assert.equal(f.stops, 1);
});

test('userspace release does not stop an independently active FRP owner', async () => {
  const f = fixture(); f.disconnected(); f.manager.register(f.context); await flush();
  await f.manager.setUserspaceActive(f.context, true); await flush();
  await f.manager.setFrpActive(f.context, true); await flush();
  await f.manager.setUserspaceActive(f.context, false); await flush();
  assert.equal(f.stops, 0);
  await f.manager.setFrpActive(f.context, false); await flush();
  assert.equal(f.stops, 1);
});
