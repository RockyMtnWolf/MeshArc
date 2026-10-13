import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/components/ClashCoexistenceSettings.ets', import.meta.url), 'utf8');

test('inbound TCP policy uses the native JSON contract and reads backend status', () => {
  assert.match(source, /inboundTCPPorts: number\[\];[\s\S]*?inboundTCPEnabled: boolean;[\s\S]*?inboundTCPAllowAll: boolean;/);
  assert.match(source, /coexistenceSetInboundTCPPolicyAsync\(JSON\.stringify\(\{ allowAll: allowAll, ports: ports \}\)\)/);
  assert.match(source, /this\.applyStatus\(state, forceDraftSync\)/);
  assert.match(source, /state\.error\.length > 0 \? state\.error/);
});

test('selected ports are edited one per row and applied separately with explicit confirmation', () => {
  assert.match(source, /ForEach\(this\.inboundTCPPortDrafts/);
  assert.match(source, /placeholder: 'TCP 端口，例如 3240'/);
  assert.match(source, /private addInboundPortDraft\(\)/);
  assert.match(source, /private removeInboundPortDraft\(index: number\)/);
  assert.match(source, /Button\('添加端口'\)/);
  assert.match(source, /Button\('应用列表'\)/);
  assert.match(source, /primaryButton: \{ value: '应用列表', action: \(\) => this\.setInboundTCPPolicy\(false, ports, true\) \}/);
  assert.match(source, /仅允许 Tailnet 中通过 ACL 的设备访问以下本机 loopback 服务；不会开放其他端口，也不会暴露到公网/);
  assert.match(source, /this\.setInboundTCPPolicy\(false, \[\], true\)/);
});

test('refresh preserves dirty drafts; successful policy responses synchronize applied ports', () => {
  assert.match(source, /private applyStatus\(state: CoexistenceStatus, forceDraftSync: boolean = false\): void/);
  assert.match(source, /if \(forceDraftSync \|\| !this\.inboundPortsDraftDirty\) \{\s*this\.syncInboundPortDrafts\(state\.inboundTCPPorts\);/);
  assert.match(source, /this\.inboundPortsDraftDirty = true/);
  assert.match(source, /this\.applyStatus\(state, forceDraftSync\);/);
  assert.match(source, /this\.syncInboundPortDrafts\(state\.inboundTCPPorts\)/);
});

test('allow-all starts off, requires coexistence and a separate risk confirmation', () => {
  assert.match(source, /@State private inboundTCPAllowAll: boolean = false/);
  assert.match(source, /enabled\(!this\.busy && this\.active\)[\s\S]*?confirmAllowAllInboundTCP/);
  assert.match(source, /if \(this\.busy \|\| !this\.active\) return;[\s\S]*?确认允许全部本机 TCP 入站/);
  assert.match(source, /Tailnet 中已通过 ACL 的设备连接本机所有 TCP 服务端口/);
  assert.match(source, /不对公网暴露/);
  assert.match(source, /127\.0\.0\.1:1055 不作为入站服务开放/);
  assert.match(source, /if \(!this\.inboundTCPAllowAll\) \{\s*ForEach\(this\.inboundTCPPortDrafts/);
  assert.match(source, /this\.setInboundTCPPolicy\(false, this\.inboundTCPPorts\)/);
});

test('ClashBox guidance puts rules at the start, and config repair exports a new copy', () => {
  assert.match(source, /将两条规则插入 rules 列表开头/);
  assert.match(source, /请将规则插入 ClashBox 的 rules 列表开头/);
  assert.doesNotMatch(source, /规则置于 MATCH 前/);
  assert.match(source, /ClashConfigRepairGateway\.importAndExport\(context\)/);
  assert.match(source, /Button\('导入并导出修补副本'\)/);
  assert.match(source, /导出新副本，不修改原文件/);
});
