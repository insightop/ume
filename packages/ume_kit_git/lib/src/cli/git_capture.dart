import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Reads the host checkout with a shared time budget for all Git commands.
Future<Map<String, String>> captureGitInfo({
  String? workingDirectory,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final watch = Stopwatch()..start();
  Future<String> git(List<String> args) async {
    final remaining = timeout - watch.elapsed;
    if (remaining <= Duration.zero)
      throw TimeoutException('Git capture timed out');
    final process = await Process.start(
      'git',
      args,
      workingDirectory: workingDirectory,
    );
    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .listen(stdoutBuffer.write);
    final stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .listen(stderrBuffer.write);
    final result = Future.wait<Object?>([
      process.exitCode,
      stdoutSubscription.asFuture<void>(),
      stderrSubscription.asFuture<void>(),
    ]);
    try {
      final values = await result.timeout(remaining);
      if (values[0] != 0) {
        throw ProcessException(
          'git',
          args,
          stderrBuffer.toString(),
          values[0] as int,
        );
      }
      return stdoutBuffer.toString();
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      throw TimeoutException('Git capture timed out after $timeout');
    } finally {
      // Close pipe readers even if a descendant still holds the write ends.
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
    }
  }

  // Fetch all current-commit fields together, then pin history to this revision.
  final current = (await git([
    'log',
    '-1',
    '--format=%H%x00%an%x00%cI%x00%B',
  ])).trimRight().split('\u0000');
  if (current.length != 4)
    throw const FormatException('Invalid Git commit data');
  final commit = current[0];
  final branch = (await git(['rev-parse', '--abbrev-ref', 'HEAD'])).trim();
  final dirty = (await git(['status', '--porcelain'])).isNotEmpty;
  final recent = <Map<String, String>>[];
  try {
    final fields = (await git([
      'log',
      '-5',
      '--skip=1',
      '-z',
      '--format=%H%x00%h%x00%an%x00%cI%x00%s',
      commit,
    ])).split('\u0000');
    if (fields.last.isEmpty) fields.removeLast();
    for (var i = 0; i + 4 < fields.length; i += 5) {
      recent.add({
        'hash': fields[i],
        'shortHash': fields[i + 1],
        'author': fields[i + 2],
        'time': fields[i + 3],
        'subject': fields[i + 4],
      });
    }
  } catch (error) {
    stderr.writeln(
      'UME: Recent Git commits unavailable; keeping build revision: $error',
    );
  }
  return {
    'UME_GIT_COMMIT': commit,
    'UME_GIT_BRANCH': branch == 'HEAD' ? 'Detached HEAD' : branch,
    'UME_GIT_AUTHOR': current[1],
    'UME_GIT_TIME': current[2],
    'UME_GIT_MESSAGE_BASE64': base64Encode(utf8.encode(current[3])),
    'UME_GIT_RECENT_COMMITS_BASE64': base64Encode(
      utf8.encode(jsonEncode(recent)),
    ),
    'UME_GIT_DIRTY': dirty.toString(),
  };
}

/// Refresh the IDE file atomically so readers never see partially written JSON.
Future<int> generateGitInfo(List<String> args) async {
  if (args.length > 1) {
    stderr.writeln('Usage: dart run ume:git_info [output.json]');
    return 64;
  }
  final output = File(
    args.isEmpty ? '.dart_tool/ume_git_info.json' : args.single,
  );
  Map<String, String> info;
  try {
    info = await captureGitInfo();
  } catch (error) {
    info = {};
    stderr.writeln(
      'UME: Git information unavailable; continuing without it: $error',
    );
  }
  Directory? temporary;
  try {
    output.parent.createSync(recursive: true);
    temporary = output.parent.createTempSync('.ume_git_');
    final staged = File('${temporary.path}/git_info.json');
    staged.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(info)}\n',
      flush: true,
    );
    staged.renameSync(output.path);
    stdout.writeln('UME Git info written to ${output.path}');
    return 0;
  } on FileSystemException catch (error) {
    stderr.writeln('Failed to write UME Git info file: $error');
    // Invalidate stale data where possible, without masking the original error.
    try {
      if (output.existsSync()) output.deleteSync();
    } on FileSystemException catch (cleanupError) {
      stderr.writeln('UME: Could not remove stale Git info: $cleanupError');
    }
    return 1;
  } finally {
    if (temporary != null) cleanupGitDirectory(temporary);
  }
}

/// Cleanup must not replace Flutter's exit code or the original write error.
void cleanupGitDirectory(Directory directory) {
  try {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  } on FileSystemException catch (error) {
    stderr.writeln('UME: Could not clean temporary Git info: $error');
  }
}
