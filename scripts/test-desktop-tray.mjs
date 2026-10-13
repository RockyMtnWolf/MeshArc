import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import test from 'node:test';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (relativePath) => readFileSync(path.join(root, relativePath), 'utf8');
const trayServiceSource = read('entry/src/main/ets/services/DesktopTrayService.ets');
const entryAbility = read('entry/src/main/ets/entryability/EntryAbility.ets');
const extensionAbility = read('entry/src/main/ets/statusbarviewextensionability/MeshArcStatusBarAbility.ets');
const page = read('entry/src/main/ets/pages/StatusBarPage.ets');
const moduleConfig = JSON.parse(read('entry/src/main/module.json5'));
const pages = JSON.parse(read('entry/src/main/resources/base/profile/main_pages.json'));
const trayServiceJavaScript = stripTypeScriptTypes(trayServiceSource
  .replace(/^import .*;\r?$/gm, '')
  .replace('export class DesktopTrayService', 'class DesktopTrayService') +
  '\nglobalThis.DesktopTrayService = DesktopTrayService;');
const entryAbilityJavaScript = stripTypeScriptTypes(entryAbility
  .replace(/^import\s*\{[\s\S]*?\}\s*from\s*'[^']+';\r?\n/gm, '')
  .replace(/^import .*;\r?\n/gm, '')
  .replace(/^const DOMAIN = .*;\r?\n/m, '')
  .replace(/^const TAG = .*;\r?\n/m, '')
  .replace('export default class EntryAbility', 'class EntryAbility') +
  '\nglobalThis.EntryAbility = EntryAbility;');

function deferred() {
  let resolve;
  const promise = new Promise((finish) => { resolve = finish; });
  return { promise, resolve };
}

async function flush() {
  await new Promise((resolve) => setImmediate(resolve));
}

function fixture(options = {}) {
  const state = {
    sdkApiVersion: options.sdkApiVersion ?? 26,
    deviceType: options.deviceType ?? '2in1',
    supported: options.supported ?? true,
    capabilityCalls: 0,
    rawFiles: [],
    sources: [],
    pixelMaps: [],
    addedItems: [],
    removals: 0,
    hideAbilityCalls: 0,
    hideAbilityError: false,
    showAbilityCalls: 0,
    failPixelMapAt: options.failPixelMapAt ?? -1,
    pixelMapGate: options.pixelMapGate
  };
  const sandbox = {
    deviceInfo: {
      sdkApiVersion: state.sdkApiVersion,
      deviceType: state.deviceType,
      DeviceTypes: { TYPE_2IN1: '2in1' }
    },
    statusBarManager: {
      isStatusBarCapabilitySupported: async () => {
        state.capabilityCalls++;
        return state.supported;
      },
      addToStatusBar: (_context, item) => state.addedItems.push(item),
      removeFromStatusBar: () => { state.removals++; }
    },
    image: {
      createImageSource: () => {
        const sourceIndex = state.sources.length;
        const source = {
          released: 0,
          async createPixelMap() {
            if (state.pixelMapGate?.sourceIndex === sourceIndex) {
              state.pixelMapGate.entered.resolve();
              await state.pixelMapGate.promise;
            }
            if (state.failPixelMapAt === sourceIndex) {
              throw new Error('mock image decode failure');
            }
            const pixelMap = {
              released: 0,
              async release() { pixelMap.released++; }
            };
            state.pixelMaps.push(pixelMap);
            return pixelMap;
          },
          async release() { source.released++; }
        };
        state.sources.push(source);
        return source;
      }
    },
    hilog: { warn: () => {}, info: () => {} },
    trayRegistered: false,
    minimizeCalls: 0,
    minimizeError: false
  };
  vm.runInNewContext(trayServiceJavaScript, sandbox);
  sandbox.sharedVpnBackgroundTask = {};
  sandbox.sharedBackgroundKeepaliveController = {};
  sandbox.AppShellIntentAdapter = class {};
  sandbox.WindowEnvironment = class {};
  sandbox.UIAbility = class {};
  sandbox.APP_FOREGROUND_EVENT = 'foreground';
  sandbox.DiagnosticPrivacy = { formatLogError: () => '' };
  sandbox.notificationManager = {};
  sandbox.ConfigurationConstant = {};
  sandbox.Configuration = {};
  sandbox.AbilityConstant = {};
  sandbox.Want = {};
  sandbox.window = {};
  vm.runInNewContext(entryAbilityJavaScript, sandbox);
  const context = {
    async hideAbility() {
      state.hideAbilityCalls++;
      if (state.hideAbilityError) throw new Error('hide ability failed');
    },
    async showAbility() {
      state.showAbilityCalls++;
    },
    resourceManager: {
      getRawFileContentSync(fileName) {
        state.rawFiles.push(fileName);
        return { buffer: new ArrayBuffer(1) };
      }
    }
  };
  sandbox.context = context;
  state.service = new sandbox.DesktopTrayService();
  state.context = context;
  state.sandbox = sandbox;
  return state;
}

