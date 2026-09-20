import 'dart:convert';

import 'package:file/file.dart';

import '../command_result.dart';
import '../config.dart';
import '../file_lock.dart';
import '../git.dart';
import '../logger.dart';
import '../provider.dart';
import 'create.dart';
import 'default.dart';
import 'env_shims.dart';
import 'flutter_tool.dart';
import 'upgrade.dart';
import 'version.dart';

Future<void> _git(Scope scope, Directory repository, List<String> args) async {
  final result = await GitClient.of(scope).raw(args, directory: repository);
  if (result.exitCode != 0) {
    throw CommandError('git ${args.first} failed: ${result.stderr}');
  }
}

/// Resolve only refs from the OHOS origin, never the official release index.
Future<FlutterVersion> resolveOhosVersion({
  required Scope scope,
  required Directory repository,
  required String ref,
}) async {
  final git = GitClient.of(scope);
  for (final candidate in [
    (ref: 'refs/remotes/origin/$ref', branch: ref, tag: null),
    (ref: 'refs/tags/$ref', branch: null, tag: ref),
    if (RegExp(r'^[0-9a-fA-F]{7,40}$').hasMatch(ref))
      (ref: ref, branch: null, tag: null),
  ]) {
    final result = await git.raw([
      'rev-parse', '--verify', '--end-of-options', '${candidate.ref}^{commit}',
    ], directory: repository);
    if (result.exitCode == 0) {
      return FlutterVersion(
        commit: (result.stdout as String).trim(),
        branch: candidate.branch,
        tag: candidate.tag,
      );
    }
  }
  throw CommandError('Could not find OHOS branch, tag or commit `$ref`');
}

Future<void> _checkoutOhosVersion({
  required Scope scope,
  required EnvConfig environment,
  required FlutterVersion version,
  required bool force,
}) async {
  final repository = environment.flutterDir;
  // --no-overwrite-ignore prevents a ref switch from deleting ignored local files.
  await _git(scope, repository, [
    'checkout', '--no-overwrite-ignore',
    if (force) '--force',
    if (version.branch != null) ...['-B', version.branch!] else '--detach',
    version.commit,
  ]);
  if (version.branch != null) {
    await GitClient.of(scope).branch(
      repository: repository,
      branch: version.branch!,
      setUpstream: 'origin/${version.branch}',
    );
  }
}

Future<EnvCreateResult> createOhosEnvironment({
  required Scope scope,
  required String envName,
  String ref = defaultOhosFlutterRef,
}) async {
  ensureValidEnvName(envName);
  if (isPseudoEnvName(envName) || isValidVersion(envName)) {
    throw CommandError('OHOS environments require a custom name, such as `harmony`');
  }
  final config = PuroConfig.of(scope);
  final git = GitClient.of(scope);
  final environment = config.getEnv(envName);
  environment.envDir.createSync(recursive: true);
  await lockFile(scope, environment.updateLockFile, (_) async {
    if (await git.tryGetCurrentCommitHash(repository: environment.flutterDir) != null) {
      throw CommandError('Environment `$envName` already exists; use `puro upgrade $envName`');
    }
    final prefs = await environment.readPrefs(scope: scope);
    if (prefs.hasDesiredVersion() && !prefs.ohos) {
      throw CommandError('Environment `$envName` is not an OHOS environment');
    }
    await environment.updatePrefs(scope: scope, fn: (prefs) {
      prefs.ohos = true;
      prefs.forkRemoteUrl = config.ohosFlutterGitUrl;
    });

    config.sharedDir.createSync(recursive: true);
    await lockFile(scope, config.sharedOhosFlutterLock, (_) async {
      await fetchOrCloneShared(
        scope: scope,
        repository: config.sharedOhosFlutterDir,
        remoteUrl: config.ohosFlutterGitUrl,
      );
      final version = await resolveOhosVersion(
        scope: scope, repository: config.sharedOhosFlutterDir, ref: ref,
      );
      final repository = environment.flutterDir;
      repository.createSync(recursive: true);
      if (!repository.childDirectory('.git').existsSync()) {
        await git.init(repository: repository);
      }
      final alternates = repository.childFile('.git/objects/info/alternates');
      alternates.parent.createSync(recursive: true);
      alternates.writeAsStringSync('${config.sharedOhosFlutterDir.path}/.git/objects\n');
      await git.syncRemotes(repository: repository, remotes: {
        'origin': GitRemoteUrls.single(config.ohosFlutterGitUrl),
      });
      await git.fetch(repository: repository);
      await _checkoutOhosVersion(
        scope: scope, environment: environment, version: version, force: false,
      );
      await environment.updatePrefs(scope: scope, fn: (prefs) {
        prefs.desiredVersion = version.toModel();
      });
    }, mode: FileMode.append, exclusive: true);
    await installEnvShims(scope: scope, environment: environment);
  }, mode: FileMode.append, exclusive: true);
  await updateDefaultEnvSymlink(scope: scope);
  await setUpFlutterTool(scope: scope, environment: environment);
  return EnvCreateResult(success: true, environment: environment);
}

