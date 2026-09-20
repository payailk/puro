import 'dart:convert';
import 'dart:io' as io;

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:puro/src/command_result.dart';
import 'package:puro/src/config.dart';
import 'package:puro/src/env/command.dart';
import 'package:puro/src/env/engine.dart';
import 'package:puro/src/env/env_shims.dart';
import 'package:puro/src/env/gc.dart';
import 'package:puro/src/env/list.dart';
import 'package:puro/src/env/ohos.dart';
import 'package:puro/src/env/version.dart';
import 'package:puro/src/logger.dart';
import 'package:puro/src/proto/puro.pb.dart';
import 'package:puro/src/provider.dart';
import 'package:puro/src/terminal.dart';
import 'package:puro/src/version.dart';
import 'package:test/test.dart';

const _nativeLauncher = r'''#!/usr/bin/env bash
set -e
if [ -f "$FLUTTER_ROOT/../fail-initialize" ]; then
  echo 'fixture initialization failed' >&2
  exit 9
fi
mkdir -p "$FLUTTER_ROOT/bin/cache/dart-sdk"
cp "$FLUTTER_ROOT/bin/internal/engine.ohos.version" "$FLUTTER_ROOT/bin/cache/engine-dart-sdk.stamp"
git -C "$FLUTTER_ROOT" rev-parse HEAD > "$FLUTTER_ROOT/bin/cache/flutter_tools.stamp"
touch "$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot"
printf '%s\n' "$(basename "$0")" "$FLUTTER_OHOS_STORAGE_BASE_URL" "$PWD" "$@"
printf 'upstream: %s\n' "$FLUTTER_STORAGE_BASE_URL"
if [ "${1:-}" = '--stdin' ]; then cat; fi
if [ "${1:-}" = '--fail' ]; then
  echo 'native stderr' >&2
  exit 17
fi
''';

Future<String> _git(Directory repository, List<String> args) async {
  final result = await io.Process.run('git', args, workingDirectory: repository.path);
  if (result.exitCode != 0) throw StateError('${result.stderr}');
  return (result.stdout as String).trim();
}

(RootScope, PuroConfig) _scope(Directory root, Directory origin, {
  String source = 'https://ohos.example',
  String upstream = 'https://official.invalid',
}) {
  final fs = root.fileSystem;
  final config = PuroConfig(
    fileSystem: fs,
    gitExecutable: fs.file('git'),
    globalPrefsJsonFile: root.childFile('prefs.json'),
    puroRoot: root,
    legacyPubCacheDir: root.childDirectory('pub-cache'),
    legacyPubCache: true,
    homeDir: root,
    projectDir: null,
    parentProjectDir: null,
    flutterGitUrl: 'https://official.invalid/flutter.git',
    engineGitUrl: 'https://official.invalid/engine.git',
    dartSdkGitUrl: 'https://official.invalid/dart.git',
    releasesJsonUrl: Uri.parse('https://official.invalid/releases.json'),
    flutterStorageBaseUrl: Uri.parse(upstream),
    environmentOverride: null,
    puroBuildsUrl: Uri.parse('https://official.invalid/builds'),
    buildTarget: PuroBuildTarget.query(),
    enableShims: false,
    shouldInstall: false,
    shouldSkipCacheSync: false,
    ohosFlutterGitUrl: origin.uri.toString(),
    ohosFlutterStorageBaseUrl: source,
  );
  final scope = RootScope()
    ..add(PuroConfig.provider, config)
    ..add(PuroLogger.provider, PuroLogger())
    ..add(Terminal.provider, Terminal(stdout: io.stdout)..enableStatus = false)
    ..add(globalPrefsJsonFileProvider, config.globalPrefsJsonFile)
    ..add(isFirstRunProvider, false);
  return (scope, config);
}

