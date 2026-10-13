import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const scriptPath = fileURLToPath(new URL('./prepare-isolated-dev.ps1', import.meta.url));
const powershell = process.env.POWERSHELL_EXE || (process.platform === 'win32' ? 'powershell.exe' : 'pwsh');

function writeFixtureFile(root, relativePath, content) {
  const fullPath = path.join(root, relativePath);
  mkdirSync(path.dirname(fullPath), { recursive: true });
  writeFileSync(fullPath, content);
}

function createFixture(t, sourceBundleName = 'io.github.tailscaleohos') {
  const temporaryRoot = mkdtempSync(path.join(os.tmpdir(), 'tailscale-isolated-dev-'));
  t.after(() => rmSync(temporaryRoot, { recursive: true, force: true }));

  const source = path.join(temporaryRoot, 'source');
  mkdirSync(path.join(source, 'scripts'), { recursive: true });
  writeFileSync(path.join(source, 'scripts', 'prepare-isolated-dev.ps1'), readFileSync(scriptPath));
  writeFixtureFile(source, 'AppScope/app.json5', `{"app":{"bundleName":"${sourceBundleName}","label":"$string:app_name"}}\n`);
  writeFixtureFile(source, 'AppScope/resources/base/element/string.json', '{"string":[{"name":"app_name","value":"MeshArc"}]}\n');
  writeFixtureFile(source, 'entry/src/main/resources/base/element/string.json',
    '{"string":[{"name":"entryability_label","value":"MeshArc"},{"name":"preserved","value":"Keep me"}]}\n');
  writeFixtureFile(source, 'entry/src/main/resources/zh_CN/element/string.json',
    '{\n  "string": [\n    { "name": "entryability_label", "value": "MeshArc" },\n    { "name": "preserved", "value": "原样保留" }\n  ]\n}\n');
  writeFixtureFile(source, 'entry/src/main/resources/en_US/element/string.json',
    '{"string":[{"name":"entryability_label","value":"MeshArc"},{"name":"preserved","value":"Keep it"}]}\n');
  writeFixtureFile(source, 'build-profile.example.json5', '{"app":{"signingConfigs":[]}}\n');
  for (const [file, value] of [
    ['one.ets', `const BUNDLE_NAME = '${sourceBundleName}';\n`],
    ['two.ets', `bundleName: '${sourceBundleName}',\n`],
    ['three.ets', `const NAME: string = '${sourceBundleName}';\n`],
    ['four.ets', `const OTHER = '${sourceBundleName}';\n`]
  ]) {
    writeFixtureFile(source, `entry/src/main/ets/${file}`, value);
  }
  writeFixtureFile(source, 'entry/src/main/ets/tray/NewTray.ets', 'export const traySource = true;\n');
  writeFixtureFile(source, 'entry/src/main/resources/base/element/tray.json', '{"string":[]}\n');
  writeFixtureFile(source, 'untracked.txt', 'must not be copied\n');
  execFileSync('git', ['-C', source, 'init', '--quiet']);
  execFileSync('git', ['-C', source, 'add', 'scripts', 'AppScope', 'build-profile.example.json5',
    'entry/src/main/resources/base/element/string.json', 'entry/src/main/resources/zh_CN/element/string.json',
    'entry/src/main/ets/one.ets', 'entry/src/main/ets/two.ets',
    'entry/src/main/ets/three.ets', 'entry/src/main/ets/four.ets']);

  return { source, temporaryRoot };
}

function runPreparation(source, target, additionalSourcePaths = []) {
  const quotePowerShell = value => `'${value.replaceAll("'", "''")}'`;
  let command = `& ${quotePowerShell(path.join(source, 'scripts', 'prepare-isolated-dev.ps1'))}` +
    ` -TargetDirectory ${quotePowerShell(target)}`;
  if (additionalSourcePaths.length > 0) {
    command += ` -AdditionalSourcePaths @(${additionalSourcePaths.map(quotePowerShell).join(', ')})`;
  }
  return spawnSync(powershell, ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', command], {
    encoding: 'utf8',
    windowsHide: true
  });
}

