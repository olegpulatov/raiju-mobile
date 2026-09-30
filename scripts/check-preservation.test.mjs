import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { assertBaselineComplete, blobHash, inspect, isVisual, isFrozen, loadBaseline } from './check-preservation.mjs';

const widget = 'lib/shared/widgets/frosted_app_bar.dart';
const screen = 'lib/features/channels/channel_detail_page.dart';
const original = Buffer.from('original Buzz component');
const retiredBackend = 'lib/features/channels/channel_directory.dart';
const retainedSharedGui = 'lib/shared/emoji/emoji_burst.dart';
const entry = (path) => ({ path, hash: blobHash(original) });

function baselineFixture(files) {
  const root = mkdtempSync(join(tmpdir(), 'raiju-preservation-test-'));
  const staging = join(root, 'staging');
  for (const [path, bytes] of Object.entries(files)) {
    const destination = join(staging, 'mobile', path);
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, bytes);
  }
  const archive = join(root, 'buzz-mobile.tar.gz');
  const tar = spawnSync('tar', ['-czf', archive, '-C', staging, 'mobile'], {
    encoding: 'utf8',
  });
  assert.equal(tar.status, 0, tar.stderr || tar.error?.message);
  const expectedSha256 = createHash('sha256').update(readFileSync(archive)).digest('hex');
  return {
    archive,
    expectedSha256,
    cleanup: () => rmSync(root, { recursive: true, force: true }),
  };
}

test('unchanged original GUI passes', () => {
  assert.deepEqual(inspect([entry(widget)], () => original).errors, []);
});

test('missing original screen fails rather than accepting new replacement', () => {
  const result = inspect([entry(screen)], () => { throw new Error('missing'); });
  assert.match(result.errors[0], /removed original GUI/);
});

test('changing frozen shared appearance fails', () => {
  const result = inspect([entry(widget)], () => Buffer.from('handcrafted substitute'));
  assert.match(result.errors[0], /changed frozen GUI/);
});

test('adapter changes require explicit diff review, not false visual proof', () => {
  const result = inspect([entry(screen)], () => Buffer.from('original screen with new provider'));
  assert.deepEqual(result.errors, []);
  assert.deepEqual(result.changed, [screen]);
});

test('logic can be stripped while QR and native polish remain frozen', () => {
  assert.equal(isVisual('lib/shared/relay/relay_session.dart'), false);
  assert.equal(isFrozen('lib/shared/theme/community_theme_provider.dart'), false);
  assert.equal(isFrozen('lib/features/pairing/pairing_qr_scanner.dart'), true);
  assert.equal(isFrozen('ios/Runner/JumpToLatestGlassButton.swift'), true);
});

test('retired backend parts are explicit non-visual exceptions', () => {
  for (const path of [
    retiredBackend,
    'lib/features/channels/channel_member_snapshots.dart',
    'lib/features/channels/channel_push_cache.dart',
  ]) {
    assert.equal(isVisual(path), false);
    assert.deepEqual(
      inspect([entry(path)], () => { throw new Error('retired'); }).errors,
      [],
    );
  }
});

test('backend exception does not permit deleting genuine channel UI', () => {
  const adjacentUi = 'lib/features/channels/channel_detail_page.dart';
  assert.equal(isVisual(adjacentUi), true);
  const result = inspect([entry(adjacentUi)], () => { throw new Error('missing'); });
  assert.match(result.errors[0], /removed original GUI/);
});

test('shared data providers remain outside the visual classifier', () => {
  assert.equal(
    isVisual('lib/shared/custom_emoji/custom_emoji_provider.dart'),
    false,
  );
  assert.equal(isVisual(retainedSharedGui), true);
});

test('shared visual sources and app shell require existence but stay adaptable', () => {
  for (const path of [
    retainedSharedGui,
    'lib/shared/mentions/mention_bindings.dart',
    'lib/app.dart',
  ]) {
    assert.equal(isVisual(path), true);
    assert.equal(isFrozen(path), false);
    const changed = inspect([entry(path)], () => Buffer.from('adapted visual'));
    assert.deepEqual(changed.errors, []);
    assert.deepEqual(changed.changed, [path]);
  }
});

const nativeAdapter = 'ios/Runner/NativeAttachmentPopoverMenu.swift';
const adaptedNative = Buffer.from('original native renderer with fenced actions');
const reviewedNative = new Map([[nativeAdapter, blobHash(adaptedNative)]]);

test('reviewed native effect adapters remain frozen to exact approved bytes', () => {
  assert.equal(isVisual(nativeAdapter), true);
  assert.equal(isFrozen(nativeAdapter), true);
  const result = inspect([entry(nativeAdapter)], () => adaptedNative, 'sha1', reviewedNative);
  assert.deepEqual(result.errors, []);
  assert.deepEqual(result.changed, [nativeAdapter]);
  assert.equal(result.frozen, 1);
  assert.equal(result.reviewed, 1);
});

