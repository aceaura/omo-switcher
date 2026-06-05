const assert = require('node:assert/strict');
const test = require('node:test');

async function importFresh(modulePath) {
  return import(`${modulePath}?t=${Date.now()}-${Math.random()}`);
}

test('deleteCurrentItems creates a new snapshot without mutating the old one', async () => {
  const versions = await importFresh('../server/src/versions.js');
  const firstId = await versions.createSnapshot(
    [
      { key: 'Opus_Mode.v2', contentB64: Buffer.from('opus').toString('base64') },
      { key: 'gpt-low', contentB64: Buffer.from('gpt').toString('base64') },
    ],
    { note: 'seed' },
  );

  const deleteId = await versions.deleteCurrentItems(['Opus_Mode.v2'], {
    note: 'delete one',
  });

  const current = await versions.getCurrentItems();
  const first = await versions.getSnapshot(firstId);
  const deleted = await versions.getSnapshot(deleteId);

  assert.deepEqual(current.map((item) => item.key), ['gpt-low']);
  assert.deepEqual(first.items.map((item) => item.key).sort(), [
    'Opus_Mode.v2',
    'gpt-low',
  ]);
  assert.deepEqual(deleted.items.map((item) => item.key), ['gpt-low']);

  const listed = await versions.listSnapshots();
  assert.equal(listed.head, deleteId);
});

test('renameCurrentItem creates a new snapshot and preserves the old key in history', async () => {
  const versions = await importFresh('../server/src/versions.js');
  const firstId = await versions.createSnapshot(
    [
      { key: 'gpt-high', contentB64: Buffer.from('gpt').toString('base64') },
      { key: 'opus-low', contentB64: Buffer.from('opus').toString('base64') },
    ],
    { note: 'seed rename' },
  );

  const renameId = await versions.renameCurrentItem('gpt-high', 'gpt_high_custom', {
    note: 'rename one',
  });

  const current = await versions.getCurrentItems();
  const first = await versions.getSnapshot(firstId);
  const renamed = await versions.getSnapshot(renameId);

  assert.deepEqual(current.map((item) => item.key).sort(), [
    'gpt_high_custom',
    'opus-low',
  ]);
  assert.deepEqual(first.items.map((item) => item.key).sort(), [
    'gpt-high',
    'opus-low',
  ]);
  assert.deepEqual(renamed.items.map((item) => item.key).sort(), [
    'gpt_high_custom',
    'opus-low',
  ]);
});