test('skips unsupported devices and API versions before loading tray icons', async () => {
  for (const options of [{ deviceType: 'tablet' }, { sdkApiVersion: 25 }]) {
    const state = fixture(options);
    state.service.register(state.context);
    await flush();
    assert.equal(state.capabilityCalls, 0);
    assert.equal(state.rawFiles.length, 0);
    assert.equal(state.addedItems.length, 0);
  }

  const unsupportedCapability = fixture({ supported: false });
  unsupportedCapability.service.register(unsupportedCapability.context);
  await flush();
  assert.equal(unsupportedCapability.capabilityCalls, 1);
  assert.equal(unsupportedCapability.rawFiles.length, 0);
  assert.equal(unsupportedCapability.addedItems.length, 0);
});

test('registers the status bar item and releases it on dispose', async () => {
  const state = fixture();
  state.service.register(state.context);
  await flush();

  assert.equal(state.addedItems.length, 1);
  assert.equal(state.service.isRegistered(), true);
  assert.deepEqual(state.rawFiles, ['mesh_arc_status_white.svg', 'mesh_arc_status_black.svg']);
  assert.equal(state.sources.length, 2);
  assert.ok(state.sources.every((source) => source.released === 1));
  assert.equal(state.addedItems[0].quickOperation.abilityName, 'MeshArcStatusBarAbility');
  assert.equal(state.addedItems[0].statusBarGroupMenu[0][0].menuAction.abilityName, 'EntryAbility');

  state.service.dispose(state.context);
  assert.equal(state.service.isRegistered(), false);
  assert.equal(state.removals, 1);
  assert.ok(state.pixelMaps.every((pixelMap) => pixelMap.released === 1));
});

test('dispose during icon loading prevents registration and releases both images', async () => {
  const gate = { sourceIndex: 0, ...deferred(), entered: deferred() };
  const state = fixture({ pixelMapGate: gate });
  state.service.register(state.context);
  await gate.entered.promise;
  state.service.dispose(state.context);
  gate.resolve();
  await flush();

  assert.equal(state.addedItems.length, 0);
  assert.equal(state.removals, 0);
  assert.ok(state.pixelMaps.every((pixelMap) => pixelMap.released === 1));
  assert.ok(state.sources.every((source) => source.released === 1));
});

test('image loading failure releases earlier maps and image sources', async () => {
  const state = fixture({ failPixelMapAt: 1 });
  state.service.register(state.context);
  await flush();

  assert.equal(state.addedItems.length, 0);
  assert.equal(state.sources.length, 2);
  assert.ok(state.sources.every((source) => source.released === 1));
  assert.equal(state.pixelMaps.length, 1);
  assert.equal(state.pixelMaps[0].released, 1);
  state.service.dispose(state.context);
  assert.equal(state.removals, 0);
});

