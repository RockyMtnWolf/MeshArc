import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const sourceText = readFileSync(new URL('../entry/src/main/ets/services/ConfigDocumentGateway.ets', import.meta.url), 'utf8')
  .replace(/^import \{ common \} from '@kit\.AbilityKit';\r?\n/m, '')
  .replace(/^import \{ fileIo, picker \} from '@kit\.CoreFileKit';\r?\n/m,
    'const fileIo = globalThis.__fileIo;\nconst picker = globalThis.__picker;\n')
  .replace(/^import \{ util \} from '@kit\.ArkTS';\r?\n/m, 'const util = globalThis.__util;\n');

function createHarness(contents) {
  const directory = mkdtempSync(join(tmpdir(), 'config-document-'));
  const path = join(directory, 'frpc-input.toml');
  write(path, contents);
  const readOffsets = [];
  let closed = false;
  let selected = true;
  const fileIo = {
    OpenMode: { READ_ONLY: 8 },
    openSync(_uri) { return { fd: open(path), name: basename(path) }; },
    statSync(fd) {
      const stat = fstat(fd);
      return { size: stat.size, isFile: () => stat.isFile() };
    },
    readSync(fd, buffer, options) {
      readOffsets.push(options.offset);
      return read(fd, Buffer.from(buffer), 0, Math.min(options.length, 2048), options.offset);
    },
    closeSync(file) { close(file.fd); closed = true; }
  };
  const picker = {
    DocumentViewPicker: class {
      async select() { return selected ? ['mock-document-uri'] : []; }
    }
  };
  const util = {
    TextDecoder: {
      create(encoding, options) {
        const decoder = new globalThis.TextDecoder(encoding, options);
        return { decodeWithStream: (bytes) => decoder.decode(bytes) };
      }
    }
  };
  const sandbox = { __fileIo: fileIo, __picker: picker, __util: util };
  const executable = stripTypeScriptTypes(sourceText.replace(/^export /gm, ''));
  vm.runInNewContext(`${executable}\nthis.api = ConfigDocumentGateway;`, sandbox);
  return {
    api: sandbox.api,
    context: {},
    directory,
    readOffsets,
    wasClosed: () => closed,
    selectNone: () => { selected = false; }
  };
}

import { closeSync as close, fstatSync as fstat, openSync as open, readSync as read,
  writeFileSync as write } from 'node:fs';

async function withHarness(contents, callback) {
  const harness = createHarness(contents);
  try {
    return await callback(harness);
  } finally {
    rmSync(harness.directory, { recursive: true, force: true });
  }
}

test('reads UTF-8 in chunks using file offsets and closes the picked descriptor', async () => {
  const expected = `# ${'a'.repeat(8190)}你好\nserverAddr = "loopback"\n`;
  await withHarness(expected, async ({ api, context, readOffsets, wasClosed }) => {
    const imported = await api.pickText(context, 256 * 1024);
    assert.equal(imported.name, 'frpc-input.toml');
    assert.equal(imported.text, expected);
    assert.ok(readOffsets.length > 2);
    assert.equal(readOffsets[0], 0);
    assert.ok(readOffsets.some((offset, index) => index > 0 && offset > readOffsets[index - 1]));
    assert.equal(wasClosed(), true);
  });
});

test('honors caller byte limit and the absolute 256 KiB ceiling', async () => {
  await withHarness('01234567890', async ({ api, context }) => {
    await assert.rejects(api.pickText(context, 10), /不得超过 10 字节/);
  });
  await withHarness('a'.repeat(256 * 1024 + 1), async ({ api, context }) => {
    await assert.rejects(api.pickText(context, 512 * 1024), /不得超过 262144 字节/);
  });
});

test('rejects invalid UTF-8 and still closes the descriptor', async () => {
  await withHarness(Uint8Array.from([0xC3, 0x28]), async ({ api, context, wasClosed }) => {
    await assert.rejects(api.pickText(context, 32), /有效的 UTF-8/);
    assert.equal(wasClosed(), true);
  });
});

test('picker cancellation returns undefined without opening a file', async () => {
  await withHarness('', async ({ api, context, selectNone, wasClosed }) => {
    selectNone();
    assert.equal(await api.pickText(context, 128), undefined);
    assert.equal(wasClosed(), false);
  });
});
