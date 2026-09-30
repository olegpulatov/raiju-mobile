#!/usr/bin/env node
// Modified for Raiju: private broker-to-Core live provider probe launcher.
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
if (process.argv.length !== 2) {
  console.error('usage: SPARK_LIVE=1 SPARK_BROKER_TOKEN=... SPARK_ALLOW_HTTP=1 node scripts/spark-live-provider-probe.mjs');
  process.exit(64);
}
if (process.env.SPARK_LIVE !== '1') {
  console.error('error: live provider access is disabled; set SPARK_LIVE=1 explicitly');
  process.exit(64);
}
const brokerToken = process.env.SPARK_BROKER_TOKEN ?? process.env.OMP_AUTH_BROKER_TOKEN;
if (!brokerToken?.trim()) {
  console.error('error: broker token must be inherited at runtime');
  process.exit(64);
}
const result = spawnSync(
  'node',
  ['scripts/flutter-tool.mjs', 'dart', 'run', 'tool/spark_live_provider_probe.dart'],
  { cwd: root, env: process.env, stdio: 'inherit' },
);
if (result.error) {
  console.error('error: unable to start the private live provider flow');
  process.exit(127);
}
process.exit(result.status ?? 1);
