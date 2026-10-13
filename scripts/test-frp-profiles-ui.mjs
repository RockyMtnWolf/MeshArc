import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const page = readFileSync(new URL('../entry/src/main/ets/components/FrpProfilesPage.ets', import.meta.url), 'utf8');
const bridge = readFileSync(new URL('../entry/src/main/ets/components/BridgeStatus.ets', import.meta.url), 'utf8');

test('profiles use the multi-profile gateway and independent runtime status by profile id', () => {
  assert.match(page, /FrpProfilesGateway\.start\(this\.context\(\), profile\)/);
  assert.match(page, /FrpProfilesGateway\.stop\(this\.context\(\), profile\.id\)/);
  assert.match(page, /FrpProfilesGateway\.statuses\(this\.context\(\)\)/);
  assert.match(page, /item\.profileId === id/);
  assert.doesNotMatch(page, /FrpGateway\.(start|stop|status)\(/);
  assert.doesNotMatch(page, /activeId|activeProfileId/);
});

test('cards expose stable independent toggle, edit and delete controls', () => {
  assert.match(page, /frp-profile-toggle-\$\{profile\.id\}/);
  assert.match(page, /frp-profile-edit-\$\{profile\.id\}/);
  assert.match(page, /frp-profile-delete-\$\{profile\.id\}/);
  assert.match(page, /private busyIds: string\[\]/);
  assert.match(page, /this\.isRunning\(this\.runtimeFor\(profile\.id\)\)/);
});

test('modal supports TOML editing, form mappings, protected token and import/save without starting', () => {
  assert.match(page, /id\('frp-profile-toml-input'\)/);
  assert.match(page, /InputType\.Password/);
  assert.match(page, /ConfigDocumentGateway\.pickText\(this\.context\(\), 256 \* 1024\)/);
  assert.match(page, /parsed\.hasUnknownFields/);
  assert.match(page, /frp-profile-proxy-\$\{index\}-remote-port/);
  assert.match(page, /FrpProfileStore\.save\(this\.context\(\), next\)/);
  assert.match(page, /保存不会启动或修改正在运行的 worker/);
  assert.doesNotMatch(page, /saveProfile\(\)[\s\S]*?FrpProfilesGateway\.start/);
});

test('modal layout keeps save actions visible and page content clear of bottom navigation', () => {
  assert.match(page, /maxWidth: 980, maxHeight: '85%'/);
  assert.match(page, /\.height\('85%'\)/);
  assert.match(page, /bottom: this\.bottomInset/);
  assert.match(page, /id\('frp-profile-save'\)/);
});

test('single mapping is sufficient and removable mappings stop at one', () => {
  const reset = page.match(/private resetForm\(\): void \{([\s\S]*?)\n  private loadForm/);
  assert.ok(reset);
  assert.equal((reset[1].match(/config\.proxies\.push\(/g) ?? []).length, 1);
  assert.match(page, /while \(copied\.length < 1\)/);
  assert.match(page, /if \(this\.proxies\.length <= 1\) return/);
  assert.match(page, /\.enabled\(this\.proxies\.length > 1\)/);
});

test('empty profile defaults TLS on while imported TLS setting is retained', () => {
  assert.match(page, /config\.tlsEnable = true/);
  assert.match(page, /this\.tlsEnable = true/);
  assert.match(page, /this\.tlsEnable = config\.tlsEnable !== false/);
  assert.match(page, /Text\('启用 TLS'\)/);
});

test('page accepts Bridge scroller and layout insets without constraining modal viewport', () => {
  assert.match(page, /private scroller: Scroller = new Scroller\(\)/);
  assert.doesNotMatch(page, /@Prop scroller/);
  assert.match(page, /@Prop bottomInset: number = 112/);
  assert.match(page, /@Prop cardMaxWidth: number = 760/);
  assert.match(page, /Scroll\(this\.scroller\)/);
  assert.match(page, /maxWidth: this\.cardMaxWidth/);
  assert.match(page, /bottom: this\.bottomInset/);
  assert.match(page, /\.width\('92%'\)\.constraintSize\(\{ maxWidth: 980/);
});

test('ArkUI form fields use a builder and optional runtime error is safely narrowed', () => {
  assert.match(page, /@Builder\s+private field\(/);
  assert.match(page, /private runtimeError\(profileId: string\): string/);
  assert.match(page, /Text\(this\.runtimeError\(profile\.id\)\)/);
  assert.doesNotMatch(page, /runtimeFor\(profile\.id\)\?\.error/);
});

test('editor visibility notifies the parent and clears its bottom bar flag on disappearance', () => {
  assert.match(page, /onEditorVisibilityChange: \(visible: boolean\) => void/);
  assert.doesNotMatch(page, /@Prop onEditorVisibilityChange/);
  assert.match(page, /@State @Watch\('onModalOpenChanged'\) private modalOpen/);
  assert.match(page, /this\.onEditorVisibilityChange\(this\.modalOpen\)/);
  assert.match(page, /aboutToDisappear\(\): void \{[\s\S]*?this\.onEditorVisibilityChange\(false\)/);
});

test('editor overlay blocks clicks with a transparent background and keeps the floating card', () => {
  assert.match(page, /Column\(\)\.width\('100%'\)\.height\('100%'\)\.backgroundColor\(Color\.Transparent\)\.onClick\(\(\) => \{\}\)/);
  assert.match(page, /\.backgroundColor\(\$r\('sys\.color\.comp_background_primary'\)\)\.borderRadius\(22\)/);
  assert.match(page, /\.shadow\(\{ radius: 28/);
});

test('mode button states the destination and blank TOML switches to the default form', () => {
  assert.match(page, /this\.textMode \? '切换表单' : '切换TOML'/);
  assert.match(page, /if \(this\.tomlText\.trim\(\)\.length === 0\) \{\s*this\.textMode = false/);
});

test('controlled toggle ignores feedback matching current runtime and emits credential-safe diagnostics', () => {
  assert.match(page, /if \(shouldRun === running\) \{/);
  assert.match(page, /toggle event profileId=%\{private\}s requested=%\{public\}d running=%\{public\}d/);
  assert.match(page, /start requested profileId=%\{private\}s/);
  assert.match(page, /stop requested profileId=%\{private\}s/);
  assert.match(page, /operation completed profileId=%\{private\}s state=%\{public\}s worker=%\{public\}d connected=%\{public\}d/);
  assert.match(page, /operation failed profileId=%\{private\}s/);
  assert.doesNotMatch(page, /hilog\.(info|error)\([^\n]*\b(token|toml|serverAddr)\b/i);
});

test('protocol Select renders the selected TCP or UDP label', () => {
  assert.match(page, /\.selected\(proxy\.type === 'tcp' \? 0 : 1\)[\s\S]*?\.value\(proxy\.type === 'tcp' \? 'TCP' : 'UDP'\)/);
});

test('Bridge mobile tab bar adapts width to available window and target layout', () => {
  assert.match(bridge,
    /\.barWidth\(Math\.min\(Math\.max\(0, this\.layoutWidth - 32\), this\.layoutWidth < 600 \? 520 : 800\)\)/);
});

test('vertical local IP field does not consume Column layout weight while Row fields keep equal weight', () => {
  assert.match(page, /password: boolean = false, weight: number = 1/);
  assert.match(page, /layoutWeight\(weight\)/);
  assert.match(page, /本机 IP（建议 127\.0\.0\.1）[\s\S]*?updateProxy\(index, 'localIP', value\), false, 0\)/);
  assert.match(page, /private field\([\s\S]*?layoutWeight\(weight\)/);
});

test('FRP state and errors use theme-aware semantic colors', () => {
  assert.match(page, /\$r\('app\.color\.status_success'\)/);
  assert.match(page, /\$r\('app\.color\.status_error'\)/);
  assert.match(page, /\$r\('app\.color\.status_warning'\)/);
  assert.doesNotMatch(page, /Color\.(Green|Red|Orange)/);
});

test('profile copy distinguishes saved profiles from provider tunnel limits', () => {
  assert.match(page, /最多保存 32 份配置（不是 32 条隧道）/);
  assert.match(page, /单份配置可含多条映射，服务商实际隧道数量以套餐为准/);
  assert.match(page, /公网端口须由 frps 管理员许可/);
  assert.match(page, /return '已连接 frps'/);
  assert.doesNotMatch(page, /连接 frps 不代表外网映射已验收/);
  assert.doesNotMatch(page, /已连接 frps，仍需外网验证/);
});
