import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../command_result.dart';
import '../config.dart';
import '../file_lock.dart';
import '../git.dart';
import '../install/bin.dart';
import '../logger.dart';
import '../process.dart';
import '../provider.dart';
import '../workspace/gitignore.dart';

// Delete these because running them can corrupt our cache
const _sharedScripts = {
  'bin/internal/shared.bat',
  'bin/internal/shared.sh',
  'bin/internal/update_dart_sdk.ps1',
  'bin/internal/update_dart_sdk.sh',
};

const _binFiles = {
  'bin/dart',
  'bin/dart.bat',
  'bin/flutter',
  'bin/flutter.bat',
};

final _ignoredFiles = {
  'bin/cache',
  ..._binFiles,
  for (final name in _binFiles) '$name.bak',
  ..._sharedScripts,
};

Future<void> installEnvShims({
  required Scope scope,
  required EnvConfig environment,
}) async {
  if ((await environment.readPrefs(scope: scope)).ohos) {
    await installOhosEnvShims(scope: scope, environment: environment);
    return;
  }
  final log = PuroLogger.of(scope);
  final git = GitClient.of(scope);
  final flutterConfig = environment.flutter;

  log.d('installEnvShims');

  for (var name in _binFiles) {
    name = name.replaceAll('/', path.context.separator);
    final file = flutterConfig.sdkDir.childFile(name);
    final bakFile = flutterConfig.sdkDir.childFile('$name.bak');
    if (bakFile.existsSync()) {
      if (file.existsSync()) {
        log.d('deleting $bakFile');
        bakFile.deleteSync();
      } else {
        log.d('renaming $bakFile -> $file');
        bakFile.renameSync(file.path);
      }
    }
  }

  await updateGitignore(
    scope: scope,
    projectDir: environment.flutterDir,
    ignores: _ignoredFiles,
  );

  for (var name in _sharedScripts) {
    name = name.replaceAll('/', path.context.separator);
    final file = flutterConfig.sdkDir.childFile(name);
    if (file.existsSync()) file.deleteSync();
  }

  await writePassiveAtomic(
    scope: scope,
    file: flutterConfig.binDir.childFile('dart'),
    content:
        '$bashShimHeader\n'
        'export PURO_FLUTTER_BIN="\$(cd "\${PROG_NAME%/*}" ; pwd -P)"\n'
        'PURO_BIN="\$PURO_FLUTTER_BIN/../../../../bin"\n' // Backing out of envs/<name>/flutter/bin
        '"\$PURO_BIN/puro" dart "\$@"\n',
  );
  await writePassiveAtomic(
    scope: scope,
    file: flutterConfig.binDir.childFile('flutter'),
    content:
        '$bashShimHeader\n'
        'export PURO_FLUTTER_BIN="\$(cd "\${PROG_NAME%/*}" ; pwd -P)"\n'
        'PURO_BIN="\$PURO_FLUTTER_BIN/../../../../bin"\n' // Backing out of envs/<name>/flutter/bin
        '"\$PURO_BIN/puro" flutter "\$@"\n',
  );

  if (!Platform.isWindows) {
    await runProcess(scope, 'chmod', [
      '+x',
      flutterConfig.binDir.childFile('dart').path,
      flutterConfig.binDir.childFile('flutter').path,
    ]);
  }

  await writePassiveAtomic(
    scope: scope,
    file: flutterConfig.binDir.childFile('dart.bat'),
    content:
        '@echo off\n'
        'SETLOCAL ENABLEDELAYEDEXPANSION\n'
        'FOR %%i IN ("%~dp0.") DO SET PURO_FLUTTER_BIN=%%~fi\n'
        'SET PURO_BIN=%PURO_FLUTTER_BIN%\\..\\..\\..\\..\\bin\n'
        '"%PURO_BIN%\\puro" dart %* & exit /B !ERRORLEVEL!\n',
  );
  await writePassiveAtomic(
    scope: scope,
    file: flutterConfig.binDir.childFile('flutter.bat'),
    content:
        '@echo off\n'
        'SETLOCAL ENABLEDELAYEDEXPANSION\n'
        'FOR %%i IN ("%~dp0.") DO SET PURO_FLUTTER_BIN=%%~fi\n'
        'SET PURO_BIN=%PURO_FLUTTER_BIN%\\..\\..\\..\\..\\bin\n'
        '"%PURO_BIN%\\puro" flutter %* & exit /B !ERRORLEVEL!\n',
  );

  final assumeUnchanged = _binFiles.followedBy(_sharedScripts).toList();

  for (final fn in assumeUnchanged.toList()) {
    if (!await git.exists(repository: flutterConfig.sdkDir, path: fn)) {
      assumeUnchanged.remove(fn);
    }
  }

  log.d('assumeUnchanged: $assumeUnchanged');

  await git.assumeUnchanged(
    repository: flutterConfig.sdkDir,
    files: assumeUnchanged,
  );

  await updateGitAttributes(
    scope: scope,
    projectDir: environment.flutterDir,
    attributes: {
      for (final name in _binFiles.followedBy(_sharedScripts))
        name: 'merge=ours',
    },
  );

  await git.config(
    repository: environment.flutterDir,
    name: 'merge.ours.driver',
    value: Platform.isWindows ? 'rem' : 'true',
  );
}

