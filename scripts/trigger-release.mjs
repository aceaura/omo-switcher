#!/usr/bin/env node
// Trigger the GitHub Actions release build for omo-switcher.
//
// Reads the version from client/pubspec.yaml, then either:
//   * (default) creates and pushes a matching git tag `vX.Y.Z`, which fires
//     .github/workflows/release.yml and publishes the installers, or
//   * (--dispatch) runs the workflow directly via the `gh` CLI without tagging.
//
// Usage:
//   node scripts/trigger-release.mjs              # tag from pubspec version and push
//   node scripts/trigger-release.mjs --tag v1.2.3 # override the tag
//   node scripts/trigger-release.mjs --dispatch   # gh workflow run (no tag pushed)
//   node scripts/trigger-release.mjs --allow-dirty
//   node scripts/trigger-release.mjs --remote upstream
//
// npm equivalents: `npm run release` / `npm run release:dispatch`.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { execFileSync } from 'node:child_process';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const has = (flag) => args.includes(flag);
const opt = (name) => {
  const i = args.indexOf(name);
  return i !== -1 ? args[i + 1] : undefined;
};

const remote = opt('--remote') ?? 'origin';
const dispatch = has('--dispatch');
const allowDirty = has('--allow-dirty');

const capture = (cmd, cmdArgs) =>
  execFileSync(cmd, cmdArgs, { cwd: root, encoding: 'utf8' }).trim();
const inherit = (cmd, cmdArgs) =>
  execFileSync(cmd, cmdArgs, { cwd: root, stdio: 'inherit' });

const die = (msg) => {
  console.error(`error: ${msg}`);
  process.exit(1);
};

// 1. Resolve the tag from the requested override or the pubspec version.
let tag = opt('--tag');
if (!tag) {
  const pubspec = readFileSync(join(root, 'client', 'pubspec.yaml'), 'utf8');
  const m = pubspec.match(/^\s*version:\s*(.+?)\s*$/m);
  if (!m) die('could not read version from client/pubspec.yaml');
  const version = m[1].split('+')[0].trim(); // drop build metadata (1.0.6+7 -> 1.0.6)
  tag = `v${version}`;
}
console.log(`Release tag: ${tag}`);

// Resolve the owner/repo slug for the links printed at the end.
let slug = 'aceaura/omo-switcher';
try {
  const m = capture('git', ['remote', 'get-url', remote]).match(
    /github\.com[/:]([^/]+\/[^/.]+?)(?:\.git)?$/,
  );
  if (m) slug = m[1];
} catch {
  /* fall back to the default slug */
}

// 2a. Dispatch path: ask GitHub to run the workflow directly (no tag pushed).
if (dispatch) {
  console.log(`Dispatching release.yml with tag=${tag} via gh ...`);
  try {
    inherit('gh', ['workflow', 'run', 'release.yml', '-f', `tag=${tag}`]);
  } catch {
    die('`gh workflow run` failed — is the GitHub CLI installed and authenticated?');
  }
  console.log(`\nDispatched. Watch progress: https://github.com/${slug}/actions`);
  process.exit(0);
}

// 2b. Tag path: validate, then create and push an annotated tag.
try {
  if (capture('git', ['status', '--porcelain']) && !allowDirty) {
    die(
      'working tree has uncommitted changes (the build uses committed HEAD, not local edits).\n' +
        '       Commit or stash first, or re-run with --allow-dirty.',
    );
  }
} catch {
  die('not a git repository, or git is not installed');
}

try {
  capture('git', ['rev-parse', '--verify', '--quiet', `refs/tags/${tag}`]);
  die(`tag ${tag} already exists. Bump version in client/pubspec.yaml or delete the tag.`);
} catch (e) {
  if (e?.status === undefined) throw e; // rethrow non-git failures
  // non-zero exit means the tag does not exist — good, continue.
}

inherit('git', ['tag', '-a', tag, '-m', `omo-switcher ${tag}`]);
inherit('git', ['push', remote, tag]);

// 3. Report where to watch the build and download the binaries.
console.log(`\nPushed ${tag}. Build started:`);
console.log(`  https://github.com/${slug}/actions`);
console.log('\nWhen the run is green, the installers will be downloadable at:');
console.log(`  https://github.com/${slug}/releases/latest/download/omo-switcher-windows-setup.msi`);
console.log(`  https://github.com/${slug}/releases/latest/download/omo-switcher-macos.pkg`);
