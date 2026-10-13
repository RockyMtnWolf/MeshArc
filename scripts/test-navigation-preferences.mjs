import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

function preferencesFixture(values = {}) {
  const state = { ...values };
  const writes = [];
  const sandbox = {
    preferences: {
      getPreferences: async () => ({
        getSync: (key, fallback) => state[key] ?? fallback,
        putSync: (key, value) => {
          state[key] = value;
          writes.push([key, value]);
        },
        flush: async () => {}
      })
    }
  };
  let source = readFileSync(new URL('../entry/src/main/ets/services/NavigationPreferences.ets', import.meta.url), 'utf8')
    .replace(/^import .*;\r?$/gm, '')
    .replace('export class NavigationPreferences', 'class NavigationPreferences')
    .replaceAll('export const ', 'const ');
  source = stripTypeScriptTypes(source);
  vm.runInNewContext(`${source}\nglobalThis.NavigationPreferences = NavigationPreferences;`, sandbox);
  return { preferences: sandbox.NavigationPreferences, state, writes };
}

test('new installations use the five-tab default order with one FRP tab', async () => {
  const fixture = preferencesFixture();
  const settings = await fixture.preferences.load({});
  assert.equal(JSON.stringify(settings.order), JSON.stringify([
    'home', 'transfer', 'files', 'frp', 'settings'
  ]));
  assert.deepEqual(JSON.parse(JSON.stringify(settings.hidden)), []);
});

test('migrates the old four-tab order before settings and preserves existing relative order', async () => {
  const fixture = preferencesFixture({
    navigation_order: 'transfer,settings,files,home',
    navigation_hidden: 'files',
    navigation_bottom_margin: 30
  });
  const settings = await fixture.preferences.load({});
  assert.equal(JSON.stringify(settings.order), JSON.stringify([
    'transfer', 'frp', 'settings', 'files', 'home'
  ]));
  assert.equal(fixture.state.navigation_order,
    'transfer,frp,settings,files,home');
  assert.deepEqual(JSON.parse(JSON.stringify(settings.hidden)), ['files']);
  assert.equal(fixture.writes.length, 2);
});

test('deduplicates known ids, discards invalid ids, and never hides settings', async () => {
  const fixture = preferencesFixture({
    navigation_order: 'files,frp-home,frp-home,bad,settings,home,home',
    navigation_hidden: 'settings,frp-home,bad,frp-home'
  });
  const settings = await fixture.preferences.load({});
  assert.equal(JSON.stringify(settings.order), JSON.stringify([
    'files', 'frp', 'transfer', 'settings', 'home'
  ]));
  assert.deepEqual(JSON.parse(JSON.stringify(settings.hidden)), []);
  assert.equal(settings.hidden.includes('settings'), false);
});

test('hides the migrated FRP tab only when both old tabs were hidden', async () => {
  const oneHidden = preferencesFixture({
    navigation_order: 'home,transfer,files,frp-home,frp-config,settings',
    navigation_hidden: 'frp-home'
  });
  const oneHiddenSettings = await oneHidden.preferences.load({});
  assert.equal(oneHiddenSettings.hidden.includes('frp'), false);

  const bothHidden = preferencesFixture({
    navigation_order: 'home,transfer,files,frp-home,frp-config,settings',
    navigation_hidden: 'frp-home,frp-config'
  });
  const bothHiddenSettings = await bothHidden.preferences.load({});
  assert.deepEqual(JSON.parse(JSON.stringify(bothHiddenSettings.hidden)), ['frp']);
});
