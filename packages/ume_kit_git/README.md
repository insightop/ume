# ume_kit_git

[简体中文](./README_cn.md)

Standalone UME Git revision panel and build-time CLI. Depends only on Flutter
and ume_core. Register `const GitInfo()` and use `dart run ume_kit_git:flutter`
in place of `flutter`, or use the equivalent `ume:flutter` facade command.
The installed app displays embedded build metadata without Git or network access.

## Expanded integration guide (current source)

Standalone host-app Git build metadata for UME: panel, collection and CLI in one
package. Depends on Flutter and `ume_core`, with no `ume_kit_device` dependency.

This guide describes the current repository sources. Use matching local/Git
sources that contain the kit and CLI; a source version number does not establish
that the same pub.dev archive already includes these additions.

## What the panel shows

| Section | Content |
| --- | --- |
| Current build | Full commit ID, branch, full message, author, committer timestamp with timezone, dirty state |
| Recent commits | Up to five entries, collapsed initially; short hash, subject, author and timestamp |
| Copy | Tap a current-build field to copy it; tap a history entry or its copy button for the full hash and details |

History lists up to five commits **before** the captured build revision
(`git log -5 --skip=1 <build-commit>`); the build revision itself is shown under
Current build. Fewer local commits produce fewer entries. The limit is currently
fixed at five, with no count option. The author is Git author name; timestamps
use committer time.
The tool reads the **host app checkout's local HEAD**, not the UME repository or
the remote tip. Dirty state is a flag, not an embedded diff. History does not
represent all changes since the previous test build.

## Register the panel

When using the complete facade:

```dart
import 'package:ume/ume.dart';

PluginManager.instance.register(const GitInfo());
```

For independent usage:

```dart
import 'package:ume_core/ume_core.dart';
import 'package:ume_kit_git/ume_kit_git.dart';

PluginManager.instance.register(const GitInfo());
```

Wrap the app in `UMEWidget` as usual. Registration creates the panel entry;
collection below supplies its data. Both steps are required.

Local standalone dependency example (adjust checkout paths):

```yaml
dev_dependencies:
  ume_kit_git:
    path: ../ume/packages/ume_kit_git

dependency_overrides:
  ume_core:
    path: ../ume/packages/ume_core
```

Run `flutter pub get`. The app does not need to join the UME pub workspace.

## Choose an entry point

| Use case | Complete UME | Standalone kit |
| --- | --- | --- |
| Run, test, build | `dart run ume:flutter …` | `dart run ume_kit_git:flutter …` |
| Generate a file for IDE/native Flutter | `dart run ume:git_info [output.json]` | `dart run ume_kit_git:generate_git_info [output.json]` |

`dart run ume:flutter` runs the package's `bin/flutter.dart`, which then invokes
Flutter. It is not an extra Flutter subcommand. Run from the app project directory
with Git, Dart and the intended Flutter SDK available. The installed app needs
neither Git, network access nor the source JSON file.

### Terminal and build scripts

Replace `flutter` with `dart run ume:flutter`, keeping the remaining arguments:

```sh
dart run ume:flutter run --flavor dev -t lib/main_dev.dart
dart run ume:flutter build apk --release --flavor dev -t lib/main_dev.dart
dart run ume:flutter build ipa --release --flavor dev -t lib/main_dev.dart
dart run ume:flutter test
```

Use your actual flavor and entry point, or omit flavor options when unused.
`run`, `build` and `test` inject metadata through a fresh system temporary JSON
file. The file is removed after Flutter exits. Other commands and help requests
pass through. Terminal streams, arguments and Flutter's exit code are preserved;
termination signals are forwarded on macOS/Linux.

### Android Studio / IntelliJ

Keep the IDE's native Flutter configuration for breakpoints and hot reload.

1. Open **Run → Edit Configurations → + → Shell Script**.
2. Create this project run task:

| Field | Value |
| --- | --- |
| Name | `ume_git_info` |
| Mode | **Script text** |
| Script text | `dart run ume:git_info` |
| Interpreter | macOS/Linux: `/bin/sh` |
| Working directory | `$ProjectFileDir$`, the app project root |
| Execute in terminal | Unchecked, so the IDE waits and checks the exit code |

If the IDE cannot find Dart, use your Flutter SDK's absolute Dart executable path.
On Windows, adapt the script interpreter and executable paths to your installation.

3. In the Flutter configuration, append this to **Additional run args**:

```text
--dart-define-from-file=.dart_tool/ume_git_info.json
```

Keep existing debug/release flags, flavor and entry point.

4. Under **Before launch**, choose **+ → Run Another Configuration → ume_git_info**.
5. Confirm `Run 'ume_git_info'` appears, then **Apply → OK**. Repeat for each relevant Flutter configuration.

This uses a project task, without requiring a global External Tool.

### VS Code / Cursor

Merge this task into `.vscode/tasks.json`:

