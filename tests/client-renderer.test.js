const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const rendererPath = path.join(__dirname, '..', 'client', 'renderer', 'renderer.js');

function makeElement(extra = {}) {
  return {
    value: '',
    textContent: '',
    className: '',
    innerHTML: '',
    dataset: {},
    checked: false,
    classList: {
      add() {},
      remove() {},
    },
    appendChild() {},
    close() {},
    showModal() {},
    querySelector() {
      return makeElement();
    },
    querySelectorAll() {
      return [];
    },
    ...extra,
  };
}

async function loadRenderer(apiOverrides = {}) {
  const ids = new Map();
  const id = (name) => {
    if (!ids.has(name)) ids.set(name, makeElement());
    return ids.get(name);
  };

  id('conn').className = 'pill pill-muted';
  id('serverUrl').value = 'http://old.example';

  const calls = [];
  const alerts = [];
  const api = {
    async getSetting(key) {
      calls.push(['getSetting', key]);
      return key === 'server_url' ? 'http://old.example' : '';
    },
    async setSetting(key, value) {
      calls.push(['setSetting', key, value]);
      return true;
    },
    async call(method, route, body) {
      calls.push(['call', method, route, body]);
      if (route === '/api/state') {
        return { ok: true, tiers: [], active: { shared: '' } };
      }
      if (route === '/api/health') return { ok: true, storeMode: 'redis' };
      if (route === '/api/config/items') return { ok: true, items: [] };
      if (route === '/api/config/diff') {
        return { ok: true, diff: { onlyLocal: [], onlyRemote: [], changed: [], same: [] } };
      }
      if (route === '/api/snapshots?limit=50') return { ok: true, items: [] };
      return { ok: true };
    },
    async listLocalItems() {
      calls.push(['listLocalItems']);
      return [];
    },
    async testConnection(serverUrl) {
      calls.push(['testConnection', serverUrl]);
      return { ok: true, storeMode: 'redis' };
    },
    async importLocal(opts) {
      calls.push(['importLocal', opts]);
      return { ok: true, imported: opts?.keys || [] };
    },
    async exportLocal(opts) {
      calls.push(['exportLocal', opts]);
      return { ok: true, exported: opts?.keys || [], failed: [] };
    },
    async pull(opts) {
      calls.push(['pull', opts]);
      return { ok: true, pulled: opts.keys };
    },
    async push(opts) {
      calls.push(['push', opts]);
      return { ok: true, snapshotId: 'snap-1' };
    },
    ...apiOverrides,
  };

  const context = {
    api,
    console: { log() {}, error() {} },
    document: {
      addEventListener() {},
      createElement: () => makeElement(),
      getElementById: id,
      querySelector: () => makeElement({ value: 'pull' }),
      querySelectorAll: () => [],
    },
    window: { __OMO_SWITCHER_TEST__: true },
    alert(message) {
      alerts.push(message);
    },
    confirm: () => true,
  };
  context.globalThis = context;

  vm.runInNewContext(fs.readFileSync(rendererPath, 'utf8'), context, {
    filename: rendererPath,
  });

  await Promise.resolve();
  calls.length = 0;

  return { alerts, calls, context, ids };
}

test('testConn saves the current server URL after a successful connection', async () => {
  const { calls, context, ids } = await loadRenderer();

  ids.get('serverUrl').value = 'http://127.0.0.1:7600';
  await context.testConn();

  assert.deepEqual(calls[0], ['testConnection', 'http://127.0.0.1:7600']);
  assert.deepEqual(calls[1], ['setSetting', 'server_url', 'http://127.0.0.1:7600']);
  assert.equal(ids.get('conn').textContent, '已连接');
  assert.equal(ids.get('store').textContent, 'store: redis');
});

test('testConn shows a failed state when the connection check rejects', async () => {
  const { context, ids } = await loadRenderer({
    async testConnection() {
      throw new Error('connection refused');
    },
  });

  ids.get('serverUrl').value = 'http://127.0.0.1:1';
  await context.testConn();

  assert.equal(ids.get('conn').textContent, '未连接');
  assert.equal(ids.get('conn').className, 'pill pill-bad');
  assert.match(ids.get('store').textContent, /connection refused/);
});

test('selectedKeys reads checked boxes for the requested storage zone', async () => {
  const { context } = await loadRenderer();
  const checkedBox = { dataset: { key: 'balanced' } };

  context.document.querySelectorAll = (selector) => {
    return selector === '.workspace-key:checked' ? [checkedBox] : [];
  };

  assert.deepEqual([...context.selectedKeys('.workspace-key')], ['balanced']);
});

test('downloadWorkspaceToLocal imports selected workspace keys into SQLite', async () => {
  const { calls, context } = await loadRenderer();
  const checkedBox = { dataset: { key: 'remote-only' } };

  context.document.querySelectorAll = (selector) => {
    if (selector === '.workspace-key:checked') return [checkedBox];
    return [];
  };

  await context.downloadWorkspaceToLocal();

  assert.equal(JSON.stringify(calls[0]), JSON.stringify(['importLocal', { keys: ['remote-only'] }]));
});

test('uploadLocalToWorkspace exports selected SQLite keys to the workspace', async () => {
  const { calls, context } = await loadRenderer();
  const checkedBox = { dataset: { key: 'balanced' } };

  context.document.querySelectorAll = (selector) => {
    if (selector === '.local-key:checked') return [checkedBox];
    return [];
  };

  await context.uploadLocalToWorkspace();

  assert.equal(JSON.stringify(calls[0]), JSON.stringify(['exportLocal', { keys: ['balanced'] }]));
});