Future<EnvUpgradeResult> upgradeOhosEnvironment({
  required Scope scope,
  required EnvConfig environment,
  String? ref,
  bool force = false,
}) async {
  environment.ensureExists();
  final git = GitClient.of(scope);
  final repository = environment.flutterDir;
  final versions = await lockFile(scope, environment.updateLockFile, (_) async {
    final prefs = await environment.readPrefs(scope: scope);
    if (!prefs.ohos) throw CommandError('`${environment.name}` is not an OHOS environment');
    final currentCommit = await git.getCurrentCommitHash(repository: repository);
    final currentBranch = await git.getBranch(repository: repository);
    final from = FlutterVersion(commit: currentCommit, branch: currentBranch);
    final String targetRef;
    if (ref != null) {
      targetRef = ref;
    } else if (prefs.hasDesiredVersion()) {
      final desired = prefs.desiredVersion;
      targetRef = desired.hasBranch() ? desired.branch : desired.commit;
    } else {
      targetRef = currentBranch ?? currentCommit;
    }
    await git.syncRemotes(repository: repository, remotes: {
      'origin': GitRemoteUrls.single(prefs.hasForkRemoteUrl()
          ? prefs.forkRemoteUrl : PuroConfig.of(scope).ohosFlutterGitUrl),
    });
    // Pinned tags/commits remain usable offline when no new ref is requested.
    if (ref != null || prefs.desiredVersion.hasBranch() || !prefs.hasDesiredVersion()) {
      await git.fetch(repository: repository);
    }
    final to = ref == null && prefs.hasDesiredVersion() && !prefs.desiredVersion.hasBranch()
        ? FlutterVersion.fromModel(prefs.desiredVersion)
        : await resolveOhosVersion(scope: scope, repository: repository, ref: targetRef);

    if (force || currentCommit != to.commit || currentBranch != to.branch) {
      await uninstallEnvShims(scope: scope, environment: environment);
      try {
        final status = await git.raw(['status', '--porcelain', '--untracked-files=no'], directory: repository);
        if (status.exitCode != 0 || (!force && (status.stdout as String).isNotEmpty)) {
          throw CommandError('Environment has local changes; commit them or pass --force');
        }
        if (!force) {
          final savedCommit = prefs.hasDesiredVersion() ? prefs.desiredVersion.commit : currentCommit;
          final ancestor = await git.raw(['merge-base', '--is-ancestor', currentCommit, to.commit], directory: repository);
          if (currentCommit != savedCommit && ancestor.exitCode != 0) {
            throw CommandError('Environment has local commits; pass --force to discard them');
          }
        }
        await _checkoutOhosVersion(
          scope: scope, environment: environment, version: to, force: force,
        );
        // The SDK's own stamps handle ordinary updates. Clearing on a ref change
        // also covers OHOS artifact versions that differ from the upstream engine.
        clearOhosCache(environment);
        await environment.updatePrefs(scope: scope, fn: (prefs) {
          prefs.desiredVersion = to.toModel();
          prefs.clearOhosCacheSource();
        });
      } finally {
        await installEnvShims(scope: scope, environment: environment);
      }
    } else {
      // Also repairs an interrupted initialization without moving the checkout.
      await installEnvShims(scope: scope, environment: environment);
      await environment.updatePrefs(scope: scope, fn: (prefs) {
        prefs.desiredVersion = to.toModel();
      });
    }
    return (from: from, to: to, remote: prefs.forkRemoteUrl);
  }, mode: FileMode.append, exclusive: true);
  final toolInfo = await setUpFlutterTool(scope: scope, environment: environment);
  return EnvUpgradeResult(
    environment: environment,
    from: versions.from,
    to: versions.to,
    forkRemoteUrl: versions.remote,
    switchedBranch: versions.from.branch != versions.to.branch,
    toolInfo: toolInfo,
  );
}

