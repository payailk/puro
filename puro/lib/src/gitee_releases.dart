import 'dart:convert';

import 'package:pub_semver/pub_semver.dart';

import 'command_result.dart';
import 'config.dart';
import 'http.dart';
import 'provider.dart';
import 'version.dart';

class PuroRelease {
  PuroRelease({
    required this.tagName,
    required this.version,
    required this.assetName,
    required this.binaryUrl,
    required this.checksumsUrl,
    required this.checksum,
    required this.assets,
  });

  final String tagName;
  final Version? version;
  final String assetName;
  final Uri binaryUrl;
  final Uri checksumsUrl;
  final String checksum;
  final Map<String, Uri> assets;
}

String puroReleaseAssetName(PuroBuildTarget target) => 'puro-${target.name}${target.exeSuffix}';

String puroReleaseChecksum(String contents, String assetName) {
  final checksums = <String>[];
  final pattern = RegExp(r'^([a-fA-F0-9]{64})[ \t]+\*?(.+?)\s*$');
  for (final line in const LineSplitter().convert(contents)) {
    final match = pattern.firstMatch(line);
    if (match != null && match.group(2) == assetName) {
      checksums.add(match.group(1)!.toLowerCase());
    }
  }
  if (checksums.length != 1) {
    throw CommandError('SHA256SUMS must contain exactly one checksum for `$assetName`.');
  }
  return checksums.single;
}

Uri _releaseUri(PuroConfig config, {String? tag, int? page}) {
  final base = config.puroBuildsUrl;
  return base.replace(
    pathSegments: [
      ...base.pathSegments.where((segment) => segment.isNotEmpty),
      if (tag != null) ...['tags', tag],
    ],
    queryParameters: {...base.queryParameters, if (page != null) 'page': '$page', if (page != null) 'per_page': '100'},
  );
}

class _ReleaseMetadata {
  _ReleaseMetadata(this.tagName, this.version, this.assets);

  final String tagName;
  final Version? version;
  final Map<String, Uri> assets;

  static _ReleaseMetadata? fromJson(dynamic value) {
    if (value is! Map<String, dynamic> || value['draft'] == true) return null;
    final tag = value['tag_name'];
    if (tag is! String || tag.isEmpty) return null;
    final version = tryParseVersion(tag);
    if (tag != 'master' && version == null) return null;
    final assetValues = value['assets'];
    if (assetValues is! List) return null;
    final assets = <String, Uri>{};
    for (final asset in assetValues) {
      if (asset is! Map<String, dynamic>) continue;
      final name = asset['name'];
      final url = asset['browser_download_url'];
      if (name is! String || name.isEmpty || url is! String) continue;
      final uri = Uri.tryParse(url);
      if (uri == null || uri.host.isEmpty || !const ['https', 'http'].contains(uri.scheme)) continue;
      if (assets.containsKey(name)) {
        throw CommandError('Gitee release `$tag` contains duplicate asset `$name`.');
      }
      assets[name] = uri;
    }
    return _ReleaseMetadata(tag, version, assets);
  }

  bool supports(PuroBuildTarget target) =>
      assets.containsKey(puroReleaseAssetName(target)) && assets.containsKey('SHA256SUMS');
}

Future<PuroRelease> _resolveRelease({required Scope scope, required _ReleaseMetadata metadata}) async {
  final target = PuroConfig.of(scope).buildTarget;
  final assetName = puroReleaseAssetName(target);
  if (!metadata.supports(target)) {
    throw CommandError('Gitee release `${metadata.tagName}` needs `$assetName` and `SHA256SUMS` for ${target.name}.');
  }
  final checksumsUrl = metadata.assets['SHA256SUMS']!;
  final response = await scope.read(clientProvider).get(checksumsUrl);
  HttpException.ensureSuccess(response);
  return PuroRelease(
    tagName: metadata.tagName,
    version: metadata.version,
    assetName: assetName,
    binaryUrl: metadata.assets[assetName]!,
    checksumsUrl: checksumsUrl,
    checksum: puroReleaseChecksum(response.body, assetName),
    assets: Map.unmodifiable(metadata.assets),
  );
}

Future<PuroRelease?> findLatestPuroRelease({required Scope scope}) async {
  final config = PuroConfig.of(scope);
  final client = scope.read(clientProvider);
  final candidates = <_ReleaseMetadata>[];
  for (var page = 1; ; page++) {
    final response = await client.get(_releaseUri(config, page: page));
    HttpException.ensureSuccess(response);
    final values = jsonDecode(response.body);
    if (values is! List) throw CommandError('Expected a Gitee releases list from `${config.puroBuildsUrl}`.');
    for (final value in values) {
      if (value is Map<String, dynamic> && value['prerelease'] == true) continue;
      final metadata = _ReleaseMetadata.fromJson(value);
      if (metadata != null && metadata.version != null && metadata.supports(config.buildTarget))
        candidates.add(metadata);
    }
    if (values.length < 100) break;
  }
  candidates.sort((left, right) => right.version!.compareTo(left.version!));
  for (final candidate in candidates) {
    try {
      return await _resolveRelease(scope: scope, metadata: candidate);
    } on CommandError {
      continue;
    } on HttpException {
      continue;
    }
  }
  return null;
}

Future<PuroRelease> getPuroRelease({required Scope scope, required String version}) async {
  final parsedVersion = version == 'master' ? null : tryParseVersion(version);
  if (version != 'master' && parsedVersion == null)
    throw CommandError('Expected a Puro version or `master`, got `$version`.');
  final tag = version == 'master' ? 'master' : 'v$parsedVersion';
  final uri = _releaseUri(PuroConfig.of(scope), tag: tag);
  final response = await scope.read(clientProvider).get(uri);
  if (response.statusCode == 404) {
    throw CommandError('Publish Gitee release `$tag` with this platform binary and SHA256SUMS before upgrading.');
  }
  HttpException.ensureSuccess(response);
  final metadata = _ReleaseMetadata.fromJson(jsonDecode(response.body));
  if (metadata == null || metadata.tagName != tag || metadata.version != parsedVersion) {
    throw CommandError('Gitee returned a different release than the requested `$tag`.');
  }
  return _resolveRelease(scope: scope, metadata: metadata);
}
