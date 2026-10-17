import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../command_result.dart';
import '../config.dart';
import '../downloader.dart';
import '../extensions.dart';
import '../git.dart';
import '../gitee_releases.dart';
import '../http.dart';
import '../logger.dart';
import '../process.dart';
import '../provider.dart';
import '../terminal.dart';
import '../version.dart';

void _validateBinaryTarget(Uint8List bytes, PuroBuildTarget target) {
  final data = ByteData.sublistView(bytes);
  final bool matches;
  switch (target) {
    case PuroBuildTarget.macosX64:
    case PuroBuildTarget.macosArm64:
      matches =
          bytes.length >= 8 &&
          data.getUint32(0, Endian.little) == 0xfeedfacf &&
          data.getUint32(4, Endian.little) == (target == PuroBuildTarget.macosArm64 ? 0x0100000c : 0x01000007);
    case PuroBuildTarget.windowsX64:
      final peOffset = bytes.length >= 64 ? data.getUint32(60, Endian.little) : -1;
      matches =
          peOffset >= 64 &&
          bytes.length >= peOffset + 6 &&
          data.getUint16(0, Endian.little) == 0x5a4d &&
          data.getUint32(peOffset, Endian.little) == 0x00004550 &&
          data.getUint16(peOffset + 4, Endian.little) == 0x8664;
    case PuroBuildTarget.linuxX64:
      matches =
          bytes.length >= 20 &&
          data.getUint32(0, Endian.big) == 0x7f454c46 &&
          bytes[4] == 2 &&
          bytes[5] == 1 &&
          data.getUint16(18, Endian.little) == 62;
  }
  if (!matches) throw CommandError('Downloaded Puro binary does not match ${target.name}.');
}

Future<int> upgradePuro({
  required Scope scope,
  required String targetVersion,
  required bool? path,
  PuroRelease? release,
}) async {
  final config = PuroConfig.of(scope);
  final terminal = Terminal.of(scope);
  final log = PuroLogger.of(scope);
  final buildTarget = config.buildTarget;
  final selectedRelease = release ?? await getPuroRelease(scope: scope, version: targetVersion);
  if (selectedRelease.assetName != puroReleaseAssetName(buildTarget)) {
    throw CommandError('Selected release asset does not match ${buildTarget.name}.');
  }
  config.binDir.createSync(recursive: true);
  final temporaryDirectory = config.binDir.createTempSync('.puro-upgrade-');
  final tempFile = temporaryDirectory.childFile(buildTarget.executableName);
  final checksumsFile = temporaryDirectory.childFile('SHA256SUMS');
  final backupFile = temporaryDirectory.childFile('${buildTarget.executableName}.previous');
  final processEnvironment = Map<String, String>.from(Platform.environment)
    ..remove('PURO_FLUTTER_BIN')
    ..['PURO_ROOT'] = config.puroRoot.path;
  var replacing = false;
  void restorePrevious() {
    if (!replacing) return;
    config.puroExecutableFile.deleteOrRenameSync();
    if (backupFile.existsSync()) backupFile.renameSync(config.puroExecutableFile.path);
    replacing = false;
  }

  try {
    await downloadFile(
      scope: scope,
      url: selectedRelease.binaryUrl,
      file: tempFile,
      description: 'Downloading Puro ${selectedRelease.tagName}',
    );
    await downloadFile(
      scope: scope,
      url: selectedRelease.checksumsUrl,
      file: checksumsFile,
      description: 'Downloading SHA256SUMS',
    );
    final expectedChecksum = puroReleaseChecksum(await checksumsFile.readAsString(), selectedRelease.assetName);
    final bytes = await tempFile.readAsBytes();
    final actualChecksum = sha256.convert(bytes).toString();
    if (expectedChecksum != selectedRelease.checksum || actualChecksum != expectedChecksum) {
      throw CommandError('SHA-256 verification failed for `${selectedRelease.assetName}`.');
    }
    _validateBinaryTarget(bytes, buildTarget);
    if (!Platform.isWindows) {
      await runProcess(scope, 'chmod', ['+x', tempFile.path], throwOnFailure: true);
    }
    final probe = await runProcessWithTimeout(
      scope,
      tempFile.path,
      ['--no-install', '--no-update-check', 'version', '--plain'],
      environment: processEnvironment,
      includeParentEnvironment: false,
      timeout: const Duration(seconds: 30),
    );
    final actualVersion = probe == null ? null : tryParseVersion((probe.stdout as String).trim());
    if (probe == null ||
        probe.exitCode != 0 ||
        actualVersion == null ||
        actualVersion == unknownSemver ||
        (selectedRelease.version != null && selectedRelease.version != actualVersion)) {
      throw CommandError('Downloaded Puro version verification failed for `${selectedRelease.tagName}`.');
    }
    if (config.puroExecutableFile.existsSync()) config.puroExecutableFile.renameSync(backupFile.path);
    replacing = true;
    tempFile.renameSync(config.puroExecutableFile.path);
    terminal.flushStatus();
    final installProcess = await startProcess(
      scope,
      config.puroExecutableFile.path,
      [
        if (terminal.enableColor) '--color',
        if (terminal.enableStatus) '--progress',
        '--log-level=${log.level?.index ?? 0}',
        'install-puro',
        if (path != null)
          if (path) '--path' else '--no-path',
      ],
      environment: processEnvironment,
      includeParentEnvironment: false,
    );
    final stdoutFuture = installProcess.stdout.listen(stdout.add).asFuture<void>();
    await installProcess.stderr.listen(stderr.add).asFuture<void>();
    await stdoutFuture;
    final exitCode = await installProcess.exitCode;
    if (exitCode != 0) restorePrevious();
    replacing = false;
    return exitCode;
  } catch (_) {
    restorePrevious();
    rethrow;
  } finally {
    try {
      temporaryDirectory.deleteSync(recursive: true);
    } catch (exception) {
      log.v('Puro upgrade temporary files remain at ${temporaryDirectory.path}: $exception');
    }
  }
}
