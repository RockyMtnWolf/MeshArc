import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const configSource = readFileSync(new URL('../entry/src/main/ets/services/FrpConfig.ets', import.meta.url), 'utf8');
const storeSource = readFileSync(new URL('../entry/src/main/ets/services/FrpProfileStore.ets', import.meta.url), 'utf8')
  .replace(/^import \{ common \} from '@kit\.AbilityKit';\r?\n/m, '')
  .replace(/^import \{ fileIo \} from '@kit\.CoreFileKit';\r?\n/m, 'const fileIo = globalThis.__fileIo;\n')
  .replace(/^import \{ util \} from '@kit\.ArkTS';\r?\n/m, 'const util = globalThis.__util;\n')
  .replace(/^import \{ FrpParseResult, parseFrpToml, validateFrpConfig \} from '\.\/FrpConfig';\r?\n/m, '')
  .replace(/^import \{ FrpGateway \} from '\.\/FrpGateway';\r?\n/m, 'const FrpGateway = globalThis.__FrpGateway;\n');

function createHarness() {
  const directory = mkdtempSync(join(tmpdir(), 'frp-profile-store-'));
  const fileIo = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4, READ_ONLY: 8 },
    accessSync(path) { return exists(path); },
    openSync(path, mode) {
      const flags = (mode & this.OpenMode.READ_ONLY) !== 0 ? 'r' : 'w';
      return { fd: open(path, flags), name: basename(path) };
    },
    statSync(target) {
      const stat = typeof target === 'number' ? fstat(target) : statPath(target);
      return { size: stat.size, isFile: () => stat.isFile() };
    },
    readTextSync(path) { return readFileSync(path, 'utf8'); },
    writeSync(fd, arrayBuffer) {
      const bytes = Buffer.from(arrayBuffer);
      return write(fd, bytes, 0, bytes.byteLength, null);
    },
    closeSync(file) { close(file.fd); },
    renameSync(from, to) { rename(from, to); },
    unlinkSync(path) { unlink(path); }
  };
  const util = {
    TextEncoder: class {
      encodeInto(value) { return new TextEncoder().encode(value); }
    }
  };
  const sandbox = {
    __fileIo: fileIo,
    __util: util,
    __FrpGateway: {
      load(filesDir) {
        const path = join(filesDir, 'frpc-config.toml');
        return exists(path) ? readFileSync(path, 'utf8') : '';
      }
    }
  };
  const source = stripTypeScriptTypes(`${configSource}\n${storeSource}`.replace(/^export /gm, ''));
  vm.runInNewContext(`${source}\nthis.api = { FrpProfileStore, parseFrpToml, serializeFrpToml };`, sandbox);
  return { api: sandbox.api, directory };
}

import { closeSync as close, existsSync as exists, fstatSync as fstat, openSync as open,
  renameSync as rename, statSync as statPath, unlinkSync as unlink, writeSync as write } from 'node:fs';

function withHarness(callback) {
  const harness = createHarness();
  try {
    callback(harness);
  } finally {
    rmSync(harness.directory, { recursive: true, force: true });
  }
}

const validLegacy = 'serverAddr = "host"\nserverPort = 7000\n[auth]\ntoken = "private-test"\n' +
  '[[proxies]]\nname = "web"\ntype = "tcp"\nlocalIP = "127.0.0.1"\nlocalPort = 80\nremotePort = 8080\n';

test('load migrates a valid legacy TOML to JSON and retains the original file', () => {
  withHarness(({ api, directory }) => {
    const legacyPath = join(directory, 'frpc-config.toml');
    writeFileSync(legacyPath, validLegacy, 'utf8');
    const profiles = api.FrpProfileStore.load({ filesDir: directory });
    assert.equal(profiles.length, 1);
    assert.equal(profiles[0].name, '旧版配置');
    assert.equal(profiles[0].toml, validLegacy);
    assert.ok(profiles[0].id.startsWith('legacy-'));
    assert.equal(readFileSync(legacyPath, 'utf8'), validLegacy);
    const stored = JSON.parse(readFileSync(join(directory, 'frp-profiles.json'), 'utf8'));
    assert.equal(stored[0].toml, validLegacy);
    assert.deepEqual(readdirSync(directory).filter((name) => name.endsWith('.tmp')), []);
  });
});

test('invalid legacy TOML does not create a profile or JSON store', () => {
  withHarness(({ api, directory }) => {
    writeFileSync(join(directory, 'frpc-config.toml'), 'serverAddr = "host"\nserverPort = 7000\n', 'utf8');
    assert.deepEqual(JSON.parse(JSON.stringify(api.FrpProfileStore.load({ filesDir: directory }))), []);
    assert.equal(exists(join(directory, 'frp-profiles.json')), false);
  });
});

test('save enforces 32 profiles and 256 KiB per TOML while preserving old JSON on rejection', () => {
  withHarness(({ api, directory }) => {
    const context = { filesDir: directory };
    const profile = { id: 'one', name: 'Primary', toml: validLegacy, updatedAt: 123 };
    api.FrpProfileStore.save(context, [profile]);
    const path = join(directory, 'frp-profiles.json');
    const before = readFileSync(path, 'utf8');
    assert.throws(() => api.FrpProfileStore.save(context,
      Array.from({ length: 33 }, (_, index) => ({ ...profile, id: `id-${index}` }))));
    assert.throws(() => api.FrpProfileStore.save(context,
      [{ ...profile, toml: '界'.repeat(87382) }]));
    assert.equal(readFileSync(path, 'utf8'), before);
    assert.deepEqual(JSON.parse(JSON.stringify(api.FrpProfileStore.load(context))), [profile]);
  });
});

test('load rejects duplicate profile ids and malformed JSON instead of migrating over it', () => {
  withHarness(({ api, directory }) => {
    writeFileSync(join(directory, 'frpc-config.toml'), validLegacy, 'utf8');
    writeFileSync(join(directory, 'frp-profiles.json'), '{invalid', 'utf8');
    assert.throws(() => api.FrpProfileStore.load({ filesDir: directory }));
    writeFileSync(join(directory, 'frp-profiles.json'), JSON.stringify([
      { id: 'same', name: 'A', toml: '', updatedAt: 1 },
      { id: 'same', name: 'B', toml: '', updatedAt: 2 }
    ]), 'utf8');
    assert.throws(() => api.FrpProfileStore.load({ filesDir: directory }), /字段无效/);
  });
});
