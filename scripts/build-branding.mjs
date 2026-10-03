#!/usr/bin/env node
// Rebuild only mobile UI/launch marks from canonical Raiju source contours.
// Never rewrites preservation pins or the immutable upstream archive.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const brand = process.argv[2];
assert(brand && process.argv.length === 3, 'usage: node scripts/build-branding.mjs /path/to/raiju/brand');
const sources = ['ears-body.png', 'ears-bolt.png'].map(name => join(resolve(brand), 'sources', name));
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const sourceHashes = Object.fromEntries(sources.map(path => [path.split('/').at(-1), sha256(readFileSync(path))]));
const work = mkdtempSync(join(tmpdir(), 'raiju-mobile-brand-'));
const encode = ['-strip', '-depth', '8', '-define', 'png:exclude-chunks=date,time', '-define', 'png:color-type=6'];
const outputs = [
  ['assets/images/raiju-mark.png', 745, 745],
  ['ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage.png', 168, 134],
  ['ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@2x.png', 336, 268],
  ['ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage@3x.png', 504, 402],
  ['android/app/src/main/res/mipmap-mdpi/launch_image.png', 288, 230],
  ['android/app/src/main/res/mipmap-hdpi/launch_image.png', 432, 346],
  ['android/app/src/main/res/mipmap-xhdpi/launch_image.png', 576, 461],
  ['android/app/src/main/res/mipmap-xxhdpi/launch_image.png', 864, 691],
  ['android/app/src/main/res/mipmap-xxxhdpi/launch_image.png', 1152, 922],
];
try {
  const mark = join(work, 'mark.png');
  execFileSync('magick', [
    '-size', '1254x1254', 'xc:none', sources[0], '-composite', sources[1], '-composite',
    '-crop', '745x733+253+277', '+repage', '-gravity', 'center', '-background', 'none',
    '-extent', '745x745', ...encode, mark,
  ]);
  for (const [path, canvas, width] of outputs) {
    const target = join(root, path);
    mkdirSync(dirname(target), { recursive: true });
    execFileSync('magick', [
      '-size', `${canvas}x${canvas}`, 'xc:none', '(', mark, '-resize', `${width}x${width}`, ')',
      '-gravity', 'center', '-composite', ...encode, target,
    ]);
    writeFileSync(`${target}.notice.json`, JSON.stringify({
      notice: 'MODIFIED FOR RAIJU: owner-authorized replacement of active Buzz branding with canonical Raiju ears and separate bolt. Original Buzz artwork remains in immutable upstream archive.',
      author: 'Raiju contributors; AI-generated shape source via OpenAI Codex',
      license: 'Apache-2.0 for Raiju modifications, to extent copyright applies; AI imagery may have limited copyright protection',
      source: 'brand/sources/ears-body.png and ears-bolt.png; original provenance in Raiju workspace brand/README.md',
      sourceSha256: sourceHashes,
      sha256: sha256(readFileSync(target)),
    }, null, 2) + '\n');
  }
  console.log(`generated ${outputs.length} mobile UI/launch marks; review assets before updating scoped branding pins`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
