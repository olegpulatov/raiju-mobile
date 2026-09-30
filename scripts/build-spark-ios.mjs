#!/usr/bin/env node

import { cp, mkdir, rm } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const crate = resolve(root, 'spark-core');
const profile = process.argv[2] ?? 'debug';
if (!['debug', 'release'].includes(profile)) {
  console.error('usage: node scripts/build-spark-ios.mjs [debug|release]');
  process.exit(2);
}

const targets = ['aarch64-apple-ios', 'aarch64-apple-ios-sim', 'x86_64-apple-ios'];
const cargoProfile = profile === 'release' ? ['--release'] : [];
const artifactProfile = profile === 'release' ? 'release' : 'debug';
const output = resolve(root, '.work', 'spark-ios');

function run(command, args) {
  console.log(`+ ${command} ${args.join(' ')}`);
  const result = spawnSync(command, args, { cwd: root, stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}

run('rustup', ['target', 'add', ...targets]);
for (const target of targets) {
  run('cargo', ['build', '--locked', '--lib', '--manifest-path', resolve(crate, 'Cargo.toml'), '--target', target, ...cargoProfile]);
}

await rm(output, { recursive: true, force: true });
await mkdir(resolve(output, 'device'), { recursive: true });
await mkdir(resolve(output, 'simulator'), { recursive: true });
await cp(
  resolve(crate, 'target', 'aarch64-apple-ios', artifactProfile, 'libspark_core.a'),
  resolve(output, 'device', 'libspark_core.a'),
);
run('xcrun', [
  'lipo', '-create',
  resolve(crate, 'target', 'aarch64-apple-ios-sim', artifactProfile, 'libspark_core.a'),
  resolve(crate, 'target', 'x86_64-apple-ios', artifactProfile, 'libspark_core.a'),
  '-output', resolve(output, 'simulator', 'libspark_core.a'),
]);
run('xcrun', [
  'xcodebuild', '-create-xcframework',
  '-library', resolve(output, 'device', 'libspark_core.a'),
  '-headers', resolve(crate, 'include'),
  '-library', resolve(output, 'simulator', 'libspark_core.a'),
  '-headers', resolve(crate, 'include'),
  '-output', resolve(output, 'SparkCore.xcframework'),
]);
console.log(`Spark iOS libraries prepared at ${output}`);
