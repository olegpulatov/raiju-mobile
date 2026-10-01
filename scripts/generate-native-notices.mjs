#!/usr/bin/env node
// Explicit refresh of checked-in offline notices. Not a build/test gate.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const targets = ['aarch64-apple-ios', 'aarch64-apple-ios-sim', 'x86_64-apple-ios'];
const output = join(root, 'licenses/native-notices.json');
const hash = (text) => createHash('sha256').update(text).digest('hex');
const read = (path) => readFileSync(path, 'utf8');
const compare = (a, b) => a < b ? -1 : a > b ? 1 : 0;
const entries = new Map();
const inventory = [];
const unresolved = [];
const inputs = new Map();

function record(path, source) {
  const text = read(path);
  inputs.set(source, { source, sha256: hash(text) });
  return text;
}

function add(packages, text, source) {
  if (!text.trim()) throw new Error(`Empty license material: ${source}`);
  const key = hash(text);
  const entry = entries.get(key) ?? { packages: new Set(), text, sources: new Set() };
  for (const name of packages) entry.packages.add(name);
  entry.sources.add(source);
  entries.set(key, entry);
}

// Retain bundled C sources (Opus), third-party notices (ring), and license
// directories as well as each crate's own root license. Never follow symlinks.
function legalFiles(directory, prefix = '', inLicenseDirectory = false) {
  const result = [];
  for (const item of readdirSync(join(directory, prefix), { withFileTypes: true })) {
    const path = join(prefix, item.name);
    if (item.isDirectory() && !['.git', 'target'].includes(item.name)) {
      result.push(...legalFiles(directory, path, inLicenseDirectory || /^licen[sc]es?$/i.test(item.name)));
    } else if (item.isFile() && (inLicenseDirectory || /^(licen[sc]es?|copying|copyright|notices?|unlicense|authors)([._-]|$)/i.test(item.name))) {
      result.push(path);
    }
  }
  return result.sort(compare);
}

function installedPodSpec(name, version) {
  const local = join(root, 'ios/Pods/Local Podspecs', `${name}.podspec.json`);
  const bucket = createHash('md5').update(name).digest('hex').slice(0, 3).split('');
  const cached = join(process.env.COCOAPODS_SPEC_REPO ?? join(homedir(), '.cocoapods/repos/trunk/Specs'), ...bucket, name, version, `${name}.podspec.json`);
  const path = existsSync(local) ? local : cached;
  if (!existsSync(path)) return null;
  return JSON.parse(record(path, `cocoapods-specs/${name}/${version}/${name}.podspec.json`));
}

