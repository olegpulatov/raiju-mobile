#!/usr/bin/env node
// Mechanical guard against selective GUI replacement. Diff/screenshots still
// require review; file existence and hashes alone cannot prove visual parity.
import { createHash } from 'node:crypto';
import {
  lstatSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const baseline = 'ac84469';
export const archiveSha256 = '9b87fc49274e13f9577e103a7e2686f0d212b5adb03a4955036bf8e255f477cf';
const componentRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const archivePath = join(componentRoot, 'upstream', 'buzz-mobile.tar.gz');
const nativeVisual = /ios\/Runner\/(JumpToLatestGlassButton|StickyDateGlassHeader|ConcentricSheetSurface|ThemePaginationGlassControl|NativeAttachmentPopover[^/]*|NativeEmojiPicker[^/]*|NativeMessageActionSurface|NativeProfileTextEditor|NativeSkinToneControl|InlinePhotoPicker)\.swift$/;
// Exact reviewed action/data adapters, not a broad native-renderer exemption.
// Re-review source and visuals before changing these Git blob hashes.
const reviewedNativeAdapters = new Map([
  ['ios/Runner/NativeAttachmentPopover.swift', 'fd7ee1783cd76277b835989012569af744cb8072'],
  ['ios/Runner/NativeAttachmentPopoverCoordinator.swift', '3d8c5510c3598c12f371107a00623681dce64139'],
  ['ios/Runner/NativeAttachmentPopoverMenu.swift', '165228e59c51dc0cf3cf0a8b1f1e4b5d5e29c5c5'],
]);
// Owner-authorized branding edits are frozen to exact reviewed bytes, not a
// shared-widget exemption. This also extends coverage to native launch assets.
export const reviewedBrandingAdapters = new Map(Object.entries(
  JSON.parse(readFileSync(join(componentRoot, 'upstream', 'branding-adaptations.json'), 'utf8')).blobHashes,
));
const reviewedVisualAdapters = new Map([
  ...reviewedNativeAdapters,
  ...reviewedBrandingAdapters,
]);
// These checkpoint files are orphaned Buzz backend parts, not visual sources.
// Their full source remains recoverable from the immutable checkpoint archive.
const retiredBackendParts = new Set([
  'lib/features/channels/channel_directory.dart',
  'lib/features/channels/channel_member_snapshots.dart',
  'lib/features/channels/channel_push_cache.dart',
]);
// Shared presentation directories are existence-guarded but adaptable. Their
// provider/parser/data companions remain explicit backend/data exclusions.
const sharedVisual = /lib\/shared\/(?:emoji|mentions|custom_emoji|profile)\//;
const sharedVisualFiles = new Set([
  'lib/app.dart',
  'lib/shared/animated_avatar.dart',
  'lib/shared/syntax_highlight.dart',
  'lib/shared/mentions/mention_bindings.dart',
]);

export function isVisual(path) {
  if (retiredBackendParts.has(path)) return false;
  if (reviewedBrandingAdapters.has(path)) return true;
  return path.startsWith('assets/') ||
    path.startsWith('lib/shared/widgets/') ||
    path.startsWith('lib/shared/theme/') ||
    (sharedVisual.test(path) &&
      !/(provider|parser|data|bindings|tags|repository|service|storage|transport|protocol)/.test(path)) ||
    sharedVisualFiles.has(path) ||
    (path.startsWith('lib/features/') && path.endsWith('.dart') &&
      !/(provider|repository|service|storage|transport|protocol)/.test(path)) ||
    nativeVisual.test(path);
}

export function isFrozen(path) {
  if (reviewedBrandingAdapters.has(path)) return true;
  return path.startsWith('assets/') ||
    path.startsWith('lib/shared/widgets/') ||
    (path.startsWith('lib/shared/theme/') &&
      !/(provider|sync|preference)/.test(path)) ||
    path.startsWith('lib/features/pairing/pairing_qr_scanner') ||
    nativeVisual.test(path);
}

export function blobHash(bytes, algorithm = 'sha1') {
  return createHash(algorithm).update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
}

export function inspect(entries, read, algorithm = 'sha1', reviewedAdapters = reviewedVisualAdapters) {
  const errors = [];
  const changed = [];
  let preserved = 0;
  let frozen = 0;
  let reviewed = 0;
  for (const { path, hash } of entries) {
    if (!isVisual(path)) continue;
    let bytes;
    try { bytes = read(path); }
    catch {
      errors.push(`removed original GUI: ${path}`);
      continue;
    }
    preserved++;
    const actual = blobHash(bytes, algorithm);
    if (isFrozen(path)) {
      frozen++;
      const approved = reviewedAdapters.get(path);
      if (actual !== (approved ?? hash)) {
        errors.push(`changed frozen GUI: ${path}`);
      } else if (approved) {
        reviewed++;
        changed.push(path);
      }
    } else if (actual !== hash) {
      changed.push(path);
    }
  }
  return { errors, changed, preserved, frozen, reviewed };
}

function collectEntries(directory, relative = '') {
  const entries = [];
  for (const name of readdirSync(directory).sort()) {
    const path = relative ? `${relative}/${name}` : name;
    const absolute = join(directory, name);
    const stat = lstatSync(absolute);
    if (stat.isDirectory()) {
      entries.push(...collectEntries(absolute, path));
    } else if (stat.isFile()) {
      entries.push({ path, hash: blobHash(readFileSync(absolute)) });
    }
  }
  return entries;
}

export function loadBaseline({
  archive = archivePath,
  expectedSha256 = archiveSha256,
  temporaryRoot = tmpdir(),
} = {}) {
  let bytes;
  try {
    bytes = readFileSync(archive);
  } catch {
    throw new Error(`missing immutable Buzz baseline archive: ${archive}`);
  }
  const actualSha256 = createHash('sha256').update(bytes).digest('hex');
  if (actualSha256 !== expectedSha256) {
    throw new Error(`corrupt immutable Buzz baseline archive: expected SHA-256 ${expectedSha256}, got ${actualSha256}`);
  }

  const extraction = mkdtempSync(join(temporaryRoot, 'raiju-buzz-baseline-'));
  try {
    const result = spawnSync('tar', ['-xzf', '-', '-C', extraction], {
      input: bytes,
      encoding: 'utf8',
      maxBuffer: 8 * 1024 * 1024,
    });
    if (result.error) {
      throw new Error(`cannot extract immutable Buzz baseline with system tar: ${result.error.message}`);
    }
    if (result.status !== 0) {
      const detail = result.stderr.trim();
      throw new Error(`cannot extract immutable Buzz baseline with system tar${detail ? `: ${detail}` : ''}`);
    }
    const source = join(extraction, 'mobile');
    try {
      if (!lstatSync(source).isDirectory()) throw new Error();
    } catch {
      throw new Error('immutable Buzz baseline archive does not contain mobile/');
    }
    return collectEntries(source);
  } finally {
    rmSync(extraction, { recursive: true, force: true });
  }
}

export function assertBaselineComplete(entries) {
  // These counts belong to the immutable snapshot and reviewed GUI policy.
  const visual = entries.filter(({ path }) => isVisual(path));
  const frozen = visual.filter(({ path }) => isFrozen(path));
  if (visual.length !== 315 || frozen.length !== 99) {
    throw new Error(
      `incomplete Buzz baseline: expected 315 GUI files (99 frozen, including native launch branding), got ${visual.length} (${frozen.length} frozen)`,
    );
  }
}

export function main() {
  const entries = loadBaseline();
  assertBaselineComplete(entries);
  const result = inspect(entries, (path) => readFileSync(join(componentRoot, path)));
  // New shared mark is not present in Buzz's archive, but still requires its
  // reviewed bytes. Original assets remain retained and checked separately.
  const baselinePaths = new Set(entries.map(({ path }) => path));
  const additions = [...reviewedBrandingAdapters]
    .filter(([path]) => !baselinePaths.has(path))
    .map(([path, hash]) => ({ path, hash }));
  result.errors.push(...inspect(additions, (path) => readFileSync(join(componentRoot, path))).errors);
  for (const error of result.errors) console.error(error);
  console.log(`preservation: ${result.preserved} original GUI files retained; ${result.frozen} frozen files checked`);
  console.log(`${result.reviewed} frozen files use exact reviewed native-effect or branding hashes; remaining frozen files match baseline`);
  console.log(`${result.changed.length} adapted GUI files require source-diff and screenshot review`);
  if (result.errors.length) {
    console.error('do not regenerate a baseline to hide a redesign; resolve changes against ADR-001');
    return 1;
  }
  return 0;
}

function isMainModule() {
  try {
    return process.argv[1] !== undefined &&
      realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);
  } catch {
    // Importing processes may have a non-file first argument.
    return false;
  }
}

if (isMainModule()) {
  try { process.exitCode = main(); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
