import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ume_kit_git/cli.dart';

void main() {
  late Directory root;
  late File launcher;
  late String dartExecutable;
  late Map<String, String> environment;

  void git(List<String> args) {
    final result = Process.runSync('git', args, workingDirectory: root.path);
    expect(result.exitCode, 0, reason: result.stderr.toString());
  }

  Future<ProcessResult> run(List<String> args, {int code = 0}) => Process.run(
    dartExecutable,
    [launcher.path, ...args],
    workingDirectory: root.path,
    environment: {...environment, 'UME_TEST_EXIT_CODE': '$code'},
  );

  void initGit() {
    git(['init', '-q']);
    git(['config', 'user.name', '测试作者']);
    git(['config', 'user.email', 'test@example.test']);
    git(['add', '.']);
    git(['commit', '-qm', '测试 "commit"\n\n多行说明']);
  }

  setUp(() async {
    // flutter_test runs in flutter_tester; launch the actual Dart VM directly
    // so the Flutter shell wrapper cannot run Git before our timeout starts.
    var sdkDirectory = File(Platform.resolvedExecutable).parent;
    while (!File('${sdkDirectory.path}/dart-sdk/bin/dart').existsSync()) {
      if (sdkDirectory.parent.path == sdkDirectory.path) {
        throw StateError('Cannot locate Flutter cached Dart SDK');
      }
      sdkDirectory = sdkDirectory.parent;
    }
    dartExecutable = '${sdkDirectory.path}/dart-sdk/bin/dart';
    root = Directory.systemTemp.createTempSync('ume_cli_test_');
    var directory = Directory.current;
    while (!File(
      '${directory.path}/.dart_tool/package_config.json',
    ).existsSync()) {
      if (directory.parent.path == directory.path) {
        throw StateError('Cannot locate workspace package configuration');
      }
      directory = directory.parent;
    }
    final config = File('${directory.path}/.dart_tool/package_config.json');
    final packages = jsonDecode(config.readAsStringSync())['packages'] as List;
    final package = packages.firstWhere((p) => p['name'] == 'ume_kit_git');
    final cli = config.uri
        .resolve('${package['rootUri']}/')
        .resolve('lib/cli.dart');
    launcher = File('${root.path}/launcher.dart')
      ..writeAsStringSync('''
import 'dart:io';
import '$cli';
Future<void> main(List<String> args) async {
  exitCode = args.firstOrNull == 'generate'
      ? await generateGitInfo(args.skip(1).toList())
      : await runFlutter(args);
}
''');
    final bin = Directory('${root.path}/bin')..createSync();
    final flutter = File('${bin.path}/flutter')
      ..writeAsStringSync(r'''#!/bin/sh
printf '%s\n' "$@" > "$UME_TEST_ROOT/args.txt"
for arg do
  case "$arg" in
    --dart-define-from-file=*)
      file="${arg#*=}"
      printf '%s' "$file" > "$UME_TEST_ROOT/metadata_path.txt"
      cp "$file" "$UME_TEST_ROOT/metadata.json"
      ;;
  esac
done
printf 'flutter stdout\n'
printf 'flutter stderr\n' >&2
if [ "${UME_TEST_WAIT:-0}" = 1 ]; then
  trap 'exit 23' TERM
  : > "$UME_TEST_ROOT/ready"
  while :; do sleep 1; done
fi
exit "${UME_TEST_EXIT_CODE:-0}"
''');
    Process.runSync('chmod', ['+x', flutter.path]);
    environment = {
      'PATH': '${bin.path}:${Platform.environment['PATH']}',
      'UME_TEST_ROOT': root.path,
      'UME_FLUTTER_EXECUTABLE': flutter.path,
    };
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'injects host HEAD, preserves arguments/streams/exit code, cleans temporary file',
    () async {
      initGit();
      final result = await run([
        'build',
        'apk',
        '--release',
        '--dart-define=APP=hello world',
      ], code: 7);
      expect(result.exitCode, 7, reason: result.stderr.toString());
      expect(result.stdout, contains('flutter stdout'));
      expect(result.stderr, contains('flutter stderr'));
      final args = File('${root.path}/args.txt').readAsLinesSync();
      expect(args.take(4), [
        'build',
        'apk',
        '--release',
        '--dart-define=APP=hello world',
      ]);
      final info = jsonDecode(
        File('${root.path}/metadata.json').readAsStringSync(),
      );
      expect(
        info['UME_GIT_COMMIT'],
        (await captureGitInfo(workingDirectory: root.path))['UME_GIT_COMMIT'],
      );
      expect(info['UME_GIT_DIRTY'], 'false');
      expect(info['UME_GIT_AUTHOR'], '测试作者');
      final history = jsonDecode(
        utf8.decode(base64Decode(info['UME_GIT_RECENT_COMMITS_BASE64'])),
      );
      expect(history, isEmpty);

      expect(
        utf8.decode(base64Decode(info['UME_GIT_MESSAGE_BASE64'])),
        '测试 "commit"\n\n多行说明',
      );
      final metadata = File(
        '${root.path}/metadata_path.txt',
      ).readAsStringSync();
      expect(File(metadata).existsSync(), isFalse);
      expect(File(metadata).parent.existsSync(), isFalse);
    },
    skip: Platform.isWindows,
  );

  test('non-build and help commands pass through outside Git', () async {
    for (final args in [
      ['--version'],
      ['run', '--help'],
      ['doctor'],
    ]) {
      final result = await run(args);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(File('${root.path}/args.txt').readAsLinesSync(), args);
      expect(File('${root.path}/metadata.json').existsSync(), isFalse);
    }
  }, skip: Platform.isWindows);

  test(
    'continues without metadata when Git capture fails and preserves Flutter exit code',
    () async {
      final result = await run(['run'], code: 7);
      expect(result.exitCode, 7, reason: result.stderr.toString());
      expect(result.stderr, contains('continuing without it'));
      expect(File('${root.path}/args.txt').readAsLinesSync(), ['run']);
      expect(File('${root.path}/metadata.json').existsSync(), isFalse);
    },
    skip: Platform.isWindows,
  );

  test(
    'IDE generator replaces stale metadata with valid empty JSON on capture failure',
    () async {
      final output = File('${root.path}/.dart_tool/ume_git_info.json');
      output.parent.createSync();
      output.writeAsStringSync('{"UME_GIT_COMMIT":"stale"}');
      final result = await run(['generate']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(result.stderr, contains('continuing without it'));
      expect(jsonDecode(output.readAsStringSync()), isEmpty);
    },
    skip: Platform.isWindows,
  );

  test('injection precedes application argument separator', () async {
    initGit();
    final result = await run(['run', '--', 'argument with spaces', '--help']);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final args = File('${root.path}/args.txt').readAsLinesSync();
    expect(args[1], startsWith('--dart-define-from-file='));
    expect(args.sublist(2), ['--', 'argument with spaces', '--help']);
  }, skip: Platform.isWindows);

  test(
    'captures five previous commits excluding the build revision without changing the checkout',
    () async {
      initGit();
      for (var i = 1; i <= 6; i++) {
        git(['commit', '--allow-empty', '-qm', '修改 $i "中文"']);
      }
      final before = await captureGitInfo(workingDirectory: root.path);
      final history =
          jsonDecode(
                utf8.decode(
                  base64Decode(before['UME_GIT_RECENT_COMMITS_BASE64']!),
                ),
              )
              as List;
      expect(history, hasLength(5));
      expect(history.map((entry) => entry['subject']), [
        for (var i = 5; i >= 1; i--) '修改 $i "中文"',
      ]);
      expect(
        history.every((entry) => entry['hash'] != before['UME_GIT_COMMIT']),
        isTrue,
      );
      expect(
        history.every(
          (entry) => (entry['hash'] as String).startsWith(
            entry['shortHash'] as String,
          ),
        ),
        isTrue,
      );
      expect(await captureGitInfo(workingDirectory: root.path), before);
    },
    skip: Platform.isWindows,
  );

  test(
    'short history excludes current revision and keeps all available ancestors',
    () async {
      initGit();
      final initial = (await captureGitInfo(
        workingDirectory: root.path,
      ))['UME_GIT_COMMIT'];
      git(['commit', '--allow-empty', '-qm', 'current build']);
      final info = await captureGitInfo(workingDirectory: root.path);
      final history =
          jsonDecode(
                utf8.decode(
                  base64Decode(info['UME_GIT_RECENT_COMMITS_BASE64']!),
                ),
              )
              as List;
      expect(history, hasLength(1));
      expect(history.single['hash'], initial);
      expect(history.single['hash'], isNot(info['UME_GIT_COMMIT']));
    },
    skip: Platform.isWindows,
  );

  test('captures dirty and detached HEAD states', () async {
    initGit();
    git(['checkout', '--detach', '-q']);
    File('${root.path}/change.txt').writeAsStringSync('uncommitted');
    final info = await captureGitInfo(workingDirectory: root.path);
    expect(info['UME_GIT_BRANCH'], 'Detached HEAD');
    expect(info['UME_GIT_DIRTY'], 'true');
  }, skip: Platform.isWindows);
  test('global options before command still inject metadata', () async {
    initGit();
    for (final prefix in [
      ['--verbose'],
      ['--device-id', 'test-device', '--verbose'],
      ['--device-id=run'],
    ]) {
      final result = await run([...prefix, 'run']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final args = File('${root.path}/args.txt').readAsLinesSync();
      expect(args.take(prefix.length), prefix);
      expect(args.last, startsWith('--dart-define-from-file='));
    }
  }, skip: Platform.isWindows);

  test('history failure preserves current build metadata', () async {
    initGit();
    final realGit = Process.runSync('which', ['git']).stdout.toString().trim();
    final fake = File('${root.path}/bin/git')
      ..writeAsStringSync(
        '#!/bin/sh\nif [ "\$1" = log ] && [ "\$2" = -5 ]; then exit 1; fi\nexec "$realGit" "\$@"\n',
      );
    Process.runSync('chmod', ['+x', fake.path]);
    final result = await run(['run']);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stderr, contains('keeping build revision'));
    final info = jsonDecode(
      File('${root.path}/metadata.json').readAsStringSync(),
    );
    expect(info['UME_GIT_COMMIT'], isNotEmpty);
    expect(info['UME_GIT_AUTHOR'], '测试作者');
    expect(
      jsonDecode(
        utf8.decode(base64Decode(info['UME_GIT_RECENT_COMMITS_BASE64'])),
      ),
      isEmpty,
    );
  }, skip: Platform.isWindows);

  test('hung Git times out and Flutter continues', () async {
    final fake = File('${root.path}/bin/git')
      ..writeAsStringSync('#!/bin/sh\nexec sleep 30\n');
    Process.runSync('chmod', ['+x', fake.path]);
    final watch = Stopwatch()..start();
    final result = await run([
      'run',
    ], code: 7).timeout(const Duration(seconds: 12));
    expect(result.exitCode, 7, reason: result.stderr.toString());
    expect(result.stderr, contains('timed out'));
    expect(watch.elapsed, lessThan(const Duration(seconds: 12)));
    expect(File('${root.path}/metadata.json').existsSync(), isFalse);
  }, skip: Platform.isWindows);

  test(
    'atomic generator replaces existing data and cleans staging files',
    () async {
      initGit();
      final output = File('${root.path}/.dart_tool/ume_git_info.json');
      output.parent.createSync();
      output.writeAsStringSync('{"UME_GIT_COMMIT":"stale"}');
      final result = await run(['generate']);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(
        jsonDecode(output.readAsStringSync())['UME_GIT_COMMIT'],
        isNot('stale'),
      );
      expect(output.parent.listSync().map((entry) => entry.path), [
        output.path,
      ]);
    },
    skip: Platform.isWindows,
  );

  test(
    'write failure returns controlled error and cleans staging files',
    () async {
      initGit();
      final target = Directory('${root.path}/blocked.json')..createSync();
      File('${target.path}/keep').writeAsStringSync('keep');
      final result = await run(['generate', target.path]);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('Failed to write UME Git info file'));
      expect(result.stderr, isNot(contains('Unhandled exception')));
      expect(
        root.listSync().where(
          (entry) => entry.path.split('/').last.startsWith('.ume_git_'),
        ),
        isEmpty,
      );
      expect(File('${target.path}/keep').readAsStringSync(), 'keep');
    },
    skip: Platform.isWindows,
  );

  test('forwards termination and removes temporary metadata', () async {
    initGit();
    final process = await Process.start(
      dartExecutable,
      [launcher.path, 'run'],
      workingDirectory: root.path,
      environment: {...environment, 'UME_TEST_WAIT': '1'},
    );
    final stdoutDone = process.stdout.drain<void>();
    final stderrDone = process.stderr.drain<void>();
    try {
      final ready = File('${root.path}/ready');
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!ready.existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(ready.existsSync(), isTrue);
      expect(process.kill(ProcessSignal.sigterm), isTrue);
      expect(await process.exitCode.timeout(const Duration(seconds: 10)), 23);
      await Future.wait([stdoutDone, stderrDone]);
      final path = File('${root.path}/metadata_path.txt').readAsStringSync();
      expect(File(path).parent.existsSync(), isFalse);
    } finally {
      process.kill(ProcessSignal.sigkill);
    }
  }, skip: Platform.isWindows);
}
