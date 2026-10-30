import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'git_capture.dart';

/// Runs Flutter with build revision metadata, preserving its terminal streams.
/// Non-build commands and help/version requests pass through without Git access.
Future<int> runFlutter(List<String> args) async {
  Directory? temporary;
  final signals = <StreamSubscription<ProcessSignal>>[];
  try {
    final forwarded = [...args];
    final separator = forwarded.indexOf('--');
    final toolArgs = separator < 0 ? args : args.take(separator);
    final needsGit =
        {'run', 'build', 'test'}.contains(_command(toolArgs.toList())) &&
        !toolArgs.contains('--help') &&
        !toolArgs.contains('-h');
    if (needsGit) {
      try {
        // Capture first so the generated file never affects the dirty flag.
        final info = await captureGitInfo();
        temporary = Directory.systemTemp.createTempSync('ume_git_');
        final file = File('${temporary.path}/git_info.json');
        file.writeAsStringSync(jsonEncode(info));
        forwarded.insert(
          separator < 0 ? forwarded.length : separator,
          '--dart-define-from-file=${file.path}',
        );
      } catch (error) {
        stderr.writeln(
          'UME: Git information unavailable; continuing without it: $error',
        );
      }
    }
    final process = await Process.start(
      _flutterExecutable(),
      forwarded,
      mode: ProcessStartMode.inheritStdio,
      runInShell: Platform.isWindows,
    );
    if (!Platform.isWindows) {
      for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
        signals.add(signal.watch().listen((event) => process.kill(event)));
      }
    }
    final result = await process.exitCode;
    return result < 0 ? 128 - result : result;
  } catch (error) {
    stderr.writeln('UME Flutter command failed: $error');
    return 1;
  } finally {
    for (final signal in signals) {
      await signal.cancel();
    }
    if (temporary != null && temporary.existsSync()) {
      cleanupGitDirectory(temporary);
    }
  }
}

// Global flags may precede the command. Skip values rather than mistaking a
// device or local-engine name for a Flutter command.
String? _command(List<String> args) {
  const valueOptions = {
    '-d',
    '--device-id',
    '--device-timeout',
    '--local-engine',
    '--local-engine-src-path',
    '--local-engine-host',
  };
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (valueOptions.contains(arg)) {
      i++;
    } else if (!arg.startsWith('-')) {
      return arg;
    }
  }
  return null;
}

String _flutterExecutable() {
  final explicit = Platform.environment['UME_FLUTTER_EXECUTABLE'];
  if (explicit != null && explicit.isNotEmpty) return explicit;
  // Prefer the SDK running this Dart command over a different SDK on PATH.
  final bin = File(Platform.resolvedExecutable).parent.parent.parent.parent;
  final flutter = File(
    '${bin.path}/${Platform.isWindows ? 'flutter.bat' : 'flutter'}',
  );
  if (File(
        '${bin.path}/cache/dart-sdk/bin/${Platform.isWindows ? 'dart.exe' : 'dart'}',
      ).existsSync() &&
      flutter.existsSync()) {
    return flutter.path;
  }
  return 'flutter';
}