test('native approval rejects redesigns and removal of the effect fence', () => {
  for (const bytes of [original, Buffer.from('replacement native menu')]) {
    const result = inspect([entry(nativeAdapter)], () => bytes, 'sha1', reviewedNative);
    assert.match(result.errors[0], /changed frozen GUI/);
  }
});

test('native adapter approval never permits deleting the original bridge', () => {
  const result = inspect([entry(nativeAdapter)], () => { throw new Error('missing'); }, 'sha1', reviewedNative);
  assert.match(result.errors[0], /removed original GUI/);
});

test('native effect approval does not thaw other native visual components', () => {
  const other = 'ios/Runner/NativeMessageActionSurface.swift';
  const result = inspect([entry(other)], () => adaptedNative, 'sha1', reviewedNative);
  assert.equal(isFrozen(other), true);
  assert.match(result.errors[0], /changed frozen GUI/);
});

test('portable baseline loading normalizes archive paths without repository state', () => {
  const fixture = baselineFixture({ [screen]: original });
  const unrelated = mkdtempSync(join(tmpdir(), 'raiju-unrelated-cwd-'));
  const previous = process.cwd();
  try {
    process.chdir(unrelated);
    assert.deepEqual(
      loadBaseline({
        archive: fixture.archive,
        expectedSha256: fixture.expectedSha256,
        temporaryRoot: dirname(fixture.archive),
      }),
      [entry(screen)],
    );
  } finally {
    process.chdir(previous);
    rmSync(unrelated, { recursive: true, force: true });
    fixture.cleanup();
  }
});

test('baseline loading rejects corrupt archive bytes before extraction', () => {
  const root = mkdtempSync(join(tmpdir(), 'raiju-corrupt-baseline-'));
  const archive = join(root, 'buzz-mobile.tar.gz');
  writeFileSync(archive, 'not the pinned archive');
  try {
    assert.throws(
      () => loadBaseline({ archive, expectedSha256: '0'.repeat(64), temporaryRoot: root }),
      /corrupt immutable Buzz baseline archive/,
    );
    assert.deepEqual(
      readdirSync(root).sort(),
      ['buzz-mobile.tar.gz'],
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('archive baseline retains deletion and frozen-byte policy', () => {
  const fixture = baselineFixture({ [widget]: original, [screen]: original });
  try {
    const entries = loadBaseline({
      archive: fixture.archive,
      expectedSha256: fixture.expectedSha256,
      temporaryRoot: dirname(fixture.archive),
    });
    const result = inspect(entries, (path) => {
      if (path === screen) throw new Error('deleted');
      return Buffer.from('changed frozen bytes');
    });
    assert.deepEqual(result.errors, [
      `removed original GUI: ${screen}`,
      `changed frozen GUI: ${widget}`,
    ]);
  } finally {
    fixture.cleanup();
  }
});

test('standalone CLI runs through a symlink instead of silently skipping checks', () => {
  const root = mkdtempSync(join(tmpdir(), 'raiju-preservation-cli-'));
  try {
    const component = join(root, 'component');
    mkdirSync(join(component, 'scripts'), { recursive: true });
    mkdirSync(join(component, 'upstream'), { recursive: true });
    copyFileSync(
      new URL('./check-preservation.mjs', import.meta.url),
      join(component, 'scripts', 'check-preservation.mjs'),
    );
    copyFileSync(
      new URL('../upstream/buzz-mobile.tar.gz', import.meta.url),
      join(component, 'upstream', 'buzz-mobile.tar.gz'),
    );
    const alias = join(root, 'mobile-alias');
    symlinkSync(component, alias, 'dir');
    const result = spawnSync(
      process.execPath,
      [join(alias, 'scripts', 'check-preservation.mjs')],
      { cwd: root, encoding: 'utf8' },
    );
    // No app files were copied: a real scan must reject their deletion.
    assert.equal(result.status, 1, result.stderr);
    assert.match(result.stdout, /preservation: 0 original GUI files retained/);
    assert.match(result.stderr, /removed original GUI: assets\//);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('baseline coverage rejects empty, partial, and narrowed frozen entry sets', () => {
  const entries = loadBaseline();
  assert.doesNotThrow(() => assertBaselineComplete(entries));
  assert.throws(() => assertBaselineComplete([]), /incomplete Buzz baseline/);
  assert.throws(
    () => assertBaselineComplete(entries.filter(({ path }) => path !== screen)),
    /incomplete Buzz baseline/,
  );
  const narrowed = entries.map((item) => item.path === widget
    ? { ...item, path: 'lib/features/channels/synthetic_gui.dart' }
    : item);
  assert.throws(
    () => assertBaselineComplete(narrowed),
    /expected 301 GUI files \(85 frozen\), got 301 \(84 frozen\)/,
  );
});
