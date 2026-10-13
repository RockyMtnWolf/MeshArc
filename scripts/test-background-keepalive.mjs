import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const readSource = (path, replacements = []) => {
  let source = readFileSync(new URL(path, import.meta.url), 'utf8').replace(/^import .*;\r?$/gm, '');
  for (const [before, after] of replacements) source = source.replace(before, after);
  return stripTypeScriptTypes(source);
};

function controllerFixture(options = {}) {
  const f = { preference: options.preference ?? 'off', saved: [], taskModes: [], taskError: '',
    audioStarts: 0, audioStops: 0, audioActive: false, audioError: options.audioError ?? '' };
  const taskManager = {
    async setKeepaliveMode(mode) {
      f.taskModes.push(mode);
      const activeModes = mode === 'download' ? ['dataTransfer'] :
        (mode === 'audio' ? ['audioPlayback'] : []);
      return { selectedMode: mode, taskActive: mode !== 'off' && f.taskError.length === 0,
        activeModes: f.taskError.length === 0 ? activeModes : [], error: f.taskError };
    },
    getKeepaliveTaskState() {
      const mode = f.taskModes.at(-1) ?? 'off';
      const activeModes = mode === 'download' ? ['dataTransfer'] :
        (mode === 'audio' ? ['audioPlayback'] : []);
      return { selectedMode: mode, taskActive: mode !== 'off' && f.taskError.length === 0,
        activeModes: f.taskError.length === 0 ? activeModes : [], error: f.taskError };
    }
  };
  const audioService = {
    async start() {
      f.audioStarts++;
      f.audioActive = f.audioError.length === 0;
      return { active: f.audioActive, error: f.audioError };
    },
    async stop() { f.audioStops++; f.audioActive = false; return { active: false, error: '' }; },
    getState() { return { active: f.audioActive, error: f.audioError }; }
  };
  const sandbox = {
    VpnBackgroundTaskManager: class {},
    preferences: { getPreferences: async () => ({
      getSync: (_key, fallback) => f.preference ?? fallback,
      putSync: (_key, mode) => { f.preference = mode; f.saved.push(mode); },
      flush: async () => {}
    }) },
    BackgroundKeepaliveAudioService: class {},
    setInterval: () => 1,
    clearInterval: () => {}
  };
  const preferencesSource = readSource('../entry/src/main/ets/services/BackgroundKeepalivePreferences.ets', [
    ['export class BackgroundKeepalivePreferences', 'class BackgroundKeepalivePreferences']
  ]);
  const controllerSource = readSource('../entry/src/main/ets/services/BackgroundKeepaliveController.ets', [
    ['export class BackgroundKeepaliveController', 'class BackgroundKeepaliveController'],
    ['export const sharedVpnBackgroundTask', 'const sharedVpnBackgroundTask'],
    ['export const sharedBackgroundKeepaliveController', 'const sharedBackgroundKeepaliveController']
  ]);
  vm.runInNewContext(`${preferencesSource}\n${controllerSource}\nglobalThis.Controller = BackgroundKeepaliveController;`, sandbox);
  f.context = {};
  f.controller = new sandbox.Controller(taskManager, audioService);
  f.taskManager = taskManager;
  return f;
}

test('default off performs no task or audio playback', async () => {
  const f = controllerFixture();
  assert.equal(await f.controller.selectedMode(f.context), 'off');
  assert.equal(f.taskModes.length, 0);
  assert.equal(f.audioStarts, 0);
});

test('download mode requests only dataTransfer and persists after task confirmation', async () => {
  const f = controllerFixture();
  const result = await f.controller.activate(f.context, 'download');
  assert.equal(result.ok, true);
  assert.equal(result.taskActive, true);
  assert.deepEqual(f.taskModes, ['download']);
  assert.equal(f.audioActive, false);
  assert.equal(f.preference, 'download');
});

test('audio mode requires real renderer playback and audioPlayback task confirmation', async () => {
  const f = controllerFixture();
  const result = await f.controller.activate(f.context, 'audio');
  assert.equal(result.ok, true);
  assert.equal(result.audioActive, true);
  assert.equal(result.taskActive, true);
  assert.deepEqual(f.taskModes, ['audio']);
  assert.equal(f.preference, 'audio');
});

