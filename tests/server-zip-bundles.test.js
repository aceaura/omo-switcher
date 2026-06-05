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

test('bundle names allow practical safe slugs and still reject path-like names', async () => {
  const dir = tempDir();
  await setOpencodeDir(dir);
  await makeBundle(dir, 'Opus_Mode.v2', {
    'oh-my-openagent.json': '{"provider":"omo"}',
    'oh-my-opencode-slim.json': '{"provider":"slim"}',
  });
  await makeBundle(dir, '.hidden', {
    'oh-my-openagent.json': '{"provider":"hidden"}',
  });

  const { listTierBundles, isAllowedSlug } = await importFresh('../server/src/bundle.js');
  const bundles = await listTierBundles();

  assert.deepEqual(bundles.map((bundle) => bundle.key), ['Opus_Mode.v2']);
  assert.equal(isAllowedSlug('Opus_Mode.v2'), true);
  assert.equal(isAllowedSlug('../escape'), false);
  assert.equal(isAllowedSlug('.hidden'), false);
});

test('buildTierBundle augments incomplete workspace packages from active provider files', async () => {
  const dir = tempDir();
  await setOpencodeDir(dir);
  fs.writeFileSync(path.join(dir, 'oh-my-openagent.json'), '{"active":"omo"}');
  fs.writeFileSync(path.join(dir, 'oh-my-opencode-slim.json'), '{"active":"slim"}');
  await makeBundle(dir, 'balanced', {
    'opencode.jsonc': '{}',
    'tui.json': '{}',
  });

  const { buildTierBundle, extractTierBundle } = await importFresh('../server/src/bundle.js');
  const bundle = await buildTierBundle('balanced');
  const extracted = await extractTierBundle('balanced');

  assert.deepEqual(bundle.files.sort(), ['oh-my-openagent.json', 'oh-my-opencode-slim.json', 'opencode.jsonc', 'tui.json']);
  assert.deepEqual(extracted.entries.map((entry) => entry.name).sort(), [
    'oh-my-openagent.json',
    'oh-my-opencode-slim.json',
    'opencode.jsonc',
    'tui.json',
  ]);
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
  // 切换写盘时自动修复：oh-my-openagent.json 注入 disabled_skills，package.json 注入 slim 依赖。
  const omo = JSON.parse(fs.readFileSync(path.join(dir, 'oh-my-openagent.json'), 'utf8'));
  assert.equal(omo.applied, 'omo');
  assert.deepEqual(omo.disabled_skills, ['security-research', 'security-review']);
  const pkg = JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'));
  assert.equal(pkg.dependencies['oh-my-opencode-slim'], '^1.1.1');
  // slim 配置不受影响，原样写入。
  assert.equal(fs.readFileSync(path.join(dir, 'oh-my-opencode-slim.json'), 'utf8'), '{"applied":"slim"}');
});

test('auto-fix is idempotent: already-fixed members keep their bytes', async () => {
  const dir = tempDir();
  await setOpencodeDir(dir);
  const omoFixed = '{"$schema":"x","disabled_skills":["security-research","security-review"],"applied":"omo"}';
  await makeBundle(dir, 'balanced', {
    'oh-my-openagent.json': omoFixed,
    'oh-my-opencode-slim.json': '{"applied":"slim"}',
    'package.json': '{"dependencies":{"oh-my-opencode-slim":"^9.9.9"}}',
  });

  const { extractTierBundle } = await importFresh('../server/src/bundle.js');
  const extracted = await extractTierBundle('balanced');
  const omo = JSON.parse(extracted.entries.find((e) => e.name === 'oh-my-openagent.json').content.toString('utf8'));
  const pkg = JSON.parse(extracted.entries.find((e) => e.name === 'package.json').content.toString('utf8'));

  assert.deepEqual(omo.disabled_skills, ['security-research', 'security-review']);
  // 已有的依赖版本不被覆盖。
  assert.equal(pkg.dependencies['oh-my-opencode-slim'], '^9.9.9');
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
