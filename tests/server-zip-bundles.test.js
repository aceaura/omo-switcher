const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const JSZip = require('jszip');

function tempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'omo-switcher-zip-'));
}

async function makeBundle(dir, slug, files) {
  const zip = new JSZip();
  for (const [name, content] of Object.entries(files)) zip.file(name, content);
  fs.writeFileSync(path.join(dir, `${slug}.zip`), await zip.generateAsync({ type: 'nodebuffer' }));
}

async function importFresh(modulePath) {
  return import(`${modulePath}?t=${Date.now()}-${Math.random()}`);
}

async function setOpencodeDir(dir) {
  process.env.OPENCODE_DIR = dir;
  const { config } = await import('../server/src/config.js');
  config.opencodeDir = dir;
}

test('listTierBundles scans zip packages from the workspace directory', async () => {
  const dir = tempDir();
  await setOpencodeDir(dir);
  await makeBundle(dir, 'balanced', {
    'oh-my-openagent.json': '{"provider":"omo"}',
    'oh-my-opencode-slim.json': '{"provider":"slim"}',
    'opencode.jsonc': '{}',
    'tui.json': '{}',
    'package.json': '{}',
    'package-lock.json': '{}',
  });

  const { listTierBundles } = await importFresh('../server/src/bundle.js');
  const bundles = await listTierBundles();

  assert.equal(bundles.length, 1);
  assert.equal(bundles[0].key, 'balanced');
  assert.equal(bundles[0].files.length, 6);
  assert.match(bundles[0].sha256, /^[a-f0-9]{64}$/);
});

test('applyTier unzips a workspace package into active config files', async () => {
  const dir = tempDir();
  await setOpencodeDir(dir);
  await makeBundle(dir, 'balanced', {
    'oh-my-openagent.json': '{"applied":"omo"}',
    'oh-my-opencode-slim.json': '{"applied":"slim"}',
    'opencode.jsonc': '{"plugin":[]}',
    'tui.json': '{}',
    'package.json': '{}',
    'package-lock.json': '{}',
  });

  const { applyTier } = await importFresh('../server/src/switcher.js');
  const result = await applyTier('balanced');

  assert.equal(result.ok, true);
  assert.equal(fs.readFileSync(path.join(dir, 'oh-my-openagent.json'), 'utf8'), '{"applied":"omo"}');
  assert.equal(fs.readFileSync(path.join(dir, 'oh-my-opencode-slim.json'), 'utf8'), '{"applied":"slim"}');
});

test('writeTierBundle normalizes old numbered entries into active zip entries', async () => {
  const dir = tempDir();
  await setOpencodeDir(dir);
  const zip = new JSZip();
  zip.file('oh-my-openagent.3-balanced.json', '{"legacy":"omo"}');
  zip.file('oh-my-opencode-slim.3-balanced.json', '{"legacy":"slim"}');
  zip.file('opencode.jsonc', '{}');

  const { writeTierBundle, extractTierBundle } = await importFresh('../server/src/bundle.js');
  const buf = await zip.generateAsync({ type: 'nodebuffer' });
  const result = await writeTierBundle('balanced', buf.toString('base64'));
  const extracted = await extractTierBundle('balanced');

  assert.deepEqual(result.files.sort(), ['oh-my-openagent.json', 'oh-my-opencode-slim.json', 'opencode.jsonc']);
  assert.deepEqual(extracted.entries.map((entry) => entry.name).sort(), [
    'oh-my-openagent.json',
    'oh-my-opencode-slim.json',
    'opencode.jsonc',
  ]);
});
