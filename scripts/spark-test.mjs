#!/usr/bin/env node
// Modified for Raiju: focused Spark contract runner.
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const component = process.argv[2] ?? 'all';
const supported = new Set(['all', 'rust', 'domain', 'widgets', 'tooling']);
if (!supported.has(component)) {
  console.error('usage: node scripts/spark-test.mjs [all|rust|domain|widgets|tooling]');
  process.exit(64);
}

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: root,
    env: process.env,
    stdio: 'inherit',
  });
  if (result.error) {
    console.error(`error: unable to start ${command}`);
    process.exit(127);
  }
  if (result.status !== 0) process.exit(result.status ?? 1);
}

if (component === 'all' || component === 'rust') {
  run('cargo', ['test', '--manifest-path', 'spark-core/Cargo.toml']);
}
if (component === 'all' || component === 'domain') {
  run('node', ['scripts/flutter-tool.mjs', 'flutter', 'test', '--no-pub', 'test/spark/domain']);
}
if (component === 'all' || component === 'widgets') {
  run('node', ['scripts/flutter-tool.mjs', 'flutter', 'test', '--no-pub', 'test/spark/widgets']);
}
if (component === 'all' || component === 'tooling') {
  run('node', ['--test', 'test/spark/tooling/fixtures.test.mjs']);
}
