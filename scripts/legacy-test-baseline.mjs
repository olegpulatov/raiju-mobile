#!/usr/bin/env node
// Run every Flutter test and compare failures with the recorded list of known
// failures in inherited Buzz suites. Fails only on new failures, so agents can
// tell regressions from tests that target removed relay/push/huddle backends.
//
//   node scripts/legacy-test-baseline.mjs           compare with baseline
//   node scripts/legacy-test-baseline.mjs --update  rewrite baseline
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const baselinePath = path.join(root, 'test/legacy-known-failures.txt');
const update = process.argv.includes('--update');
const header = [
  '# Known failing tests in inherited Buzz suites: "<file>: <test name>".',
  '# Their fixtures feed Buzz relay/push/huddle backends that Raiju no longer',
  '# runs. Checked by `just test-legacy`; new failures outside this list fail it.',
  '# Regenerate after fixing or deleting tests: node scripts/legacy-test-baseline.mjs --update',
];

const child = spawn(
  process.execPath,
  [path.join(root, 'scripts/flutter-tool.mjs'), 'flutter', 'test', '--no-pub', '--reporter', 'json', 'test'],
  { cwd: root, env: process.env, stdio: ['ignore', 'pipe', 'inherit'] },
);
// Listen before reading output so an early exit or spawn error is not missed.
const finished = new Promise((resolve) => {
  child.on('error', (error) => resolve({ error }));
  child.on('close', (code, signal) => resolve({ code, signal }));
});

const suites = new Map();
const tests = new Map();
const failures = new Set();
let passed = 0;
let runDone = false;
for await (const line of createInterface({ input: child.stdout })) {
  let event;
  try {
    event = JSON.parse(line);
  } catch {
    continue;
  }
  if (event.type === 'done') {
    runDone = true;
  } else if (event.type === 'suite') {
    suites.set(event.suite.id, path.relative(root, event.suite.path));
  } else if (event.type === 'testStart') {
    tests.set(event.test.id, event.test);
  } else if (event.type === 'testDone' && !event.skipped) {
    const test = tests.get(event.testID);
    if (event.result === 'success') {
      if (!event.hidden) passed++;
      continue;
    }
    const file = suites.get(test.suiteID) ?? 'unknown';
    // Normalize absolute paths in load-failure names ("loading /abs/path").
    const name = test.name.replaceAll(`${root}/`, '');
    failures.add(`${file}: ${name}`);
  }
}
const { error, code, signal } = await finished;
// flutter test exits 1 when tests fail; anything else, a signal, or a missing
// final `done` event means a partial run that must not pass or overwrite the baseline.
if (error || signal || (code !== 0 && code !== 1) || !runDone) {
  const reason = error?.message ?? (signal ? `signal ${signal}` : `exit ${code}`);
  console.error(`error: incomplete flutter test run (${reason}, done event: ${runDone})`);
  process.exit(1);
}

const current = [...failures].sort();
if (update) {
  writeFileSync(baselinePath, `${[...header, ...current].join('\n')}\n`);
  console.log(`baseline updated: ${current.length} known failures, ${passed} passed`);
  process.exit(0);
}

const known = new Set(
  readFileSync(baselinePath, 'utf8')
    .split('\n')
    .filter((line) => line && !line.startsWith('#')),
);
const added = current.filter((line) => !known.has(line));
const fixed = [...known].filter((line) => !failures.has(line));
console.log(`${passed} passed, ${current.length} failed (${current.length - added.length} known)`);
if (fixed.length) {
  console.log(`\n${fixed.length} known failures now pass or no longer exist; run with --update:`);
  for (const line of fixed) console.log(`  ${line}`);
}
if (added.length) {
  console.error(`\n${added.length} new failures:`);
  for (const line of added) console.error(`  ${line}`);
  process.exit(1);
}
