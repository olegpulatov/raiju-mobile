#!/usr/bin/env node
// Resolve installed SDK without depending on another checkout or one username.
import { accessSync, constants, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { delimiter, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, spawnSync } from 'node:child_process';

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const wrapperPath = fileURLToPath(import.meta.url);
const commitKey = 'RAIJU_SOURCE_COMMIT';
const timeKey = 'RAIJU_BUILD_STARTED';

function currentMetadata() {
  const head = spawnSync('git', ['-C', projectRoot, 'rev-parse', '--verify', 'HEAD'], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
  });
  const status = spawnSync('git', ['-C', projectRoot, 'status', '--porcelain', '--untracked-files=normal', '--', '.'], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
  });
  const commit = head.status === 0 && status.status === 0
    ? `${head.stdout.trim().slice(0, 12)}${status.stdout.trim() ? '-dirty' : ''}`
    : 'unavailable';
  const now = new Date();
  const pad = (value) => String(value).padStart(2, '0');
  const started = `${pad(now.getFullYear() % 100)}-${pad(now.getMonth() + 1)}-${pad(now.getDate())} ${pad(now.getHours())}:${pad(now.getMinutes())}`;
  return { [commitKey]: commit, [timeKey]: started };
}

function injectBuildMetadata(args) {
  if (!['build', 'run', 'drive'].includes(args[0])) return args;
  const reserved = [commitKey, timeKey];
  for (let index = 0; index < args.length; index++) {
    const flag = args[index];
    const value = flag === '--dart-define'
      ? args[++index]
      : flag.startsWith('--dart-define=') ? flag.slice('--dart-define='.length) : '';
    if (value && reserved.includes(value.split('=', 1)[0])) {
      throw new Error('RAIJU_SOURCE_COMMIT and RAIJU_BUILD_STARTED are reserved build metadata; remove explicit overrides');
    }
    const defineFile = flag === '--dart-define-from-file'
      ? args[++index]
      : flag.startsWith('--dart-define-from-file=') ? flag.slice('--dart-define-from-file='.length) : '';
    if (defineFile) {
      // Flutter reads JSON here; fail closed when a file might override provenance.
      let defines;
      try { defines = JSON.parse(readFileSync(defineFile, 'utf8')); }
      catch { throw new Error('Cannot inspect --dart-define-from-file for reserved build metadata'); }
      if (defines && typeof defines === 'object' && reserved.some((key) => Object.hasOwn(defines, key))) {
        throw new Error('RAIJU_SOURCE_COMMIT and RAIJU_BUILD_STARTED are reserved build metadata; remove explicit overrides');
      }
    }
  }
  const metadata = currentMetadata();
  if (args.includes('--release') && metadata[commitKey] === 'unavailable') {
    throw new Error('Release build requires Git HEAD; source commit is unavailable');
  }
  const defines = Object.entries(metadata).map(([key, value]) => `--dart-define=${key}=${value}`);
  const position = args[0] === 'build' && args.length > 1 ? 2 : 1;
  return [...args.slice(0, position), ...defines, ...args.slice(position)];
}

function executable(path) {
  try { accessSync(path, constants.X_OK); return path; }
  catch { return undefined; }
}

function onPath(name) {
  if (name.includes('/')) return executable(resolve(name));
  for (const directory of (process.env.PATH ?? '').split(delimiter)) {
    const found = executable(join(directory, name));
    if (found) return found;
  }
}

function flutterPath() {
  if (process.env.RAIJU_FLUTTER_SDK_BINARY) {
    const sdk = onPath(process.env.RAIJU_FLUTTER_SDK_BINARY);
    if (!sdk || sdk === wrapperPath) throw new Error('RAIJU_FLUTTER_SDK_BINARY must name the real Flutter executable');
    return sdk;
  }
  if (process.env.FLUTTER === wrapperPath) throw new Error('Flutter wrapper needs RAIJU_FLUTTER_SDK_BINARY');
  if (process.env.FLUTTER) {
    const explicit = onPath(process.env.FLUTTER);
    if (!explicit) throw new Error('FLUTTER must name an executable Flutter 3.41.7 binary');
    return explicit;
  }
  // Reuse standard Hermit cache when present; PATH remains normal SDK boundary.
  const cached = [
    join(homedir(), 'Library/Caches/hermit/pkg/flutter-3.41.7/bin/flutter'),
    join(homedir(), '.cache/hermit/pkg/flutter-3.41.7/bin/flutter'),
  ].map(executable).find(Boolean);
  const found = cached ?? onPath('flutter');
  if (!found) throw new Error('Flutter 3.41.7 is required. Put its bin on PATH or set FLUTTER to its executable');
  return found;
}

if (process.argv[1] && resolve(process.argv[1]) === wrapperPath) {
  try {
    const [requested, ...rest] = process.argv.slice(2);
    const iosDart = requested === 'ios-dart';
    const tool = iosDart ? 'dart' : ['flutter', 'dart'].includes(requested) ? requested : 'flutter';
    const args = iosDart || requested === 'flutter' || requested === 'dart'
      ? rest
      : [requested, ...rest];
    if (!requested) throw new Error('usage: flutter-tool.mjs flutter|dart|ios-dart [arguments]');
    const flutter = flutterPath();
    const dart = process.env.DART ? onPath(process.env.DART) : executable(join(dirname(flutter), 'dart'));
    if (!dart) throw new Error('matching Dart 3.11.5 is required; set DART to its executable');
    const child = spawn(tool === 'flutter' ? flutter : dart,
      tool === 'flutter' && ['build', 'run', 'drive'].includes(args[0])
        ? injectBuildMetadata(args)
        : args, {
        stdio: 'inherit',
        env: {
          ...process.env,
          FLUTTER: iosDart ? wrapperPath : flutter,
          DART: dart,
          ...(iosDart ? { RAIJU_FLUTTER_SDK_BINARY: flutter } : {}),
        },
      });
    for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill(signal));
    child.on('error', () => { console.error('could not start Flutter/Dart tool'); process.exitCode = 1; });
    child.on('exit', (code, signal) => { process.exitCode = code ?? (signal === 'SIGINT' ? 130 : 1); });
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
