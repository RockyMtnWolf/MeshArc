import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../entry/src/main/ets/services/FrpConfig.ets', import.meta.url), 'utf8');
const executable = stripTypeScriptTypes(source.replace(/^export /gm, ''));
const sandbox = {};
vm.runInNewContext(`${executable}\nthis.api = { emptyFrpConfig, parseFrpToml, serializeFrpToml, validateFrpConfig };`, sandbox);
const api = sandbox.api;

test('serializing supported fields parses back without data loss', () => {
  const config = {
    serverAddr: 'frps.example.net', serverPort: 7000, token: 's3cret',
    proxies: [{ name: 'web', type: 'tcp', localIP: '127.0.0.1', localPort: 8080, remotePort: 18080 },
      { name: 'dns', type: 'udp', localIP: '127.0.0.1', localPort: 5353, remotePort: 15353 }]
  };
  const parsed = api.parseFrpToml(api.serializeFrpToml(config));
  assert.deepEqual(JSON.parse(JSON.stringify(parsed.config)), config);
  assert.equal(parsed.hasUnknownFields, false);
});

test('unknown root, table, and proxy fields are reported for no-loss editing', () => {
  const text = 'serverAddr = "host"\nserverPort = 7000\ntoken = ""\ntransport.protocol = "quic"\n[transport]\nprotocol = "quic"\n[[proxies]]\nname = "web"\ntype = "tcp"\nlocalIP = "127.0.0.1"\nlocalPort = 80\nremotePort = 8080\nhealthCheck = true';
  const parsed = api.parseFrpToml(text);
  assert.equal(parsed.hasUnknownFields, true);
  assert.equal(parsed.warnings.length, 3);
  assert.equal(parsed.rawText, text);
});

test('auth table, dotted auth, user, and TLS fields parse without adding absent optionals', () => {
  const text = 'serverAddr = "host"\nserverPort = 7000\nuser = "desktop"\nauth.token = "secret"\n' +
    'transport.tls.enable = false\ntransport.tls.disableCustomTLSFirstByte = false\n' +
    '[[proxies]]\nname = "web"\ntype = "tcp"\nlocalIP = "127.0.0.1"\nlocalPort = 80\nremotePort = 8080';
  const parsed = api.parseFrpToml(text);
  assert.equal(parsed.hasUnknownFields, false);
  assert.equal(parsed.config.user, 'desktop');
  assert.equal(parsed.config.token, 'secret');
  assert.equal(parsed.config.tlsEnable, false);
  assert.equal(parsed.config.tlsDisableCustomTLSFirstByte, false);
  assert.equal(parsed.rawText, undefined);
  const serialized = api.serializeFrpToml(parsed.config);
  assert.match(serialized, /user = "desktop"/);
  assert.match(serialized, /\[auth\]\ntoken = "secret"/);
  assert.match(serialized, /\[transport\.tls\]\nenable = false\ndisableCustomTLSFirstByte = false/);
  assert.deepEqual(JSON.parse(JSON.stringify(api.parseFrpToml(serialized).config)),
    JSON.parse(JSON.stringify(parsed.config)));

  const tableText = 'serverAddr = "host"\nserverPort = 7000\nuser = "desktop"\n[auth]\ntoken = "secret"\n' +
    '[transport.tls]\nenable = false\ndisableCustomTLSFirstByte = false\n' +
    '[[proxies]]\nname = "web"\ntype = "tcp"\nlocalIP = "127.0.0.1"\nlocalPort = 80\nremotePort = 8080';
  const fromTables = api.parseFrpToml(tableText);
  assert.equal(fromTables.hasUnknownFields, false);
  assert.equal(fromTables.config.token, 'secret');
  assert.equal(fromTables.config.tlsEnable, false);
  assert.equal(fromTables.config.tlsDisableCustomTLSFirstByte, false);
});

test('legacy root token parses and serialization migrates it under auth', () => {
  const legacy = 'serverAddr = "host"\nserverPort = 7000\ntoken = "secret"\n' +
    '[[proxies]]\nname = "web"\ntype = "tcp"\nlocalIP = "127.0.0.1"\nlocalPort = 80\nremotePort = 8080';
  const parsed = api.parseFrpToml(legacy);
  assert.deepEqual(Object.keys(parsed.config).sort(), ['proxies', 'serverAddr', 'serverPort', 'token']);
  const serialized = api.serializeFrpToml(parsed.config);
  assert.match(serialized, /\[auth\]\ntoken = "secret"/);
  assert.doesNotMatch(serialized.split('\n[auth]\n')[0], /^token\s*=/m);
  assert.equal(api.parseFrpToml(serialized).config.token, 'secret');
});

test('duplicate legacy and canonical auth tokens are rejected', () => {
  assert.throws(() => api.parseFrpToml('token = "a"\n[auth]\ntoken = "b"'), /重复/);
});

test('hash characters inside quoted strings survive with trailing comments', () => {
  const text = `serverAddr = "host" # endpoint comment
serverPort = 7000
user = "desk#top" # user comment
[auth]
token = "secret#fragment" # token comment
[[proxies]]
name = "web#primary"
type = "tcp"
localIP = "127.0.0.1"
localPort = 80
remotePort = 8080`;
  const parsed = api.parseFrpToml(text);
  assert.equal(parsed.config.user, 'desk#top');
  assert.equal(parsed.config.token, 'secret#fragment');
  assert.equal(parsed.config.proxies[0].name, 'web#primary');
  assert.equal(parsed.hasUnknownFields, false);
});

test('escaped quotes do not end a quoted string during comment scanning', () => {
  const parsed = api.parseFrpToml(String.raw`serverAddr = "host"
serverPort = 7000
[auth]
token = "quote\"#still-string" # trailing note
[[proxies]]
name = "web"
type = "tcp"
localIP = "127.0.0.1"
localPort = 80
remotePort = 8080`);
  assert.equal(parsed.config.token, 'quote"#still-string');
  assert.equal(parsed.hasUnknownFields, false);
});

test('malformed ports and duplicate fields are rejected', () => {
  assert.throws(() => api.parseFrpToml('serverPort = 70000'), /0–65535/);
  assert.throws(() => api.parseFrpToml('serverAddr = "a"\nserverAddr = "b"'), /重复/);
});

test('configuration validation requires one uniquely named valid mapping', () => {
  assert.ok(api.validateFrpConfig(api.emptyFrpConfig()).length > 0);
  const valid = { serverAddr: 'host', serverPort: 7000, token: '',
    proxies: [{ name: 'web', type: 'tcp', localIP: '127.0.0.1', localPort: 80, remotePort: 8080 }] };
  assert.equal(api.validateFrpConfig(valid).length, 0);
  valid.proxies.push({ ...valid.proxies[0] });
  assert.ok(api.validateFrpConfig(valid).some((error) => error.includes('不能重复')));
});
