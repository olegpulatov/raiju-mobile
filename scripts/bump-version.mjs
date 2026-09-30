#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const [version, flag] = process.argv.slice(2);
if (!/^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.test(version ?? '') ||
    (flag && flag !== '--check') || process.argv.length > 4) {
  console.error('usage: bump-version.mjs vX.X.X [--check]');
  process.exit(1);
}

const pubspec = fileURLToPath(new URL('../pubspec.yaml', import.meta.url));
const original = readFileSync(pubspec, 'utf8');
const match = original.match(/^version: (\d+\.\d+\.\d+)\+(\d+)$/m);
if (!match) throw new Error('pubspec.yaml needs version: X.X.X+build');

const next = `${version.slice(1)}+${match[2]}`;
if (flag !== '--check') {
  writeFileSync(pubspec, original.replace(/^version: \d+\.\d+\.\d+\+\d+$/m, `version: ${next}`));
}
console.log(`${flag === '--check' ? 'Would set' : 'Set'} mobile version ${next}`);