function generate() {
  record(join(root, 'spark-core/Cargo.toml'), 'spark-core/Cargo.toml');
  record(join(root, 'spark-core/Cargo.lock'), 'spark-core/Cargo.lock');
  const packages = new Map();
  for (const target of targets) {
    const metadata = JSON.parse(execFileSync('cargo', [
      'metadata', '--offline', '--locked', '--format-version', '1',
      '--manifest-path', join(root, 'spark-core/Cargo.toml'), '--filter-platform', target,
    ], { cwd: root, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 }));
    const resolved = new Set(metadata.resolve.nodes.map((node) => node.id));
    for (const pkg of metadata.packages) {
      if (resolved.has(pkg.id) && pkg.name !== 'spark-core') packages.set(pkg.id, pkg);
    }
  }

  // These precise upstream releases declare an Apache alternative but omit
  // full license files. Choose that alternative and supply the unmodified
  // standard text from an installed crate; never invent MIT copyright holders.
  const apacheFallbacks = new Set(['asn1-rs-impl@0.2.0', 'webrtc@0.17.2', 'yasna@0.5.2']);
  const apacheDonor = [...packages.values()].find((pkg) => pkg.name === 'asn1-rs' && pkg.version === '0.6.2');
  for (const pkg of [...packages.values()].sort((a, b) => compare(`${a.name} ${a.version}`, `${b.name} ${b.version}`))) {
    const label = `${pkg.name} ${pkg.version} (Spark native)`;
    const directory = dirname(pkg.manifest_path);
    const origin = `${pkg.name}-${pkg.version}`;
    const manifest = record(pkg.manifest_path, `cargo/${origin}/Cargo.toml`);
    let bundledNative = null;
    if (pkg.name === 'opusic-sys') {
      const versionSource = `cargo/${origin}/opus/package_version`;
      const versionText = record(join(directory, 'opus/package_version'), versionSource);
      const version = /^PACKAGE_VERSION="([^"]+)"/m.exec(versionText)?.[1];
      if (!version) throw new Error('Cannot identify bundled Opus version');
      bundledNative = { name: 'Opus', version, source: versionSource, sha256: hash(versionText) };
    }
    const files = legalFiles(directory);
    if (pkg.license_file && !files.includes(pkg.license_file)) files.push(pkg.license_file);
    let fallback = null;
    if (!files.some((path) => /^(licen[sc]e|copying|unlicense)/i.test(path))) {
      if (apacheFallbacks.has(`${pkg.name}@${pkg.version}`) && pkg.license?.includes('Apache-2.0') && apacheDonor) {
        const source = `cargo/${apacheDonor.name}-${apacheDonor.version}/LICENSE-APACHE`;
        const text = record(join(dirname(apacheDonor.manifest_path), 'LICENSE-APACHE'), source);
        fallback = { selectedLicense: 'Apache-2.0', source, sha256: hash(text), reason: 'Package declares Apache-2.0 alternative; packaged full text absent' };
        add([label], text, source);
      } else {
        unresolved.push({ package: label, reason: 'No full license text in installed source', declaredLicense: pkg.license });
        add([label], `License text unavailable in installed source. Declared license: ${pkg.license ?? 'unknown'}. This entry is not legal clearance.`, `cargo/${origin}/Cargo.toml`);
      }
    }
    for (const path of files.sort(compare)) {
      const source = `cargo/${origin}/${path}`;
      const labels = bundledNative && path.startsWith('opus/')
        ? [label, `${bundledNative.name} ${bundledNative.version} (bundled native)`]
        : [label];
      add(labels, record(join(directory, path), source), source);
    }
    const vcsPath = join(directory, '.cargo_vcs_info.json');
    inventory.push({
      ecosystem: 'cargo', name: pkg.name, version: pkg.version,
      declaredLicense: pkg.license, repository: pkg.repository, registry: pkg.source,
      manifestSha256: hash(manifest),
      ...(existsSync(vcsPath) ? { vcs: JSON.parse(record(vcsPath, `cargo/${origin}/.cargo_vcs_info.json`)) } : {}),
      files, fallback, ...(bundledNative ? { bundledNative } : {}),
    });
  }

  const lock = record(join(root, 'ios/Podfile.lock'), 'ios/Podfile.lock');
  const installed = read(join(root, 'ios/Pods/Manifest.lock'));
  if (lock !== installed) throw new Error('Installed Pods do not match Podfile.lock; run maintained pod install before refresh');
  const podVersions = new Map();
  for (const line of lock.split('\n\nDEPENDENCIES:')[0].split('\n')) {
    const match = /^  - "?([^"(]+?)"? \(([^)]+)\):?$/.exec(line);
    if (match) {
      const name = match[1].split('/')[0];
      const version = match[2];
      if (podVersions.has(name) && podVersions.get(name) !== version) throw new Error(`Conflicting pod version: ${name}`);
      podVersions.set(name, version);
    }
  }
  const ackPath = join(root, 'ios/Pods/Target Support Files/Pods-Runner/Pods-Runner-acknowledgements.markdown');
  const ackSource = relative(root, ackPath);
  const acknowledgments = record(ackPath, ackSource);
  const sections = new Map();
  for (const section of acknowledgments.split(/^## /m).slice(1)) {
    const newline = section.indexOf('\n');
    sections.set(section.slice(0, newline).trim(), section.slice(newline + 1).replace(/\nGenerated by CocoaPods[\s\S]*$/, '').trim());
  }
  for (const [name, version] of [...podVersions].sort(([a], [b]) => compare(a, b))) {
    const label = `${name} ${version} (iOS pod)`;
    const text = sections.get(name);
    if (text) add([label], text, ackSource);
    const directory = join(root, 'ios/Pods', name);
    const files = existsSync(directory) ? legalFiles(directory) : [];
    for (const path of files) {
      const source = `ios/Pods/${name}/${path}`;
      add([label], record(join(directory, path), source), source);
    }
    // Flutter's dummy 1.0.0 pod has no acknowledgment; actual Flutter SDK and
    // engine notices come from automatic NOTICES.Z, not this pod's placeholder.
    if (!text && !files.length && name !== 'Flutter') {
      unresolved.push({ package: label, reason: 'No CocoaPods acknowledgment or installed legal file' });
    }
    const spec = installedPodSpec(name, version);
    inventory.push({ ecosystem: 'cocoapods', name, version, acknowledgment: Boolean(text), files,
      ...(name === 'Flutter' ? { automatic: 'Flutter SDK and sky_engine NOTICES.Z' } : {}),
      ...(spec ? { declaredLicense: spec.license, homepage: spec.homepage, source: spec.source } : {}),
      ...(/^(GoogleMLKit|MLImage|MLKit)/.test(name) ? { terms: 'licenses/google-ml-kit-terms.txt' } : {}),
    });
  }
  record(join(root, 'licenses/google-ml-kit-terms.txt'), 'licenses/google-ml-kit-terms.txt');
  const platformAdaptations = [];
  const simulatorState = join(root, 'ios/Pods/MLKitAppleSiliconSimulator');
  if (existsSync(simulatorState)) {
    const sources = [
      'ios/.symlinks/plugins/google_mlkit_commons/ios/scripts/apple_silicon_simulator.rb',
      'ios/.symlinks/plugins/google_mlkit_commons/ios/scripts/patch_arm64_simulator.py',
      'ios/Pods/MLKitAppleSiliconSimulator/patch_arm64_simulator.py',
    ];
    const texts = sources.map((source) => record(join(root, source), source));
    const files = legalFiles(simulatorState);
    for (const path of files) {
      const source = `ios/Pods/MLKitAppleSiliconSimulator/${path}`;
      add(['Google ML Kit Apple Silicon simulator build adaptation'], record(join(simulatorState, path), source), source);
    }
    platformAdaptations.push({
      name: 'MLKitAppleSiliconSimulator',
      package: `google_mlkit_commons ${podVersions.get('google_mlkit_commons')}`,
      sources, files, copiedPatcherMatchesPackage: hash(texts[1]) === hash(texts[2]),
      scope: 'Build helper relabels LC_BUILD_VERSION.platform in existing locked MLKit/MLImage frameworks; no additional binary download or framework. Helper license comes from automatic google_mlkit_commons notices; framework notices remain those of locked pods.',
    });
  }

  const result = {
    schemaVersion: 1,
    generator: 'scripts/generate-native-notices.mjs',
    scope: 'Union of Cargo resolved package graphs for Apple library targets, including build/target superset; installed Runner pods and embedded native legal materials. Dart and Flutter engine licenses remain in automatic NOTICES.Z.',
    targets,
    inputs: [...inputs.values()].sort((a, b) => compare(a.source, b.source)),
    inventory,
    platformAdaptations,
    unresolved,
    entries: [...entries.values()].map((entry) => ({ packages: [...entry.packages].sort(compare), text: entry.text, sources: [...entry.sources].sort(compare) }))
      .sort((a, b) => compare(a.packages.join('\n'), b.packages.join('\n'))),
  };
  writeFileSync(output, `${JSON.stringify(result, null, 2)}\n`);
  console.log(`Generated ${relative(root, output)}: ${packages.size} Cargo packages, ${podVersions.size} pods, ${result.entries.length} unique texts, ${unresolved.length} unresolved entries`);
  for (const item of unresolved) console.warn(`${item.package}: ${item.reason}`);
}

if (process.argv.length > 2) {
  console.error('usage: node scripts/generate-native-notices.mjs');
  process.exitCode = 2;
} else {
  try { generate(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