/// Unlink symlinks without following them into another environment's cache.
void clearOhosCache(EnvConfig environment) {
  final cache = environment.flutter.cacheDir;
  final fs = cache.fileSystem;
  if (fs.isLinkSync(cache.path)) {
    fs.link(cache.path).deleteSync();
  } else if (cache.existsSync()) {
    cache.deleteSync(recursive: true);
  }
}

bool _cacheIsLocal(EnvConfig environment) {
  final cache = environment.flutter.cacheDir;
  if (cache.fileSystem.isLinkSync(cache.path)) return false;
  if (!cache.existsSync()) return true;
  // Official Puro caches link individual top-level entries, not just bin/cache.
  return !cache.listSync(followLinks: false).any((entry) => entry is Link);
}

/// Hold a shared environment lock while running native tools. Cache invalidation
/// takes an exclusive lock, so changing mirrors cannot delete an active cache.
Future<T> withOhosCache<T>({
  required Scope scope,
  required EnvConfig environment,
  required Future<T> Function() fn,
}) async {
  final config = PuroConfig.of(scope);
  final source = jsonEncode({
    'flutterStorageBaseUrl': config.flutterStorageBaseUrl.toString(),
    'ohosFlutterStorageBaseUrl': config.ohosFlutterStorageBaseUrl,
  });
  while (true) {
    final result = await lockFile(scope, environment.updateLockFile, (_) async {
      final prefs = await environment.readPrefs(scope: scope);
      if (!prefs.ohos) throw CommandError('`${environment.name}` is not an OHOS environment');
      if (prefs.ohosCacheSource != source || !_cacheIsLocal(environment)) {
        return (ready: false, value: null as T?);
      }
      return (ready: true, value: await fn());
    }, exclusive: false);
    if (result.ready) return result.value as T;
    await lockFile(scope, environment.updateLockFile, (_) async {
      final prefs = await environment.readPrefs(scope: scope);
      if (prefs.ohosCacheSource != source || !_cacheIsLocal(environment)) {
        PuroLogger.of(scope).v('Preparing independent OHOS cache using $source');
        clearOhosCache(environment);
        environment.flutter.cacheDir.createSync(recursive: true);
        await environment.updatePrefs(scope: scope, fn: (prefs) {
          prefs.ohosCacheSource = source;
        });
      }
    }, mode: FileMode.append, exclusive: true);
  }
}

Map<String, String> ohosProcessEnvironment(PuroConfig config, EnvConfig environment) {
  return {
    'FLUTTER_ROOT': environment.flutterDir.path,
    // Modern OHOS SDKs still fetch upstream metadata and common artifacts.
    'FLUTTER_STORAGE_BASE_URL': config.flutterStorageBaseUrl.toString(),
    'FLUTTER_OHOS_STORAGE_BASE_URL': config.ohosFlutterStorageBaseUrl,
    'PUB_CACHE': config.legacyPubCacheDir.path,
    'PURO_OHOS_NATIVE': environment.flutter.binDir.resolveSymbolicLinksSync(),
  };
}