test('switching from audio to download releases the renderer before replacing task mode', async () => {
  const f = controllerFixture();
  await f.controller.activate(f.context, 'audio');
  const result = await f.controller.activate(f.context, 'download');
  assert.equal(result.ok, true);
  assert.equal(f.audioActive, false);
  assert.equal(f.audioStops, 1);
  assert.deepEqual(f.taskModes, ['audio', 'download']);
});

test('audio startup failure is visible and does not request audioPlayback or persist audio', async () => {
  const f = controllerFixture({ audioError: 'renderer denied' });
  const result = await f.controller.activate(f.context, 'audio');
  assert.equal(result.ok, false);
  assert.equal(result.taskActive, false);
  assert.match(result.message, /renderer denied/);
  assert.deepEqual(f.taskModes, []);
  assert.equal(f.preference, 'off');
});

test('background task failure stops real audio and does not persist active mode', async () => {
  const f = controllerFixture();
  f.taskError = 'audioPlayback rejected';
  const result = await f.controller.activate(f.context, 'audio');
  assert.equal(result.ok, false);
  assert.equal(result.taskActive, false);
  assert.equal(f.audioActive, false);
  assert.match(result.message, /audioPlayback rejected/);
  assert.equal(f.preference, 'off');
});

test('legacy location and PiP preferences migrate to off', async () => {
  for (const legacyMode of ['location', 'pip']) {
    const f = controllerFixture({ preference: legacyMode });
    assert.equal(await f.controller.selectedMode(f.context), 'off');
    assert.equal(f.preference, 'off');
    assert.deepEqual(f.saved, ['off']);
  }
});

test('deactivate and dispose release audio resources', async () => {
  const f = controllerFixture();
  await f.controller.activate(f.context, 'audio');
  const stopped = await f.controller.deactivate(f.context);
  assert.equal(stopped.mode, 'off');
  assert.equal(f.audioActive, false);
  assert.equal(f.preference, 'off');
  await f.controller.activate(f.context, 'audio');
  await f.controller.dispose();
  assert.equal(f.audioActive, false);
});

test('AudioRenderer loops nonzero PCM and reports active only in running state', async () => {
  let callback;
  let capturedSamples;
  const renderer = {
    state: 0,
    on: (_event, handler) => { callback = handler; },
    off: () => {},
    setVolume: async volume => { renderer.volume = volume; },
    start: async () => { renderer.state = 2; },
    stop: async () => { renderer.state = 3; },
    release: async () => { renderer.state = 4; }
  };
  const sandbox = { audio: {
    AudioDataCallbackResult: { VALID: 0 }, AudioState: { STATE_RUNNING: 2, STATE_PAUSED: 5 },
    AudioChannel: { CHANNEL_1: 1 }, AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 },
    AudioEncodingType: { ENCODING_TYPE_RAW: 0 }, StreamUsage: { STREAM_USAGE_MUSIC: 1 },
    createAudioRenderer: async options => { sandbox.options = options; return renderer; }
  } };
  const audioSource = readSource('../entry/src/main/ets/services/BackgroundKeepaliveAudioService.ets', [
    ['export class BackgroundKeepaliveAudioService', 'class BackgroundKeepaliveAudioService']
  ]);
  vm.runInNewContext(`${audioSource}\nglobalThis.AudioService = BackgroundKeepaliveAudioService;`, sandbox);
  const service = new sandbox.AudioService();
  assert.equal((await service.start()).active, true);
  const output = new ArrayBuffer(4096);
  callback(output);
  capturedSamples = Array.from(new Int16Array(output));
  assert.equal(capturedSamples.some(sample => sample !== 0), true);
  assert.equal(renderer.volume, 0.12);
  assert.equal(sandbox.options.rendererInfo.usage, 1);
  renderer.state = 5;
  assert.equal(service.getState().active, false);
  assert.equal((await service.stop()).active, false);
  assert.equal(renderer.state, 4);
});

