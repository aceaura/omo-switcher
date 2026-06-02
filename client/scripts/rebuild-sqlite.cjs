// 为 Electron 准备 better-sqlite3 原生模块。
// 背景：Node v25 下 @electron/rebuild 自带的 yargs CLI 会崩溃（require is not defined in ESM）。
// 这里改用 better-sqlite3 自带的 prebuild-install 直接拉取对应 Electron 版本的预编译二进制，
// 失败也不让 npm install 整体失败（best-effort）。
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

function findUp(name) {
  let dir = __dirname;
  for (let i = 0; i < 6; i++) {
    const p = path.join(dir, 'node_modules', name);
    if (fs.existsSync(p)) return p;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

try {
  const electronDir = findUp('electron');
  const bsqliteDir = findUp('better-sqlite3');
  if (!electronDir || !bsqliteDir) {
    console.log('[rebuild-sqlite] 未找到 electron / better-sqlite3，跳过');
    process.exit(0);
  }
  const version = require(path.join(electronDir, 'package.json')).version;
  const prebuild = path.join(path.dirname(bsqliteDir), '.bin', 'prebuild-install');
  execFileSync(
    process.execPath,
    [prebuild, '-r', 'electron', '-t', version, '--arch', process.arch],
    { cwd: bsqliteDir, stdio: 'inherit' }
  );
  console.log(`[rebuild-sqlite] 已为 electron ${version} (${process.arch}) 准备 better-sqlite3`);
} catch (e) {
  console.log('[rebuild-sqlite] 自动准备失败，请手动执行：');
  console.log('  cd node_modules/better-sqlite3 && ../.bin/prebuild-install -r electron -t <electron版本>');
  console.log('  原因: ' + e.message);
}
process.exit(0);
