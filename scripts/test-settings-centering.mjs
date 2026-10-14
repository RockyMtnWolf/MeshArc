import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');

test('settings and all detail scroll surfaces center bounded content horizontally', () => {
  const builders = ['SettingsContent', 'SettingsAccountDetailContent', 'SettingsNetworkDetailContent',
    'SettingsAppearanceDetailContent', 'SettingsStorageDetailContent', 'SettingsSecurityDetailContent',
    'SettingsAboutDetailContent'];
  for (const builder of builders) {
    const start = source.indexOf(`  private ${builder}()`);
    assert.notEqual(start, -1, builder);
    const end = source.indexOf('\n  @Builder', start);
    const body = source.slice(start, end);
    assert.match(body, /maxWidth: ResponsiveLayout.SETTINGS_CONTENT_MAX_WIDTH/, builder);
    assert.match(body, /\.align\(Alignment.Top\)/, builder);
    assert.doesNotMatch(body, /\.align\(Alignment.TopStart\)/, builder);
    assert.match(body, /left: this.contentMargin\(\)/, builder);
    assert.match(body, /right: this.contentMargin\(\)/, builder);
    assert.match(body, /bottom:\s*this\.pageBottomInset\(\)\s*\}/, builder);
  }
});

test('settings preserves the capsule and reserves scroll clearance without shrinking its viewport', () => {
  assert.match(source, /\.barOverlap\(true\)/);
  const navigationPageStart = source.indexOf('  private NavigationPage(id: NavigationTabId)');
  const navigationPageEnd = source.indexOf('\n  @Builder', navigationPageStart);
  const settingsRoute = source.slice(navigationPageStart, navigationPageEnd);
  assert.match(settingsRoute, /this\.SettingsPage\(\)/);
  assert.doesNotMatch(settingsRoute, /padding\(\{ bottom: this\.pageBottomInset\(\) \}\)/);
  const settingsPageStart = source.indexOf('  private SettingsPage()');
  const settingsPageEnd = source.indexOf('\n  @Builder', settingsPageStart);
  const settingsPage = source.slice(settingsPageStart, settingsPageEnd);
  assert.match(settingsPage, /\.height\('100%'\)/);
  for (const builder of ['SettingsContent', 'SettingsAccountDetailContent', 'SettingsNetworkDetailContent',
    'SettingsAppearanceDetailContent', 'SettingsStorageDetailContent', 'SettingsSecurityDetailContent',
    'SettingsAboutDetailContent']) {
    const start = source.indexOf(`  private ${builder}()`);
    const end = source.indexOf('\n  @Builder', start);
    assert.match(source.slice(start, end), /bottom:\s*this\.pageBottomInset\(\)/, builder);
  }
  assert.match(source, /private settingsDetailCanvasBackground\(\): ResourceColor \{\s*return this\.pageCanvasBackground\(\);/);
  assert.match(source, /const FEEDBACK_EMAIL: string = 'smartwolf@stu\.xidian\.edu\.cn';/);
  assert.match(source, /mailto:\$\{FEEDBACK_EMAIL\}/);
  for (const locale of ['base', 'zh_CN']) {
    const strings = readFileSync(new URL(`../entry/src/main/resources/${locale}/element/string.json`, import.meta.url), 'utf8');
    assert.match(strings, /"name":\s*"feedback_email_address",\s*"value":\s*"smartwolf@stu\.xidian\.edu\.cn"/);
  }
});

test('all main scrolling tabs reserve bottom clearance for the floating tab bar', () => {
  for (const builder of ['HomeContent', 'TransferContent']) {
    const start = source.indexOf(`  private ${builder}()`);
    assert.notEqual(start, -1, builder);
    const end = source.indexOf('\n  @Builder', start);
    assert.match(source.slice(start, end), /bottom:\s*this\.pageBottomInset\(\)/, builder);
  }

  const filesStart = source.indexOf('  private FilesContent()');
  const filesEnd = source.indexOf('\n  @Builder', filesStart);
  assert.match(source.slice(filesStart, filesEnd), /bottomInset:\s*this\.pageBottomInset\(\)/, 'FilesContent');
  assert.match(source, /private pageBottomInset\(\): number \{\s*return 90 \+ this\.navigationBottomMargin;/);
  const settingsStart = source.indexOf('  private SettingsContent()');
  const settingsEnd = source.indexOf('\n  @Builder', settingsStart);
  assert.match(source.slice(settingsStart, settingsEnd), /bottom:\s*this\.pageBottomInset\(\)/);
});

test('changelog navigation uses stack mode instead of automatic split mode', () => {
  const changelogSource = readFileSync(new URL('../entry/src/main/ets/components/UpdateChangelogSheet.ets', import.meta.url), 'utf8');
  assert.match(changelogSource, /\.titleMode\(HdsNavigationTitleMode\.MODAL\)\s*\.mode\(NavigationMode\.Stack\)/);
});

test('background material and animation settings share stack-mode navigation', () => {
  const settingsNavigationSource = readFileSync(new URL('../entry/src/main/ets/components/NativeSettingsNavigation.ets', import.meta.url), 'utf8');
  assert.match(settingsNavigationSource, /\.titleMode\(HdsNavigationTitleMode\.MODAL\)\s*\.mode\(NavigationMode\.Stack\)/);
  assert.doesNotMatch(settingsNavigationSource, /BackgroundPreviewCard|native-settings-background-preview/);
  const backgroundPageStart = settingsNavigationSource.indexOf('  private BackgroundPage()');
  const backgroundPageEnd = settingsNavigationSource.indexOf('\n  @Builder', backgroundPageStart);
  const backgroundPage = settingsNavigationSource.slice(backgroundPageStart, backgroundPageEnd);
  assert.match(backgroundPage, /\.backgroundColor\(\$r\('sys\.color\.background_secondary'\)\)/);
  assert.match(settingsNavigationSource, /originalStyle: \{ backgroundStyle: \{ backgroundColor: \$r\('sys\.color\.background_secondary'\) \} \}/);
  const animationPageStart = settingsNavigationSource.indexOf('  private AnimationPage()');
  const animationPageEnd = settingsNavigationSource.indexOf('\n  @Builder', animationPageStart + 1);
  assert.match(settingsNavigationSource.slice(animationPageStart, animationPageEnd), /\.backgroundColor\(\$r\('sys\.color\.background_secondary'\)\)/);
  assert.match(settingsNavigationSource, /native_settings_animation'\), true\)/);
  const buildStart = settingsNavigationSource.indexOf('  build() {');
  const buildBody = settingsNavigationSource.slice(buildStart);
  assert.match(buildBody, /if \(this\.pageName === 'animation'\) \{\s*this\.AnimationPage\(\)\s*\} else \{\s*this\.BackgroundPage\(\)/);
  assert.match(buildBody, /\.backgroundColor\(\$r\('sys\.color\.background_secondary'\)\)/);
});

test('native settings sheet paints the system-colored drag bar and rounded shell', () => {
  const sheetStart = source.indexOf('.bindSheet($$this.nativeSettingsVisible');
  const sheetEnd = source.indexOf('onDisappear:', sheetStart);
  assert.match(source.slice(sheetStart, sheetEnd), /backgroundColor: \$r\('sys\.color\.background_secondary'\)/);
  assert.doesNotMatch(source.slice(sheetStart, sheetEnd), /backgroundColor: this\.pageCanvasBackground\(\)/);
  const contentStart = source.indexOf('  private NativeSettingsSheetContent()');
  const contentEnd = source.indexOf('\n  @Builder', contentStart + 1);
  assert.match(source.slice(contentStart, contentEnd), /\.backgroundColor\(\$r\('sys\.color\.background_secondary'\)\)/);
});

test('release notes describe implemented simulated keepalive behavior accurately', () => {
  const changelog = readFileSync(new URL('../entry/src/main/ets/services/ReleaseChangelog.ets', import.meta.url), 'utf8');
  assert.match(changelog, /可选模拟保活模式与桌面状态栏入口/);
  assert.match(changelog, /模拟下载不传输文件/);
  assert.match(changelog, /optional simulated keepalive modes and a desktop status-bar entry/);
  assert.match(changelog, /simulated downloads transfer no files/);
  assert.doesNotMatch(changelog, /已完成共存|FRP 已完成|coexistence completed|FRP completed/i);
});
