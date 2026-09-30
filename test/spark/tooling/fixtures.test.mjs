// Modified for Raiju: synthetic tooling contracts contain no production secrets.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const fixture = (name) => new URL(name, import.meta.url);

test('normalized provider fixture covers the documented event boundary', async () => {
  const events = JSON.parse(await readFile(fixture('provider-events.json'), 'utf8'));
  assert.deepEqual(
    events.map((event) => event.type),
    ['connected', 'levels', 'transcript', 'transcript', 'delegation', 'closed'],
  );
  assert.deepEqual(
    events.filter((event) => event.type === 'transcript').map((event) => event.role),
    ['user', 'assistant'],
  );
  assert.ok(events.every((event) => !('accessToken' in event) && !('sdp' in event)));
});

test('broker fixture is unmistakably synthetic and contains one eligible shape', async () => {
  const snapshot = JSON.parse(await readFile(fixture('broker-snapshot.json'), 'utf8'));
  assert.equal(snapshot.credentials.length, 1);
  const entry = snapshot.credentials[0];
  assert.equal(entry.provider, 'openai-codex');
  assert.equal(entry.credential.type, 'oauth');
  assert.match(entry.credential.access, /^synthetic-/);
  assert.equal(entry.credential.refresh, '__remote__');
});
