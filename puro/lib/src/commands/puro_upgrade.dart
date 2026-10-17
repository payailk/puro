import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

import '../command.dart';
import '../command_result.dart';
import '../config.dart';
import '../gitee_releases.dart';
import '../http.dart';
import '../install/upgrade.dart';
import '../process.dart';
import '../terminal.dart';
import '../version.dart';

class PuroUpgradeCommand extends PuroCommand {
  PuroUpgradeCommand() {
    argParser.addFlag(
      'force',
      hide: true,
      help: 'Installs a new puro executable even if it wont replace an existing one',
      negatable: false,
    );
    argParser.addFlag('path', help: 'Whether or not to update the PATH automatically');
  }

  @override
  final name = 'upgrade-puro';

  @override
  List<String> get aliases => ['update-puro'];

  @override
  String? get argumentUsage => '[version]';

  @override
  final description = 'Upgrades the puro tool to a new version';

  @override
  bool get allowUpdateCheck => false;

  @override
  Future<CommandResult> run() async {
    final force = argResults!['force'] as bool;
    final config = PuroConfig.of(scope);
    final puroVersion = await PuroVersion.of(scope);
    final currentVersion = puroVersion.semver;
    var targetVersionString = unwrapSingleOptionalArgument();

    if (puroVersion.type == PuroInstallationType.pub) {
      final result = await runProcess(scope, Platform.resolvedExecutable, ['pub', 'global', 'activate', 'puro']);
      if (result.exitCode == 0) {
        final stdout = result.stdout as String;
        if (stdout.contains('already activated at newest available version')) {
          return BasicMessageResult('Puro is up to date with $currentVersion');
        } else {
          return BasicMessageResult('Upgraded puro to latest pub version');
        }
      } else {
        return BasicMessageResult(
          '`dart pub global activate puro` failed with exit code ${result.exitCode}\n${result.stderr}'.trim(),
          success: false,
        );
      }
    } else if (puroVersion.type != PuroInstallationType.distribution && !force) {
      return BasicMessageResult("Can't upgrade: ${puroVersion.type.description}", success: false);
    }

    if (targetVersionString == 'master') {
      final exitCode = await upgradePuro(
        scope: scope,
        targetVersion: 'master',
        path: argResults!.wasParsed('path') ? argResults!['path'] as bool : null,
      );
      await runner.exitPuro(exitCode);
    }

    final Version targetVersion;
    final PuroRelease selectedRelease;
    if (targetVersionString == null) {
      final release = await findLatestPuroRelease(scope: scope);
      if (release == null) {
        throw CommandError(
          'Publish a Gitee release with ${puroReleaseAssetName(config.buildTarget)} and SHA256SUMS before upgrading.',
        );
      }
      selectedRelease = release;
      targetVersion = selectedRelease.version!;
      if (currentVersion == targetVersion && !force) {
        return BasicMessageResult('Puro is up to date with $targetVersion');
      } else if (currentVersion > targetVersion && !force) {
        return BasicMessageResult(
          'Puro is a newer version $currentVersion than the available $targetVersion',
          type: CompletionType.indeterminate,
        );
      }
    } else {
      final version = tryParseVersion(targetVersionString);
      if (version == null) throw CommandError('Expected a Puro version or `master`, got `$targetVersionString`.');
      targetVersion = version;
      if (currentVersion == targetVersion && !force) {
        return BasicMessageResult('Puro is the desired version $targetVersion');
      }
      selectedRelease = await getPuroRelease(scope: scope, version: '$targetVersion');
    }

    final exitCode = await upgradePuro(
      scope: scope,
      targetVersion: '$targetVersion',
      release: selectedRelease,
      path: argResults!.wasParsed('path') ? argResults!['path'] as bool : null,
    );

    await runner.exitPuro(exitCode);
  }
}