test('wires tray lifecycle, extension page, bundle identity, and module metadata', () => {
  assert.match(entryAbility, /desktopTrayService\.register\(this\.context\)/);
  assert.match(entryAbility, /desktopTrayService\.dispose\(this\.context\)/);
  assert.match(entryAbility, /mainWindow\.on\('windowWillClose', this\.handleWindowWillClose\)/);
  assert.match(entryAbility, /mainWindow\.off\('windowWillClose', this\.handleWindowWillClose\)/);
  assert.doesNotMatch(entryAbility, /releaseKeepalivePipHost|BackgroundKeepalivePipHostFactory/);
  assert.match(extensionAbility, /session\.loadContent\('pages\/StatusBarPage'\)/);
  assert.doesNotMatch(extensionAbility, /loadContent\([^;]*\)\.(then|catch)/);
  assert.match(page, /bundleName: context\.applicationInfo\.name/);
  assert.match(page, /desktopTrayAction: 'open'/);
  assert.doesNotMatch(page, /io\.github\.tailscaleohos/);
  assert.doesNotMatch(trayServiceSource + page, /BackgroundTasksKit|LocationKit|Pip|PictureInPicture/i);

  const statusBarAbility = moduleConfig.module.extensionAbilities.find((ability) =>
    ability.name === 'MeshArcStatusBarAbility');
  assert.equal(statusBarAbility?.type, 'statusBarView');
  assert.equal(statusBarAbility?.exported, true);
  assert.ok(pages.src.includes('pages/StatusBarPage'));
  for (const iconName of ['mesh_arc_status_white.svg', 'mesh_arc_status_black.svg']) {
    assert.match(read(`entry/src/main/resources/rawfile/${iconName}`), /width="24" height="24"/);
  }
});

test('hides the UIAbility on close only after tray registration', async () => {
  const state = fixture();
  vm.runInNewContext(`
    globalThis.ability = new EntryAbility();
    globalThis.ability.context = globalThis.context;
    globalThis.ability.mainWindow = {
      minimize: async () => {
        globalThis.minimizeCalls++;
        if (globalThis.minimizeError) throw new Error('minimize failed');
      }
    };
    globalThis.ability.desktopTrayService = { isRegistered: () => globalThis.trayRegistered };
  `, state.sandbox);

  state.sandbox.trayRegistered = false;
  assert.equal(await state.sandbox.ability.handleWindowWillClose(), false);
  assert.equal(state.sandbox.minimizeCalls, 0);
  assert.equal(state.hideAbilityCalls, 0);

  state.sandbox.trayRegistered = true;
  assert.equal(await state.sandbox.ability.handleWindowWillClose(), true);
  assert.equal(state.hideAbilityCalls, 1);
  assert.equal(state.sandbox.minimizeCalls, 0);
});

test('falls back to minimize when UIAbility hide fails and allows close if both fail', async () => {
  const state = fixture();
  vm.runInNewContext(`
    globalThis.ability = new EntryAbility();
    globalThis.ability.context = globalThis.context;
    globalThis.ability.mainWindow = {
      minimize: async () => {
        globalThis.minimizeCalls++;
        if (globalThis.minimizeError) throw new Error('minimize failed');
      }
    };
    globalThis.ability.desktopTrayService = { isRegistered: () => globalThis.trayRegistered };
  `, state.sandbox);

  state.sandbox.trayRegistered = true;
  state.hideAbilityError = true;
  assert.equal(await state.sandbox.ability.handleWindowWillClose(), true);
  assert.equal(state.sandbox.minimizeCalls, 1);

  state.sandbox.minimizeError = true;
  assert.equal(await state.sandbox.ability.handleWindowWillClose(), false);
  assert.equal(state.sandbox.minimizeCalls, 2);
});

test('restores the hidden ability from the tray open action using its UIAbility context', async () => {
  const state = fixture();
  vm.runInNewContext(`
    globalThis.ability = new EntryAbility();
    globalThis.ability.context = globalThis.context;
    globalThis.ability.appShellContentReady = true;
    globalThis.ability.appShellIntentAdapter = {
      toFeatureAction: () => ({ openTaildropInbox: false, taildropNotificationAction: '' })
    };
    globalThis.ability.desktopTrayService = { isRegistered: () => globalThis.trayRegistered };
  `, state.sandbox);

  state.sandbox.trayRegistered = true;
  state.sandbox.ability.onNewWant({ parameters: { desktopTrayAction: 'open' } }, {});
  await flush();
  assert.equal(state.showAbilityCalls, 1);
});
