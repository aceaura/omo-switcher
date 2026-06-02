const assert = require('node:assert/strict');
const test = require('node:test');

async function restartModule() {
  return import('../server/src/restart.js');
}

test('collectRestartTargets matches OpenCode case-insensitively and includes descendants', async () => {
  const { collectRestartTargets, parseProcessList } = await restartModule();
  const processes = parseProcessList(`
    674     1 /Applications/OpenCode.app/Contents/MacOS/OpenCode
   1380   674 /Applications/OpenCode.app/Contents/Frameworks/OpenCode Helper.app/Contents/MacOS/OpenCode Helper --type=gpu-process
   1864  1393 /usr/local/bin/node /Users/tony/.cache/opencode/packages/oh-my-openagent/dist/cli.js mcp
  42000     1 node src/index.js
  `);

  const targets = collectRestartTargets(processes, {
    currentPid: 42000,
    killNeedle: 'opencode',
  });

  assert.deepEqual(targets.map((target) => target.pid), [1864, 1380, 674]);
});

test('terminateRestartTargets escalates to SIGKILL when SIGTERM does not stop a process', async () => {
  const { terminateRestartTargets } = await restartModule();
  const sentSignals = [];
  const alive = new Set([123]);

  const result = await terminateRestartTargets([{ pid: 123, cmd: 'opencode' }], {
    isAlive: (pid) => alive.has(pid),
    kill: (pid, signal) => {
      sentSignals.push([pid, signal]);
      if (signal === 'SIGKILL') alive.delete(pid);
    },
    sleep: async () => {},
    termWaitMs: 0,
    killWaitMs: 0,
  });

  assert.deepEqual(sentSignals, [
    [123, 'SIGTERM'],
    [123, 'SIGKILL'],
  ]);
  assert.deepEqual(result.killed, [123]);
  assert.equal(result.failed.length, 0);
});