test('copies tracked files to a separate dev identity without repository metadata', t => {
  const { source, temporaryRoot } = createFixture(t);
  const target = path.join(temporaryRoot, 'isolated-copy');
  const result = runPreparation(source, target);

  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout + result.stderr, /io\.github\.tailscaleohos\.devtest/);
  assert.match(result.stdout + result.stderr, /Dev Test/);
  assert.match(result.stdout + result.stderr, /Native dependencies/i);
  assert.equal(JSON.parse(readFileSync(path.join(target, 'AppScope/app.json5'), 'utf8')).app.bundleName,
    'io.github.tailscaleohos.devtest');
  assert.match(readFileSync(path.join(target, 'AppScope/resources/base/element/string.json'), 'utf8'), /MeshArc Dev Test/);
  for (const locale of ['base', 'zh_CN']) {
    const strings = JSON.parse(readFileSync(path.join(target, `entry/src/main/resources/${locale}/element/string.json`), 'utf8'));
    assert.equal(strings.string.find(item => item.name === 'entryability_label').value, 'MeshArc Dev Test');
    assert.equal(strings.string.find(item => item.name === 'preserved').value, locale === 'base' ? 'Keep me' : '原样保留');
  }
  assert.equal(readFileSync(path.join(target, 'build-profile.json5'), 'utf8'),
    readFileSync(path.join(source, 'build-profile.example.json5'), 'utf8'));
  assert.equal(existsSync(path.join(target, '.git')), false);
  assert.equal(existsSync(path.join(target, 'untracked.txt')), false);
  assert.equal(existsSync(path.join(target, 'entry/src/main/ets/tray/NewTray.ets')), false);
  for (const name of ['one.ets', 'two.ets', 'three.ets', 'four.ets']) {
    const content = readFileSync(path.join(target, 'entry/src/main/ets', name), 'utf8');
    assert.equal(content.match(/io\.github\.tailscaleohos\.devtest/g)?.length, 1);
    assert.doesNotMatch(content, /io\.github\.tailscaleohos(?!\.devtest)/);
  }
  assert.equal(readFileSync(path.join(source, 'AppScope/app.json5'), 'utf8'),
    `{"app":{"bundleName":"io.github.tailscaleohos","label":"$string:app_name"}}\n`);
});

test('uses the configured source identity when deriving an isolated devtest bundle', t => {
  const sourceBundleName = 'io.github.rockymtnwolf.mesharc';
  const { source, temporaryRoot } = createFixture(t, sourceBundleName);
  const target = path.join(temporaryRoot, 'isolated-from-formal-identity');
  const result = runPreparation(source, target);

  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.equal(JSON.parse(readFileSync(path.join(target, 'AppScope/app.json5'), 'utf8')).app.bundleName,
    'io.github.tailscaleohos.devtest');
  for (const name of ['one.ets', 'two.ets', 'three.ets', 'four.ets']) {
    const content = readFileSync(path.join(target, 'entry/src/main/ets', name), 'utf8');
    assert.equal(content.match(/io\.github\.tailscaleohos\.devtest/g)?.length, 1);
    assert.doesNotMatch(content, /io\.github\.rockymtnwolf\.mesharc/);
  }
  assert.equal(JSON.parse(readFileSync(path.join(source, 'AppScope/app.json5'), 'utf8')).app.bundleName,
    sourceBundleName);
});

test('copies only explicitly listed untracked source and resource files', t => {
  const { source, temporaryRoot } = createFixture(t);
  const target = path.join(temporaryRoot, 'isolated-with-tray');
  const result = runPreparation(source, target, [
    'entry/src/main/ets/tray/NewTray.ets',
    'entry/src/main/resources/base/element/tray.json',
    'entry/src/main/resources/en_US/element/string.json'
  ]);

  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.equal(readFileSync(path.join(target, 'entry/src/main/ets/tray/NewTray.ets'), 'utf8'),
    'export const traySource = true;\n');
  assert.equal(readFileSync(path.join(target, 'entry/src/main/resources/base/element/tray.json'), 'utf8'),
    '{"string":[]}\n');
  const enStrings = JSON.parse(readFileSync(path.join(target, 'entry/src/main/resources/en_US/element/string.json'), 'utf8'));
  assert.equal(enStrings.string.find(item => item.name === 'entryability_label').value, 'MeshArc Dev Test');
  assert.equal(enStrings.string.find(item => item.name === 'preserved').value, 'Keep it');
  assert.equal(existsSync(path.join(target, 'untracked.txt')), false);
});

test('rejects unsafe or non-file additional paths before creating the destination', t => {
  const { source, temporaryRoot } = createFixture(t);
  const invalidPaths = [
    path.join(source, 'untracked.txt'),
    '../outside.txt',
    '.git/config',
    'entry/src/main/ets/tray',
    'does-not-exist.ets'
  ];

  for (const [index, invalidPath] of invalidPaths.entries()) {
    const target = path.join(temporaryRoot, `invalid-target-${index}`);
    const result = runPreparation(source, target, [invalidPath]);
    assert.notEqual(result.status, 0, `unexpectedly accepted ${invalidPath}`);
    assert.equal(existsSync(target), false, `created destination for ${invalidPath}`);
  }
});

test('rejects an existing target and any target inside the source repository', t => {
  const { source, temporaryRoot } = createFixture(t);
  const existing = path.join(temporaryRoot, 'already-here');
  mkdirSync(existing);
  writeFileSync(path.join(existing, 'keep.txt'), 'preserve');
  const existingResult = runPreparation(source, existing);
  assert.notEqual(existingResult.status, 0);
  assert.equal(readFileSync(path.join(existing, 'keep.txt'), 'utf8'), 'preserve');

  const inside = path.join(source, 'nested-copy');
  const insideResult = runPreparation(source, inside);
  assert.notEqual(insideResult.status, 0);
  assert.equal(existsSync(inside), false);
});