void main() {
  test('old environment preferences default to official; new fields round-trip', () {
    final old = PuroEnvPrefsModel()..mergeFromProto3Json({'patched': false});
    expect(old.ohos, isFalse);
    final prefs = PuroEnvPrefsModel(ohos: true, ohosCacheSource: 'https://ohos.example');
    final restored = PuroEnvPrefsModel()..mergeFromProto3Json(prefs.toProto3Json());
    expect(restored.ohos, isTrue);
    expect(restored.ohosCacheSource, 'https://ohos.example');
    final mirrors = PuroGlobalPrefsModel(
      ohosFlutterGitUrl: 'https://ohos.example/flutter.git',
      ohosFlutterStorageBaseUrl: 'https://ohos.example',
    );
    expect(PuroGlobalPrefsModel.fromBuffer(mirrors.writeToBuffer()).ohosFlutterGitUrl,
        mirrors.ohosFlutterGitUrl);
  });

  group('OHOS environments', () {
    late Directory root;
    late Directory origin;
    late RootScope scope;
    late PuroConfig config;
    late EnvConfig environment;

    setUp(() async {
      const fs = LocalFileSystem();
      root = fs.systemTempDirectory.createTempSync('puro ohos test ');
      origin = root.childDirectory('origin')..createSync();
      await _git(origin, ['init', '-b', defaultOhosFlutterRef]);
      await _git(origin, ['config', 'user.name', 'Puro test']);
      await _git(origin, ['config', 'user.email', 'puro-test@example.invalid']);
      for (final name in ['flutter', 'dart']) {
        final file = origin.childFile('bin/$name')..createSync(recursive: true);
        file.writeAsStringSync(_nativeLauncher);
        await io.Process.run('chmod', ['+x', file.path]);
        origin.childFile('bin/$name.bat').writeAsStringSync('@echo native $name\r\n');
      }
      for (final name in ['shared.sh', 'shared.bat', 'update_dart_sdk.sh', 'update_dart_sdk.ps1']) {
        (origin.childFile('bin/internal/$name')..createSync(recursive: true))
            .writeAsStringSync('native internal $name\n');
      }
      origin.childFile('bin/internal/engine.version').writeAsStringSync('${'a' * 40}\n');
      origin.childFile('bin/internal/engine.ohos.version').writeAsStringSync('ohos-engine-1\n');
      origin.childFile('README.md').writeAsStringSync('initial\n');
      await _git(origin, ['add', '.']);
      await _git(origin, ['commit', '-m', 'initial']);
      await _git(origin, ['tag', '3.41.9-ohos-test']);
      (scope, config) = _scope(root.childDirectory('puro root')..createSync(), origin);
      environment = config.getEnv('harmony');
    });

    tearDown(() {
      root.deleteSync(recursive: true);
    });

    Future<void> create({String ref = defaultOhosFlutterRef}) async {
      await createOhosEnvironment(scope: scope, envName: 'harmony', ref: ref);
    }

    test('creates independent native cache and never syncs into official cache', () async {
      final official = config.sharedCachesDir.childDirectory('a' * 40)..createSync(recursive: true);
      official.childFile('sentinel').writeAsStringSync('official');
      await create();
      final prefs = await environment.readPrefs(scope: scope);
      expect(prefs.ohos, isTrue);
      expect(prefs.forkRemoteUrl, origin.uri.toString());
      expect(prefs.desiredVersion.branch, defaultOhosFlutterRef);
      expect(config.sharedFlutterDir.existsSync(), isFalse);
      expect(config.sharedFlutterToolsDir.existsSync(), isFalse);
      expect(environment.flutter.cache.engineVersion!.trim(), 'ohos-engine-1');
      await syncFlutterCache(scope: scope, environment: environment);
      expect(official.childFile('sentinel').readAsStringSync(), 'official');
      expect(official.listSync().length, 1);
      expect(environment.flutter.cacheDir.listSync(followLinks: false).whereType<Link>(), isEmpty);
      expect(environment.flutter.sdkDir.childFile('bin/internal/shared.sh').readAsStringSync(),
          'native internal shared.sh\n');
      final listing = await listEnvironments(scope: scope);
      expect(listing.results.singleWhere((e) => e.ohos).toModel().ohos, isTrue);
      expect((await getEnvironmentFlutterVersion(scope: scope, environment: environment))!.branch,
          defaultOhosFlutterRef);
    });

    test('forwards native arguments, cwd, stdin, stderr and exit status', () async {
      await create();
      final output = <int>[];
      final errors = <int>[];
      final code = await runDartCommand(
        scope: scope, environment: environment,
        args: ['--stdin', 'argument with spaces', r'literal $HOME'],
        workingDirectory: root.path,
        stdin: Stream.value(utf8.encode('input payload\n')),
        onStdout: output.addAll,
      );
      expect(code, 0);
      expect(utf8.decode(output), contains('dart\nhttps://ohos.example\n${root.resolveSymbolicLinksSync()}\n'));
      expect(utf8.decode(output), contains('argument with spaces\nliteral \$HOME\n'));
      expect(utf8.decode(output), contains('upstream: https://official.invalid\ninput payload'));
      expect(await runFlutterCommand(
        scope: scope, environment: environment, args: ['--fail'], onStderr: errors.addAll,
      ), 17);
      expect(utf8.decode(errors), contains('native stderr'));
    });

    test('official environments still use the existing shared cache', () async {
      final official = config.getEnv('official');
      official.envDir.createSync(recursive: true);
      await _git(root, ['clone', origin.uri.toString(), official.flutterDir.path]);
      final shared = config.sharedCachesDir.childDirectory('a' * 40)..createSync(recursive: true);
      shared.childFile('sentinel').writeAsStringSync('official');
      await syncFlutterCache(scope: scope, environment: official);
      final link = root.fileSystem.link(official.flutter.cacheDir.childFile('sentinel').path);
      expect(link.existsSync(), isTrue);
      expect(link.targetSync(), shared.childFile('sentinel').path);
    });

    test('IDE launchers route through Puro; native bypass retains original filename', () async {
      await create();
      config.binDir.createSync(recursive: true);
      final puro = config.binDir.childFile('puro');
      puro.writeAsStringSync(r'''#!/usr/bin/env bash
printf 'puro route: %s\n' "$@"
printf 'environment: %s\n' "$PURO_FLUTTER_BIN"
exit 23
''');
      await io.Process.run('chmod', ['+x', puro.path]);
      final result = await io.Process.run(environment.flutter.flutterScript.path, ['doctor', 'with spaces']);
      expect(result.exitCode, 23);
      expect(result.stdout, contains('puro route: flutter\npuro route: doctor\npuro route: with spaces'));
      final original = environment.flutter.flutterScript.readAsStringSync();
      await installEnvShims(scope: scope, environment: environment);
      expect(environment.flutter.flutterScript.readAsStringSync(), original);
      final windows = environment.flutterDir.childFile('bin/dart.bat').readAsStringSync();
      expect(windows, contains('GOTO puro_ohos_native'));
      expect(windows, endsWith('@echo native dart\n'));
    });

    test('changing OHOS source rebuilds local cache without touching symlink targets', () async {
      await create();
      final shared = config.sharedCachesDir.childDirectory('sentinel')..createSync(recursive: true);
      shared.childFile('keep').writeAsStringSync('keep');
      environment.flutter.cacheDir.childFile('old-source').writeAsStringSync('old');
      root.fileSystem.link(environment.flutter.cacheDir.childDirectory('artifacts').path).createSync(shared.path);
      final (otherScope, otherConfig) = _scope(config.puroRoot, origin, source: 'https://other-ohos.example');
      final otherEnv = otherConfig.getEnv('harmony');
      await runFlutterCommand(scope: otherScope, environment: otherEnv, args: ['--version']);
      expect(otherEnv.flutter.cacheDir.childFile('old-source').existsSync(), isFalse);
      expect(shared.childFile('keep').readAsStringSync(), 'keep');
      expect(jsonDecode((await otherEnv.readPrefs(scope: otherScope)).ohosCacheSource), {
        'flutterStorageBaseUrl': 'https://official.invalid',
        'ohosFlutterStorageBaseUrl': 'https://other-ohos.example',
      });
      clearOhosCache(otherEnv);
      root.fileSystem.link(otherEnv.flutter.cacheDir.path).createSync(shared.path);
      await runDartCommand(scope: otherScope, environment: otherEnv, args: ['--version']);
      expect(root.fileSystem.isLinkSync(otherEnv.flutter.cacheDir.path), isFalse);
      expect(shared.childFile('keep').readAsStringSync(), 'keep');
    });

    test('changing the upstream source also invalidates only the OHOS environment cache', () async {
      await create();
      final old = environment.flutter.cacheDir.childFile('old-upstream')..writeAsStringSync('old');
      final (otherScope, otherConfig) = _scope(config.puroRoot, origin, upstream: 'https://other-upstream.example');
      final output = <int>[];
      await runFlutterCommand(
        scope: otherScope, environment: otherConfig.getEnv('harmony'),
        args: ['--version'], onStdout: output.addAll,
      );
      expect(old.existsSync(), isFalse);
      expect(utf8.decode(output), contains('https://ohos.example'));
      expect(utf8.decode(output), contains('upstream: https://other-upstream.example'));
    });

    test('upgrades OHOS branch and switches to a pinned tag without official releases', () async {
      await create();
      final first = await _git(origin, ['rev-parse', 'HEAD']);
      origin.childFile('bin/internal/engine.ohos.version').writeAsStringSync('ohos-engine-2\n');
      await _git(origin, ['commit', '-am', 'new OHOS artifacts, same upstream engine']);
      final upgraded = await upgradeOhosEnvironment(scope: scope, environment: environment);
      expect(upgraded.to.commit, await _git(origin, ['rev-parse', 'HEAD']));
      expect(environment.flutter.cache.engineVersion!.trim(), 'ohos-engine-2');
      await upgradeOhosEnvironment(scope: scope, environment: environment, ref: '3.41.9-ohos-test');
      expect(await _git(environment.flutterDir, ['rev-parse', 'HEAD']), first);
      expect((await environment.readPrefs(scope: scope)).desiredVersion.tag, '3.41.9-ohos-test');
      final pinned = await upgradeOhosEnvironment(scope: scope, environment: environment);
      expect(pinned.to.commit, first);
      expect(pinned.to.tag, '3.41.9-ohos-test');
      await upgradeOhosEnvironment(scope: scope, environment: environment, ref: defaultOhosFlutterRef);
      expect(environment.flutter.cache.engineVersion!.trim(), 'ohos-engine-2');
    });

    test('protects local edits and commits; force explicitly replaces them', () async {
      await create();
      environment.flutterDir.childFile('README.md').writeAsStringSync('local edit\n');
      origin.childFile('README.md').writeAsStringSync('remote edit\n');
      await _git(origin, ['commit', '-am', 'remote']);
      final oldPrefs = (await environment.readPrefs(scope: scope)).desiredVersion.commit;
      await expectLater(upgradeOhosEnvironment(scope: scope, environment: environment), throwsA(isA<CommandError>()));
      expect(environment.flutterDir.childFile('README.md').readAsStringSync(), 'local edit\n');
      expect((await environment.readPrefs(scope: scope)).desiredVersion.commit, oldPrefs);
      await upgradeOhosEnvironment(scope: scope, environment: environment, force: true);
      expect(environment.flutterDir.childFile('README.md').readAsStringSync(), 'remote edit\n');
      await _git(environment.flutterDir, ['config', 'user.name', 'Puro test']);
      await _git(environment.flutterDir, ['config', 'user.email', 'puro-test@example.invalid']);
      environment.flutterDir.childFile('README.md').writeAsStringSync('local commit\n');
      await _git(environment.flutterDir, ['commit', '-am', 'local']);
      await expectLater(upgradeOhosEnvironment(scope: scope, environment: environment), throwsA(isA<CommandError>()));
      expect(environment.flutterDir.childFile('README.md').readAsStringSync(), 'local commit\n');
    });

    test('preserves edits to native launchers when an upgrade is rejected', () async {
      await create();
      environment.flutter.flutterScript.writeAsStringSync(
        '${environment.flutter.flutterScript.readAsStringSync()}\n# local launcher edit\n',
      );
      origin.childFile('README.md').writeAsStringSync('new commit\n');
      await _git(origin, ['commit', '-am', 'new commit']);
      await expectLater(upgradeOhosEnvironment(scope: scope, environment: environment),
          throwsA(isA<CommandError>()));
      expect(environment.flutter.flutterScript.readAsStringSync(), contains('# local launcher edit'));
      expect(await runFlutterCommand(scope: scope, environment: environment, args: ['--version']), 0);
      await upgradeOhosEnvironment(scope: scope, environment: environment, force: true);
      expect(environment.flutter.flutterScript.readAsStringSync(), isNot(contains('# local launcher edit')));
    });

    test('records a new tag even when it points at the same commit', () async {
      await create(ref: '3.41.9-ohos-test');
      await _git(origin, ['tag', '3.41.9-ohos-alias']);
      await upgradeOhosEnvironment(scope: scope, environment: environment, ref: '3.41.9-ohos-alias');
      expect((await environment.readPrefs(scope: scope)).desiredVersion.tag, '3.41.9-ohos-alias');
    });

    test('failed initialization can be retried without recreating or changing type', () async {
      environment.envDir.createSync(recursive: true);
      final fail = environment.envDir.childFile('fail-initialize')..writeAsStringSync('fail');
      await expectLater(create(), throwsA(isA<CommandError>()));
      expect((await environment.readPrefs(scope: scope)).ohos, isTrue);
      fail.deleteSync();
      await upgradeOhosEnvironment(scope: scope, environment: environment);
      expect(environment.flutter.cache.engineVersion!.trim(), 'ohos-engine-1');
      final marker = environment.flutter.cacheDir.childFile('keep')..writeAsStringSync('keep');
      await collectGarbage(scope: scope, maxUnusedCaches: 0, maxUnusedFlutterTools: 0);
      expect(marker.readAsStringSync(), 'keep');
    });

    test('invalid refs leave existing SDK and cache usable', () async {
      await create();
      final before = await _git(environment.flutterDir, ['rev-parse', 'HEAD']);
      await expectLater(upgradeOhosEnvironment(scope: scope, environment: environment, ref: '--help'),
          throwsA(isA<CommandError>()));
      expect(await _git(environment.flutterDir, ['rev-parse', 'HEAD']), before);
      expect(await runFlutterCommand(scope: scope, environment: environment, args: ['--version']), 0);
    });
  }, skip: io.Platform.isWindows ? 'Native fixture uses POSIX shell; Windows needs native SDK smoke testing' : false);
}