Future<void> uninstallEnvShims({
  required Scope scope,
  required EnvConfig environment,
}) async {
  if ((await environment.readPrefs(scope: scope)).ohos) {
    await uninstallOhosEnvShims(scope: scope, environment: environment);
    return;
  }
  final log = PuroLogger.of(scope);
  final flutterConfig = environment.flutter;
  final git = GitClient.of(scope);

  log.d('uninstallEnvShims');

  for (var name in _binFiles) {
    name = name.replaceAll('/', path.context.separator);
    final file = flutterConfig.sdkDir.childFile(name);
    final bakFile = flutterConfig.sdkDir.childFile('$name.bak');
    if (file.existsSync()) {
      if (bakFile.existsSync()) {
        log.d('deleting $bakFile');
        bakFile.deleteSync();
      }
      log.d('renaming $file -> $bakFile');
      file.renameSync(bakFile.path);
    }
  }

  if (await git.tryGetCurrentCommitHash(repository: flutterConfig.sdkDir) !=
      null) {
    final assumeUnchanged = _binFiles.followedBy(_sharedScripts).toList();

    for (final fn in assumeUnchanged.toList()) {
      if (!await git.exists(repository: flutterConfig.sdkDir, path: fn)) {
        assumeUnchanged.remove(fn);
      }
    }

    log.d('assumeUnchanged: $assumeUnchanged');

    await git.assumeUnchanged(
      repository: flutterConfig.sdkDir,
      files: assumeUnchanged,
      value: false,
    );

    await updateGitAttributes(
      scope: scope,
      projectDir: flutterConfig.sdkDir,
      attributes: {},
    );
  }
}

const _ohosShimMarker = 'Puro OHOS native entry';

String _ohosShimPrefix(String name) {
  final command = name.startsWith('bin/dart') ? 'dart' : 'flutter';
  return name.endsWith('.bat')
      ? '@ECHO OFF\r\n'
        '@REM $_ohosShimMarker\r\n'
        '@FOR %%i IN ("%~dp0.") DO @SET "PURO_FLUTTER_BIN=%%~fi"\r\n'
        '@IF /I "%PURO_OHOS_NATIVE%"=="%PURO_FLUTTER_BIN%" GOTO puro_ohos_native\r\n'
        '@"%PURO_FLUTTER_BIN%\\..\\..\\..\\..\\bin\\puro" $command %*\r\n'
        '@EXIT /B %ERRORLEVEL%\r\n'
        ':puro_ohos_native\r\n'
      : '$bashShimHeader\n'
        '# $_ohosShimMarker\n'
        'if [[ "\${PURO_OHOS_NATIVE:-}" != "\${PROG_NAME%/*}" ]]; then\n'
        '  export PURO_FLUTTER_BIN="\${PROG_NAME%/*}"\n'
        '  exec "\$PURO_FLUTTER_BIN/../../../../bin/puro" $command "\$@"\n'
        'fi\n';
}

/// Keep the native launcher in the same file: shared.sh selects flutter/dart
/// from its basename, and the Windows launchers derive FLUTTER_ROOT from %~dp0.
Future<void> installOhosEnvShims({
  required Scope scope,
  required EnvConfig environment,
}) async {
  final git = GitClient.of(scope);
  final repository = environment.flutterDir;
  final scripts = <String>[];
  for (final name in _binFiles) {
    final original = await git.tryCat(repository: repository, path: name);
    if (original == null) continue;
    final prefix = _ohosShimPrefix(name);
    final file = repository.childFile(name);
    final content = file.existsSync() ? file.readAsStringSync() : utf8.decode(original);
    if (content.contains(_ohosShimMarker) && !content.startsWith(prefix)) {
      throw CommandError('OHOS launcher `$name` has a modified Puro shim; restore its Puro prefix before upgrading');
    }
    await writePassiveAtomic(
      scope: scope, file: file, content: content.startsWith(prefix) ? content : '$prefix$content',
    );
    if (!Platform.isWindows && !name.endsWith('.bat')) {
      await runProcess(scope, 'chmod', ['+x', file.path], throwOnFailure: true);
    }
    scripts.add(name);
  }
  await git.assumeUnchanged(repository: repository, files: scripts);
  await updateGitignore(
    scope: scope, projectDir: repository, ignores: {'bin/cache'},
  );
}

Future<void> uninstallOhosEnvShims({
  required Scope scope,
  required EnvConfig environment,
}) async {
  final git = GitClient.of(scope);
  final repository = environment.flutterDir;
  final scripts = <String>[];
  for (final name in _binFiles) {
    final original = await git.tryCat(repository: repository, path: name);
    if (original == null) continue;
    final file = repository.childFile(name);
    if (file.existsSync()) {
      final prefix = _ohosShimPrefix(name);
      final content = file.readAsStringSync();
      if (content.startsWith(prefix)) {
        // Keep edits to the native script so upgrade's dirty-tree check sees them.
        file.writeAsStringSync(content.substring(prefix.length));
      } else if (content.contains(_ohosShimMarker)) {
        throw CommandError('OHOS launcher `$name` has a modified Puro shim');
      }
    }
    scripts.add(name);
  }
  await git.assumeUnchanged(repository: repository, files: scripts, value: false);
}
