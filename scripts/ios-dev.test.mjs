import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));

// These cases return before native builds, simulator selection, or network IO.
function runCli(args) {
  const result = spawnSync(process.execPath, [
    'scripts/flutter-tool.mjs', 'ios-dart', 'run', 'tool/ios_dev.dart', ...args,
  ], { cwd: root, encoding: 'utf8', timeout: 60000 });
  assert.ifError(result.error);
  return { status: result.status, output: result.stdout + result.stderr };
}

test('iOS help includes TCP daemon smoke and retains existing journeys', () => {
  const result = runCli(['--help']);
  assert.equal(result.status, 0, result.output);
  assert.match(result.output, /ompd-smoke\s+Run the synthetic TCP daemon GUI journey/);
  assert.match(result.output, /smoke\s+Run the deterministic native GUI integration journey/);
  assert.match(result.output, /spark-smoke\s+Run the synthetic Spark voice/);
  assert.match(result.output, /live\s+Opt-in real-host GUI check/);
});

test('daemon smoke rejects a remote host argument before native work', () => {
  const result = runCli(['ompd-smoke', '--host', 'synthetic-host']);
  assert.equal(result.status, 64, result.output);
  assert.match(result.output, /--host is valid only with live/);
});

test('daemon smoke rejects positional endpoint and unknown flags', () => {
  for (const option of ['tcp://127.0.0.1:12345', '--endpoint']) {
    const result = runCli(['ompd-smoke', option]);
    assert.equal(result.status, 64, result.output);
    assert.match(result.output, /Unknown option/);
  }
});

test('daemon smoke requires a value after device flag', () => {
  const result = runCli(['ompd-smoke', '--device']);
  assert.equal(result.status, 64, result.output);
  assert.match(result.output, /--device requires a value/);
});

test('existing live target still requires an explicit host', () => {
  const result = runCli(['live']);
  assert.equal(result.status, 64, result.output);
  assert.match(result.output, /live requires HOST/);
});
