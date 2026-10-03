import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));

// These cases return before native builds, simulator selection, or network IO.
function runCli(args, runtime = {}) {
  const result = spawnSync(process.execPath, [
    'scripts/flutter-tool.mjs', 'ios-dart', 'run', 'tool/ios_dev.dart', ...args,
  ], {
    cwd: root,
    encoding: 'utf8',
    timeout: 60000,
    env: {
      ...process.env,
      OMPD_TEST_ENDPOINT: '',
      OMPD_TEST_PROFILE: '',
      ...runtime,
    },
  });
  assert.ifError(result.error);
  return { status: result.status, output: result.stdout + result.stderr };
}

test('iOS help includes TCP daemon smoke and retains existing journeys', () => {
  const result = runCli(['--help']);
  assert.equal(result.status, 0, result.output);
  assert.match(result.output, /ompd-smoke\s+Run the synthetic TCP daemon GUI journey/);
  assert.match(result.output, /ompd-live\s+Run against an already-running relay/);
  assert.match(result.output, /OMPD_TEST_ENDPOINT\/OMPD_TEST_PROFILE/);
  assert.match(result.output, /smoke\s+Run the deterministic native GUI integration journey/);
  assert.match(result.output, /spark-smoke\s+Run the synthetic Spark voice/);
  assert.match(result.output, /live\s+Opt-in real-host GUI check/);
});

test('daemon smoke rejects a remote host argument before native work', () => {
  const result = runCli(['ompd-smoke', '--host', 'synthetic-host']);
  assert.equal(result.status, 64, result.output);
  assert.match(result.output, /--host is valid only with live/);
});

test('daemon smoke rejects positional endpoint and live-only endpoint flag', () => {
  const positional = runCli(['ompd-smoke', 'tcp://127.0.0.1:12345']);
  assert.equal(positional.status, 64, positional.output);
  assert.match(positional.output, /Unknown option/);
  const flagged = runCli(['ompd-smoke', '--endpoint', '127.0.0.1:12345']);
  assert.equal(flagged.status, 64, flagged.output);
  assert.match(flagged.output, /--endpoint is valid only with ompd-live/);
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

test('live relay requires explicit endpoint and profile before native work', () => {
  for (const args of [
    ['ompd-live'],
    ['ompd-live', '--endpoint', '127.0.0.1:12345'],
    ['ompd-live', '--profile', 'synthetic-profile'],
  ]) {
    const result = runCli(args);
    assert.equal(result.status, 64, result.output);
    assert.match(result.output, /ompd-live requires explicit --endpoint and --profile/);
  }
});

test('live relay validates runtime endpoint before native work', () => {
  for (const endpoint of ['localhost', 'https://localhost:12345', 'localhost:0']) {
    const result = runCli(['ompd-live'], {
      OMPD_TEST_ENDPOINT: endpoint,
      OMPD_TEST_PROFILE: 'synthetic-profile',
    });
    assert.equal(result.status, 64, result.output);
    assert.match(result.output, /Relay endpoint must be HOST:PORT/);
  }
});

test('live relay rejects duplicate runtime options and missing values', () => {
  for (const flag of ['--endpoint', '--profile']) {
    const missing = runCli(['ompd-live', flag]);
    assert.equal(missing.status, 64, missing.output);
    assert.match(missing.output, /requires a value/);
    const duplicate = runCli(['ompd-live', flag, 'fixture', flag, 'fixture']);
    assert.equal(duplicate.status, 64, duplicate.output);
    assert.match(duplicate.output, /Specify the relay (endpoint|profile) once/);
  }
});
