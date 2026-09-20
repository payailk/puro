import '../command.dart';
import '../command_result.dart';
import '../config.dart';
import '../terminal.dart';

const _mirrorKeys = {'flutterGitUrl', 'engineGitUrl', 'dartSdkGitUrl', 'flutterStorageBaseUrl', 'releasesJsonUrl', 'ohosFlutterGitUrl', 'ohosFlutterStorageBaseUrl'};

class ConfigCommand extends PuroCommand {
  ConfigCommand() {
    for (final action in ['set', 'get', 'unset', 'list']) {
      addSubcommand(_ConfigActionCommand(action));
    }
  }

  @override
  final name = 'config';

  @override
  final description = 'Manages persistent mirror configuration';
}

class _ConfigActionCommand extends PuroCommand {
  _ConfigActionCommand(this.name);

  @override
  final String name;

  @override
  bool get allowUpdateCheck => false;

  @override
  String get description => switch (name) {
    'set' => 'Saves a mirror URL',
    'get' => 'Shows the saved and effective URL',
    'unset' => 'Removes a saved override',
    _ => 'Lists saved and effective mirror URLs',
  };

  @override
  String? get argumentUsage => switch (name) {
    'set' => '<key> <url>',
    'list' => null,
    _ => '<key>',
  };

  @override
  Future<CommandResult> run() async {
    final count = name == 'list' ? 0 : (name == 'set' ? 2 : 1);
    final args = unwrapArguments(atLeast: count, atMost: count);
    final config = PuroConfig.of(scope);
    final vars = PuroInternalPrefsVars(scope: scope, config: config);
    final key = args.isEmpty ? null : args.first;
    if (key != null && !_mirrorKeys.contains(key)) {
      throw CommandError('Unknown mirror key `$key`. Available keys: ${_mirrorKeys.join(', ')}');
    }
    if (name == 'set') {
      final value = args[1].trim();
      final uri = Uri.tryParse(value);
      final isGit = key!.endsWith('GitUrl');
      final isScp = isGit && RegExp(r'^[\w.-]+@[\w.-]+:[^\s]+$').hasMatch(value);
      final isUrl =
          uri != null &&
          uri.host.isNotEmpty &&
          (uri.scheme == 'https' || uri.scheme == 'http' || (isGit && uri.scheme == 'ssh'));
      if (value.contains(RegExp(r'\s')) || (!isScp && !isUrl)) {
        throw CommandError('Invalid URL for `$key`. Use HTTP(S)${isGit ? ' or SSH' : ''}.');
      }
      await vars.writeVar(key, value);
      return BasicMessageResult('Saved $key = $value. Applies to subsequent commands.');
    }
    if (name == 'unset') {
      await vars.writeVar(key!, 'null');
      return BasicMessageResult('Removed $key override. Applies to subsequent commands.');
    }
    final effective = {
      'flutterGitUrl': config.flutterGitUrl,
      'engineGitUrl': config.engineGitUrl,
      'dartSdkGitUrl': config.dartSdkGitUrl,
      'flutterStorageBaseUrl': config.flutterStorageBaseUrl.toString(),
      'releasesJsonUrl': config.releasesJsonUrl.toString(),
      'ohosFlutterGitUrl': config.ohosFlutterGitUrl,
      'ohosFlutterStorageBaseUrl': config.ohosFlutterStorageBaseUrl,
    };
    final values = <String, dynamic>{};
    for (final selected in key == null ? _mirrorKeys : [key]) {
      values[selected] = {'saved': await vars.readVar(selected), 'effective': effective[selected]};
    }
    return BasicMessageResult(prettyJsonEncoder.convert(values), type: CompletionType.info);
  }
}