test('renderer startup error never reports audio active and releases partial resources', async () => {
  const renderer = { state: 0, on: () => {}, off: () => {}, setVolume: async () => {},
    start: async () => { throw Error('no audio focus'); }, stop: async () => {},
    release: async () => { renderer.state = 4; } };
  const sandbox = { audio: {
    AudioDataCallbackResult: { VALID: 0 }, AudioState: { STATE_RUNNING: 2, STATE_PAUSED: 5 },
    AudioChannel: { CHANNEL_1: 1 }, AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 },
    AudioEncodingType: { ENCODING_TYPE_RAW: 0 }, StreamUsage: { STREAM_USAGE_MUSIC: 1 },
    createAudioRenderer: async () => renderer
  } };
  const audioSource = readSource('../entry/src/main/ets/services/BackgroundKeepaliveAudioService.ets', [
    ['export class BackgroundKeepaliveAudioService', 'class BackgroundKeepaliveAudioService']
  ]);
  vm.runInNewContext(`${audioSource}\nglobalThis.AudioService = BackgroundKeepaliveAudioService;`, sandbox);
  const state = await new sandbox.AudioService().start();
  assert.equal(state.active, false);
  assert.match(state.error, /no audio focus/);
  assert.equal(renderer.state, 4);
});

test('renderer release is attempted even when listener removal or stop throws', async () => {
  let stopCalls = 0;
  let releaseCalls = 0;
  const renderer = { state: 2, on: () => {}, off: () => { throw Error('listener cleanup failed'); },
    setVolume: async () => {}, start: async () => {},
    stop: async () => { stopCalls++; throw Error('stop failed'); },
    release: async () => { releaseCalls++; renderer.state = 4; } };
  const sandbox = { audio: {
    AudioDataCallbackResult: { VALID: 0 }, AudioState: { STATE_RUNNING: 2, STATE_PAUSED: 5 },
    AudioChannel: { CHANNEL_1: 1 }, AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 },
    AudioEncodingType: { ENCODING_TYPE_RAW: 0 }, StreamUsage: { STREAM_USAGE_MUSIC: 1 },
    createAudioRenderer: async () => renderer
  } };
  const audioSource = readSource('../entry/src/main/ets/services/BackgroundKeepaliveAudioService.ets', [
    ['export class BackgroundKeepaliveAudioService', 'class BackgroundKeepaliveAudioService']
  ]);
  vm.runInNewContext(`${audioSource}\nglobalThis.AudioService = BackgroundKeepaliveAudioService;`, sandbox);
  const service = new sandbox.AudioService();
  assert.equal((await service.start()).active, true);
  const stopped = await service.stop();
  assert.equal(stopped.active, false);
  assert.match(stopped.error, /listener cleanup failed/);
  assert.equal(stopCalls, 1);
  assert.equal(releaseCalls, 1);
  assert.equal(renderer.state, 4);
});

test('renderer startup preserves original failure while reporting cleanup failure', async () => {
  let releaseCalls = 0;
  const renderer = { state: 0, on: () => {}, off: () => { throw Error('off cleanup failed'); },
    setVolume: async () => { throw Error('volume setup failed'); }, start: async () => {},
    stop: async () => {}, release: async () => { releaseCalls++; renderer.state = 4; } };
  const sandbox = { audio: {
    AudioDataCallbackResult: { VALID: 0 }, AudioState: { STATE_RUNNING: 2, STATE_PAUSED: 5 },
    AudioChannel: { CHANNEL_1: 1 }, AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 },
    AudioEncodingType: { ENCODING_TYPE_RAW: 0 }, StreamUsage: { STREAM_USAGE_MUSIC: 1 },
    createAudioRenderer: async () => renderer
  } };
  const audioSource = readSource('../entry/src/main/ets/services/BackgroundKeepaliveAudioService.ets', [
    ['export class BackgroundKeepaliveAudioService', 'class BackgroundKeepaliveAudioService']
  ]);
  vm.runInNewContext(`${audioSource}\nglobalThis.AudioService = BackgroundKeepaliveAudioService;`, sandbox);
  const state = await new sandbox.AudioService().start();
  assert.equal(state.active, false);
  assert.match(state.error, /volume setup failed/);
  assert.match(state.error, /off cleanup failed/);
  assert.equal(releaseCalls, 1);
  assert.equal(renderer.state, 4);
});
