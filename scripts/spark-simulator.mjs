#!/usr/bin/env node
// Modified for Raiju: deterministic synthetic Spark simulator journey.
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = ['scripts/flutter-tool.mjs', 'dart', 'run', 'tool/ios_dev.dart', 'spark-smoke'];
if (process.argv.length === 4 && process.argv[2] === '--device') {
  args.push('--device', process.argv[3]);
} else if (process.argv.length !== 2) {
  console.error('usage: node scripts/spark-simulator.mjs [--device UDID]');
  process.exit(64);
}
const result = spawnSync('node', args, {
  cwd: root,
  env: process.env,
  stdio: 'inherit',
});
if (result.error) {
  console.error('error: unable to start the simulator journey');
  process.exit(127);
}
process.exit(result.status ?? 1);
