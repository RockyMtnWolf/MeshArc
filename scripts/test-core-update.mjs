import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/services/CoreUpdateGateway.ets', import.meta.url), 'utf8');
const commit = 'a'.repeat(40);
function fixture(options = {}) {
  const requests = [];
  let destroyed = 0;
  const responses = [
    { tag_name: 'v1.102.4', draft: false, prerelease: false,
      html_url: 'https://github.com/tailscale/tailscale/releases/tag/v1.102.4', ...options.release },
    { object: { type: options.annotated ? 'tag' : 'commit', sha: commit } },
    ...(options.annotated ? [{ object: { type: 'commit', sha: commit } }] : []),
    'module tailscale.com\ngo 1.26.6\n'
  ];
  const sandbox = {
    setTimeout, clearTimeout,
    http: { RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 0 }, createHttp: () => ({
      async request(url) {
        requests.push(url);
        if (options.hang) {
          return await new Promise(() => {});
        }
        const body = responses.shift();
        return { responseCode: options.status ?? 200, result: typeof body === 'string' ? body : JSON.stringify(body) };
      },
      destroy() { destroyed++; }
    }) }
  };
  const javascript = stripTypeScriptTypes(source.replace(/^import .*;\r?$/gm, '').replace(/^export /gm, '').replace('15000', '5'));
  vm.runInNewContext(javascript + '\nglobalThis.Gateway = CoreUpdateGateway; globalThis.compare = compareCoreVersions;', sandbox);
  return { gateway: new sandbox.Gateway(), sandbox, requests, destroyed: () => destroyed };
}

test('resolves a stable release to an immutable commit and reports unsupported Go', async () => {
  const state = fixture({ annotated: true });
  const candidate = await state.gateway.checkLatest();
  assert.equal(candidate.commit, commit);
  assert.equal(candidate.compatibleWithCurrentToolchain, false);
  assert.equal(candidate.newer, true);
  assert.equal(state.requests.length, 4);
  assert.equal(state.destroyed(), 4);
  const manifest = JSON.parse(state.gateway.exportBuildRequest(candidate));
  assert.equal(manifest.allowProductionReplacement, false);
  assert.equal(manifest.workflowStatus, 'requires_on_device_builder_and_signer');
  assert.equal(manifest.goos, 'openharmony');
});

test('rejects prerelease, malformed tags and foreign release URLs', async () => {
  for (const release of [{ prerelease: true }, { tag_name: '../main' }, { html_url: 'https://example.com/package' }]) {
    const state = fixture({ release });
    await assert.rejects(state.gateway.checkLatest());
    assert.equal(state.destroyed(), 1);
  }
});

test('rate-limit errors are visible and release the HTTP resource', async () => {
  const state = fixture({ status: 429 });
  await assert.rejects(state.gateway.checkLatest(), /Upstream HTTP 429/);
  assert.equal(state.destroyed(), 1);
});

test('an unresponsive HTTP operation is bounded and releases its resource', async () => {
  const state = fixture({ hang: true });
  await assert.rejects(state.gateway.checkLatest(), /Update request timed out/);
  assert.equal(state.destroyed(), 1);
});

test('version comparisons are numeric and requests cannot smuggle other archives', () => {
  const state = fixture();
  assert.equal(state.sandbox.compare('1.100.0', '1.99.9'), 1);
  assert.equal(state.sandbox.compare('1.24', '1.24.0'), 0);
  assert.throws(() => state.gateway.exportBuildRequest({ version: '1.1.0', tag: 'v1.1.0',
    commit, sourceURL: 'https://example.com/evil', goVersion: '1.24.5' }));
});
