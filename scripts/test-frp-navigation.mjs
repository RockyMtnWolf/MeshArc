import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');

test('FRP navigation has one profile page tab and no legacy page rendering', () => {
  assert.match(source, /import \{ FrpProfilesPage \} from '\.\/FrpProfilesPage';/);
  assert.match(source, /case 'frp': return 'FRP';/);
  assert.match(source, /case 'frp': return \$r\('app\.media\.tab_frp'\)/);
  assert.match(source, /id === 'frp'[\s\S]*?this\.FrpPage\(\)/);
  assert.doesNotMatch(source, /frp-home|frp-config|FrpRuntimePanel|FrpSettings/);
});

test('FRP component owns scrolling within a fixed full-page viewport', () => {
  const page = source.slice(source.indexOf('private FrpPage()'), source.indexOf('private MobileTabs()'));
  assert.match(page, /Stack\(\)\s*\{\s*FrpProfilesPage\(\{[\s\S]*?scroller: this\.frpScroller,[\s\S]*?bottomInset: this\.pageBottomInset\(\),[\s\S]*?cardMaxWidth: ResponsiveLayout\.SETTINGS_CONTENT_MAX_WIDTH/);
  assert.match(page, /onEditorVisibilityChange: \(visible: boolean\) => this\.frpEditorVisible = visible/);
  assert.match(page, /\}\.width\('100%'\)\.height\('100%'\)/);
  assert.doesNotMatch(page, /Scroll\(/);
  assert.match(page, /backgroundColor\(this\.pageCanvasBackground\(\)\)/);
  assert.match(page, /\.bindToScrollable\(\[this\.frpScroller\]\)/);
});

test('FRP editor hides the floating tab bar and disables swipe until it closes', () => {
  assert.match(source, /@State frpEditorVisible: boolean = false;/);
  assert.match(source, /\.barHeight\(this\.frpEditorVisible \? 0 : 56\)/);
  assert.match(source, /\.barMode\(BarMode\.Fixed\)/);
  assert.match(source, /\.scrollable\(!this\.settingsDetailActive && !this\.deviceDetailVisible && !this\.frpEditorVisible\)/);
  assert.match(source, /if \(id !== 'frp'\) \{\s*this\.frpEditorVisible = false;/);
  assert.match(source, /if \(selectedId !== 'frp'\) \{\s*this\.frpEditorVisible = false;/);
});