```json
{
  "version": "2.0.0",
  "tasks": [{
    "label": "UME Git Info",
    "type": "process",
    "command": "dart",
    "args": ["run", "ume:git_info"],
    "options": {"cwd": "${workspaceFolder}"},
    "problemMatcher": []
  }]
}
```

Add the pre-launch task and compiler-file argument to `.vscode/launch.json`:

```json
{
  "version": "0.2.0",
  "configurations": [{
    "name": "App with UME Git Info",
    "type": "dart",
    "request": "launch",
    "program": "lib/main.dart",
    "preLaunchTask": "UME Git Info",
    "toolArgs": ["--dart-define-from-file=.dart_tool/ume_git_info.json"]
  }]
}
```

Retain your app's entry point and other tool arguments. Both IDE workflows run the
generator first, then let the IDE start Flutter with the generated definitions.

### Native Flutter and custom output files

```sh
dart run ume:git_info
flutter run --dart-define-from-file=.dart_tool/ume_git_info.json

# Generation and compilation must reference the same file.
dart run ume:git_info .dart_tool/custom_git_info.json
flutter build apk --dart-define-from-file=.dart_tool/custom_git_info.json
```

The default file remains on disk and is overwritten before each IDE launch.
Metadata is compiled into the app through `String.fromEnvironment`.

## Failure behavior

| Condition | Result |
| --- | --- |
| Git missing, no repository, no commits, or another capture failure | Log a warning and continue |
| IDE generator capture failure | Replace stale data with `{}` and exit successfully; Flutter can still read the file |
| Wrapper capture failure | Invoke Flutter without injecting Git metadata |
| IDE output-file I/O failure | Report failure, rather than silently using stale metadata; fix the path/permissions |
| Flutter build failure | Preserve Flutter's failing exit code |
| No current-build metadata | Show “暂无 Git 信息”; omit Git fields and history |
| Older build without history or malformed history data | Retain current-build fields and omit history |

## Icons and troubleshooting

The icon is embedded as Base64 bytes and loaded with `MemoryImage`. No consumer
asset declaration is required, including when UME is a dev dependency. The PNG
in `assets/` remains the source image, not a runtime asset dependency.

- **Old revision after changes:** stop and run/build again. Hot reload and hot
  restart do not rerun the generator or recompile command-line definitions.
- **Empty Before launch list:** explicitly associate the Shell Script task using
  **Run Another Configuration**, then apply. Creating the task or adding the
  JSON argument alone does not link the two configurations.
- **Missing JSON:** check the generator's app-root working directory, execution
  and output path. Keep the default `.dart_tool/` ignored by Git.
- **Fewer than five commits in CI:** shallow checkouts may contain fewer commits.
  Use checkout `fetch-depth: 0` when full history is needed. UME never fetches.
- **Unexpected dirty state:** Git includes tracked edits and untracked files.
  Ignore custom generated output paths so they do not affect subsequent runs.
- **Release/Profile:** this panel does not depend on VM Service. Register it and
  wrap UME in the intended internal entry point; debug-only registration will
  not appear in release builds.

## Development

From the repository root:

```sh
flutter pub get
dart analyze packages/ume_kit_git
dart analyze packages/ume/bin
flutter test packages/ume_kit_git/test
# Also validate interaction with actual injected build/history data:
dart run ume:flutter test packages/ume_kit_git/test/git_info_test.dart
```

Coverage includes history order and limits, Unicode, fail-open capture, stale
file replacement, argument/exit-code forwarding, temporary files, collapsible
history, copying and image decoding.

### Platform support

The panel uses Flutter APIs only. Git capture and the CLI wrapper are tested on
macOS/Linux; on Windows the wrapper uses `runInShell`/`.bat`, and its CLI tests
are currently skipped, so treat Windows as preview until CI covers it.


## Capture reliability and SDK selection

- Git capture is asynchronous with a shared 5-second budget. A capture failure or timeout does not prevent Flutter from running; history failures only omit recent commits.
- Current revision fields are collected together, reducing normal capture to four Git processes.
- IDE generation stages JSON beside the destination and atomically replaces it. Capture failures replace old data with `{}`; file write failures still return a nonzero exit code. Temporary-file cleanup failures produce warnings without replacing the command result.
- Global Flutter options may precede `run`, `build`, or `test`, for example `dart run ume:flutter --verbose run`.
- SDK selection: `UME_FLUTTER_EXECUTABLE` (explicit executable path), then Flutter alongside the running Dart SDK, then `flutter` on PATH. Set the override when your SDK manager requires a different executable.
- Dart API callers must now `await captureGitInfo()` and `await generateGitInfo(args)`. `captureGitInfo(timeout: Duration(seconds: 5))` accepts a custom total budget. CLI commands are unchanged.
- Recent commit rows show time first, subject second, and short hash plus author third. Copying retains the full hash.
