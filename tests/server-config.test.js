const assert = require('node:assert/strict');
const test = require('node:test');

async function importFresh(modulePath) {
  return import(`${modulePath}?t=${Date.now()}-${Math.random()}`);
}

test('server binds externally by default so remote clients can connect', async () => {
  delete process.env.OMO_SWITCHER_HOST;

  const { config } = await importFresh('../server/src/config.js');

  assert.equal(config.host, '0.0.0.0');
});

test('server host can still be restricted with OMO_SWITCHER_HOST', async () => {
  process.env.OMO_SWITCHER_HOST = '127.0.0.1';

  const { config } = await importFresh('../server/src/config.js');

  assert.equal(config.host, '127.0.0.1');
});
