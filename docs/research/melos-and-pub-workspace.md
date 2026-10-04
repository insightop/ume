# Melos × native Dart pub workspaces

**Investigated:** 2026-10-01 · **Repo:** [insightop/ume](https://github.com/insightop/ume) (local `/Users/bookshiyi/repos/ume`)
**melos source inspected:** `invertase/melos` @ [`073b1506`](https://github.com/invertase/melos/commit/073b15060c5269496b065aa5629008bb1b5a2bfe) (2026-09-28), plus the local pub-cache copy of `melos 8.9.0`
**Local toolchain:** Dart 3.13.4 / melos 8.9.0 · **pub source inspected:** `dart-lang/pub` `lib/`

Primary sources only: the `invertase/melos` repo (`docs/`, `CHANGELOG.md`, `packages/melos/lib/`), `dart.dev` docs, `dart-lang/pub` source, `pub.dev` API, and real repos fetched via `gh`/`gh api`. Each claim is marked **[documented]**, **[observed in source]**, **[observed empirically]**, **[community-reported]**, or **[unconfirmed]**.

> Companion doc: [pub-workspace-publishing.md](./pub-workspace-publishing.md) covers the *pub* side (why a published archive with a dangling `workspace:` breaks consumers). This doc covers the *melos* side.

---

## TL;DR

1. **Yes — pub workspaces are melos's official, required model since melos 7.0.0.** melos 7.0.0 (2025-08-15) is *"the first stable release of Melos that uses the Pub workspaces feature"* and it was a **breaking** migration (`melos.yaml` removed → config moves into the root `pubspec.yaml`; members must add `resolution: workspace`). **[documented]** — [`CHANGELOG.md` 2025-08-15](https://github.com/invertase/melos/blob/main/CHANGELOG.md), [migration guide](https://melos.invertase.dev/guides/migrations).
2. **There is no "melos + workspace" integration knob — melos *is* the workspace root.** melos reads the workspace membership from the root pubspec's `workspace:` key (it does not parse `resolution:` at all). `useRootAsPackage: false` is the **default** and the correct setting when the root is a pub workspace root. **[observed in source]**
3. **`melos.yaml` is dead in ≥7.0.0.** `MelosWorkspaceConfig.fromWorkspaceRoot` reads *only* `<root>/pubspec.yaml`; no code path opens `melos.yaml`. Verified empirically: a `melos.yaml` sitting at the workspace root is silently ignored. **[observed in source + empirically]**
4. **`melos bootstrap` runs exactly ONE `pub get`, in the workspace root**, never per package — that is `#822` ("Only run pub get in workspace root", merged 2025-01-07). It writes no `pubspec_overrides.yaml` (unless you opt into `dependencyOverridePaths`). Verified empirically on a 2-member workspace. **[observed in source + empirically]**
5. **`runPubGetInParallel: true` — which `ume` sets — does nothing in melos ≥7.** `BootstrapCommandConfigs.runPubGetInParallel` is parsed, serialized and `==`-compared, but **never read by any command**. Its doc comment is also stale (it is documented as "used to run `pub get` in parallel", but the field defaults to `true` while the actual `bootstrap` command has always had to run in parallel). **[observed in source]**
6. **`melos:` config in the root `pubspec.yaml` is the documented and only supported location**, and *every* major repo does it — including melos itself, `flame`, `drift`, `dashbook`. A `melos.yaml` next to it is dead weight. **[documented + observed in repos]**
7. **Publishing is unaffected in melos's own code path**: `melos publish` shells out to `dart pub publish` (or `flutter pub publish`) once per package from that package's directory. melos never rewrites a pubspec for publishing. **[observed in source]**
8. **Publishing members with `resolution: workspace` is safe and is what upstream does.** `melos 8.9.0`, `drift_dev 2.35.1`, `flame 1.38.2`, `ume_core 2.0.3` all ship `resolution: workspace` in their published archives and work downstream. **[observed empirically]**
9. **⚠️ For `ume` specifically: do NOT run `melos publish` yet.** `melos publish` publishes **every** unpublished package in the workspace by default. The root `ume_workspace` is `publish_to: none` so it is skipped, and `ume_kit_example` is also private — but the remaining **20** publishable packages (`ume`, `ume_core`, 18 kits) would be attempted in one run, and `melos version` **corrupts quoted range constraints** (issue [#1039](https://github.com/invertase/melos/issues/1039), reproduced on 7.8.2 /*and* 8.0.0 /*and* `main`). `ume`'s current per-tag `dart pub -C` workflow sidesteps both. See §6.
10. **The one real melos-side trap left in `ume` is `packages/*/example`** — a glob whose only match (`packages/ume_kit_shared_preferences/example`) is scheduled to move. `melos list` / `melos bootstrap` tolerate it, but **`dart pub get` hard-fails** when a `workspace:` glob matches nothing (`No workspace packages matching`). That is a *pub* failure triggered by a *melos-era* root layout. **[observed in source + cross-ref to companion doc]**

---

## 1. Melos + pub workspace: official support matrix

### 1.1 Version timeline

| melos | released | pub-workspace support | evidence |
|---|---|---|---|
| ≤ 6.3.3 | 2025-05-25 | **none** — generates `pubspec_overrides.yaml`; `melos.yaml` config | [CHANGELOG 6.x](https://github.com/invertase/melos/blob/main/CHANGELOG.md), [#747](https://github.com/invertase/melos/issues/747) |
| 7.0.0-dev.1 … -dev.10 | 2025-01-07 → 2025-09-12 | experimental | [`#816`](https://github.com/invertase/melos/pull/816) merged 2025-01-07 |
| **7.0.0** | **2025-08-15** | **first stable** — breaking migration to pub workspaces | [CHANGELOG 2025-08-15](https://github.com/invertase/melos/blob/main/CHANGELOG.md); pub.dev `published` = `2025-08-15T12:02:34Z` |
| 7.1.0 | 2025-08-21 | adds `useRootAsPackage` | [`#927`](https://github.com/invertase/melos/pull/927) |
| 7.4.0 | 2026-01-27 | adds `discoverNestedWorkspaces` (nested workspaces) | [`#968`](https://github.com/invertase/melos/issues/968) |
| 8.0.0 | 2026-06-23 | **breaking**: `exec.command` config shape; build-number retention | [CHANGELOG 8.0.0](https://github.com/invertase/melos/blob/main/CHANGELOG.md) |
| 8.1.0 | 2026-07-03 | restores `melos analyze` (removed in 7.0.0) | [`#1037`](https://github.com/invertase/melos/issues/1037) |
| **8.9.0** | **2026-09-21** | current; `ume` pins `^8.9.0` | `packages/melos/lib/version.g.dart` → `melosVersion = '8.9.0'` |

**The 7.0.0 changelog entry, verbatim** (`.github`-generated from the release; [source](https://github.com/invertase/melos/blob/main/CHANGELOG.md)):

> #### `melos` - `v7.0.0`
> This version has all the changes from the `7.0.0-dev.x` releases, and is the first stable release
> of Melos that uses the Pub workspaces feature.
>
> - **BREAKING** **FEAT**: Remove melos.yaml in favor of the root pubspec.yaml ([#832](https://github.com/invertase/melos/issues/832)).
> - **BREAKING** **FEAT**: Migrate to use the Pub workspaces feature ([#816](https://github.com/invertase/melos/issues/816)).
> - **FIX**: Only run pub get in workspace root ([#822](https://github.com/invertase/melos/issues/822)).

**The PR that introduced it** — [`invertase/melos#816`](https://github.com/invertase/melos/pull/816) "feat!: Migrate to use the Pub workspaces feature", opened 2025-01-06, merged 2025-01-07, closes [`#747`](https://github.com/invertase/melos/issues/747) ("request: pub workspaces", opened 2024-08-07):

> This PR migrates so that we rely on the pub workspaces feature instead of creating the pubspec_overrides.yaml file.

`#747` was opened by a community member on 2024-08-07 and replied to same-day by maintainer **spydon**:

> It is indeed planned, thanks for opening an issue so that we can track it! I'll link in the Flutter design doc for it is here too: <https://flutter.dev/go/pub-workspace>

**[community-reported + maintainer guidance]**, [`#747` comments](https://github.com/invertase/melos/issues/747).

### 1.2 Does melos parse `resolution: workspace`? **No.**

**[observed in source]** — a full-tree grep of `packages/melos/lib/` finds **zero** references to `resolution` as a pubspec field:

```
$ grep -rn "resolution" packages/melos/lib/
lib/src/command_runner/publish.dart:37:  'Publish without validation and resolution (this will ignore '
lib/src/command_configs/publish.dart:282:  /// Whether packages are published without validation and resolution.
lib/src/commands/bootstrap.dart:105:  'Dependency resolution failed, rolling back changes to '
```

All three are unrelated (the `--skip-validation` flag text and a log string). melos's only read of workspace *membership* is the root's `workspace:` key:

**[observed in source]** — `packages/melos/lib/src/workspace_config.dart`:

```dart
final packages = assertListIsA<String>(
  key: 'workspace',
  map: pubspecYaml,
  isRequired: false,
  ...
);
```

`workspace` is read from the **root pubspec** (note `map: pubspecYaml`), while everything else — `categories`, `ignore`, `scripts`, `ide`, `command`, `sdkPath`, `quiet`, `useRootAsPackage`, `discoverNestedWorkspaces`, `pub` — is read from `map: melosYaml`, where:

```dart
final melosYaml = pubspecYaml['melos'] as Map<Object?, Object?>? ?? {};
```

**Consequence:** `resolution: workspace` in members is entirely pub's business. melos neither validates nor requires it — but pub does, fatally:

**[observed in source]** — `dart-lang/pub` `lib/src/package.dart`:

```dart
if (package.pubspec.resolution != Resolution.workspace) {
  fail('''
${package.pubspecPath} is included in the workspace from ${p.join(dir, 'pubspec.yaml')}, but does not have `resolution: workspace`.
...
```

So "melos + pub workspace" is really "**pub** enforces member flags; **melos** reads the member list and layers scripts/versioning/publishing on top."

### 1.3 What melos does differently when it detects a pub workspace

**`melos bootstrap` runs one `pub get`, at the workspace root.** **[observed in source]** — `packages/melos/lib/src/commands/bootstrap.dart`:

```dart
Future<void> _runPubGetForWorkspace(
  MelosWorkspace workspace, {
  ...
}) async {
  await runPubGetForPackage(
    workspace,
    workspace.rootPackage,   // ← the workspace root, not the members
    ...
  );
}
```

and `runPubGetForPackage` sets `workingDirectory: package.path` for that single invocation.

**Verified empirically** — a fresh 2-member workspace (`packages/a`, `packages/b`, both `resolution: workspace`), `melos 8.9.0`, Dart 3.13.4:

```
$ dart pub global run melos bootstrap
melos bootstrap
  └> /private/tmp/mstest

Running "dart pub get" in workspace...
  > SUCCESS

Generating IntelliJ IDE files...
  > SUCCESS

 -> 2 packages bootstrapped

$ ls .dart_tool/package_config.json          → PRESENT   (single, at root)
$ ls packages/a/.dart_tool/                  → pub/  ONLY
$ ls packages/a/.dart_tool/pub/              → workspace_ref.json
$ ls packages/*/pubspec_overrides.yaml       → NONE
```

So: **one** shared `.dart_tool/package_config.json` at the root, a small `.dart_tool/pub/workspace_ref.json` marker in each member, and **no** `pubspec_overrides.yaml`. This is exactly the pub-workspace shape, and it means the old melos 6.x "per-package `pub get` + per-package overrides" cost is gone.

Note this **supersedes** the pre-7.0.0 community advice. In [`#747`](https://github.com/invertase/melos/issues/747) a contributor wrote (2024-12-04):

> You MUST NOT use `melos bootstrap` as it will try to generate the overrides again. I suggest to just use `dart pub get` and melos for all the other commands.

and maintainer spydon replied: *"it shouldn't be a problem for them to co-exist already afaik."* That was true for melos 6.3.x only if you avoided bootstrap; from **7.0.0 onward it is obsolete** — bootstrap is safe.

**[documented]** — melos's own bootstrap doc now says the same:

> After the [Pub Workspaces feature](https://dart.dev/tools/pub/workspaces) was introduced in Dart 3.6.0, it is no longer strictly necessary to run `melos bootstrap`, since all the packages are already linked together. However, there are still some benefits to running `melos bootstrap`, if you for example want to set up shared dependencies or attaching your own setup scripts to the bootstrap hooks.

---

## 2. Correct configuration

### 2.1 Where `melos:` lives

**In the root `pubspec.yaml`, under a top-level `melos:` key. `melos.yaml` is not supported at all in ≥7.0.0.** **[documented]**

The migration guide states it plainly:

> 1. There is no longer a `melos.yaml` file, only the root `pubspec.yaml`
> 2. You now have to add `resolution: workspace` to all of your packages' `pubspec.yaml` files.
> 3. You now have to add a list of all your packages to the root `pubspec.yaml` file.

and PR [`#832`](https://github.com/invertase/melos/pull/832) ("feat!: Remove melos.yaml in favor of the root pubspec.yaml", merged 2025-01-10) explains *why*:

> Since we now declare the packages in the `workspace` section in the `pubspec.yaml` file we'll move the rest of the config in there too, under it's own `melos` section. This is common practice for other dart tools too and the Dart team knows about it.

**[observed in source]** — `MelosWorkspaceConfig.fromWorkspaceRoot` opens exactly one file:

```dart
final rootPubspecFile = File(pubspecPathForDirectory(workspaceRoot.path));
...
rootPubspecContent = loadYamlNode(await rootPubspecFile.readAsString(), ...)
...
return MelosWorkspaceConfig.fromYaml(rootPubspecContent, path: workspaceRoot.path, ...);
```

If that file is missing it throws `Found no pubspec.yaml file in "<path>". You must have a pubspec.yaml file in the root of your workspace.` The only remaining `melos.yaml` strings in `lib/` are **stale CLI help text** (e.g. `'Lists all scripts defined in the melos.yaml config file.'` in `command_runner/run.dart`) — cosmetic bugs, not behavior.

**Verified empirically:** dropping a legacy `melos.yaml` at the root of a working workspace changes nothing — `melos list` still lists the members from `pubspec.yaml`, and a script defined *only* in `melos.yaml` is invisible:

```
$ dart pub global run melos list
pkg_a
pkg_b

$ dart pub global run melos run hello      # hello defined only in melos.yaml
NoScriptException: This workspace has no scripts defined in its 'pubspec.yaml' file.
```

A leftover `melos.yaml` is therefore **dead weight** — safe to delete, actively misleading if kept. (melos still ships `melos.yaml.schema.json` at the repo root for IDE use, but nothing in `lib/` references it.)

### 2.2 `useRootAsPackage`

**[documented]** — from the melos configuration reference:

> **useRootAsPackage** — Whether to include the repository root as a package in the workspace. When enabled, the root directory (containing the workspace configuration) will be treated as a package and included in workspace operations such as scripts, filtering, and categorization.
> **Defaults to `false`** for backward compatibility.

Use cases listed are: legacy 6.x projects with the main app at the root; projects whose primary Flutter app is at the root; category filtering on the root; and **single-package (non-monorepo) projects** that want versioning/publishing.

**`useRootAsPackage: false` is correct for `ume`.** **[observed in source]**

```dart
final allPackages = workspaceConfig.useRootAsPackage
    ? packages.addPackage(rootPackage)
    : packages;
```

The root package is only merged into `allPackages` when the flag is `true`. With `false`, `ume_workspace` is excluded from scripts, filtering, versioning and publishing — exactly what you want for a `publish_to: none` virtual root.

**Gotcha if you ever flip it to `true`:** the root then uses **plain** version tags (`v1.2.3`) instead of `<pkg>-v1.2.3`. **[documented]** and **[observed in source]** (`lib/src/common/git.dart`):

> The root package uses plain version tags, e.g. `v1.2.3`, instead of tags prefixed with the package name, e.g. `my_package-v1.2.3`, that all other packages use.

`ume`'s release tags are currently mixed: `v2.0.8` (plain, root-era) *and* `ume_kit_console-v2.0.4` etc. (per-package). Keeping `useRootAsPackage: false` avoids any interaction with that.

### 2.3 Bootstrap config — and a dead option

`ume` currently sets:

```yaml
melos:
  useRootAsPackage: false
  command:
    bootstrap:
      runPubGetInParallel: true
```

**`runPubGetInParallel` has no effect in melos ≥7.** **[observed in source]** — every occurrence in the whole repo:

```
lib/src/command_configs/bootstrap.dart:17     this.runPubGetInParallel = true,
lib/src/command_configs/bootstrap.dart:35     final runPubGetInParallel = ...
lib/src/command_configs/bootstrap.dart:126    runPubGetInParallel: runPubGetInParallel,
lib/src/command_configs/bootstrap.dart:151    final bool runPubGetInParallel;
lib/src/command_configs/bootstrap.dart:211    'runPubGetInParallel': runPubGetInParallel,   // toJson
lib/src/command_configs/bootstrap.dart:234    ... == runPubGetInParallel,                  // ==
lib/src/command_configs/bootstrap.dart:257    runPubGetInParallel,                         // hashCode
lib/src/command_configs/bootstrap.dart:278    runPubGetInParallel: $runPubGetInParallel,    // toString
```

plus tests in `test/workspace_config_test.dart`. **No command ever reads it.** Since bootstrap now issues a single `pub get` at the root (§1.3), parallelism over packages is meaningless — the option is vestigial. Harmless, but worth deleting to avoid implying behavior that doesn't exist.

Its doc comment is also stale: it claims `The default is `true`.` under the heading *"Whether to run `pub get` in parallel during bootstrapping"*, yet §1.3 shows there is only one `pub get`.

### 2.4 Recommended `melos:` block for a workspace-root layout like `ume`

```yaml
melos:
  useRootAsPackage: false        # default; root is a virtual, unpublished package
  command:
    version:
      branch: master             # ume's default branch
      linkToCommits: true        # requires `repository:` — see caveat below
    publish:
      dryRun: true               # default anyway; explicit is better
  scripts:
    test:
      exec:
        command: flutter test --enable-vmservice
        concurrency: 1
      packageFilters:
        dirExists: test
    analyze:
      exec:
        command: dart analyze --no-fatal-warnings .
      packageFilters:
        dirExists: lib
```

**Caveat — `linkToCommits` requires a `repository:`.** **[documented]** *"Enabling this option, requires `repository` to be specified."* `ume`'s root pubspec currently has **no** `repository:` key (verified), so either add `repository: https://github.com/insightop/ume` or leave `linkToCommits` off. melos will otherwise fail at `No repository configured in the pubspec.yaml file to generate a changelog link.`

**Note the 8.x breaking change** that `ume` must respect (its current pubspec already does): `run` and `exec` are **mutually exclusive**, and exec options moved under `exec.command`. **[documented]** — migration guide 7.x → 8.0.0:

> `run` and `exec` are now mutually exclusive: a script either runs once in the workspace root with `run`, or across multiple packages with `exec`. When you need to pass options to `exec`, move the command into `exec` under the new `command` key.

---

## 3. Publishing a workspace member with melos

### 3.1 How `melos publish` actually publishes

**[observed in source]** — `lib/src/commands/publish.dart`:

1. It queries the registry for every non-private package and diffs local vs published version.
2. It builds `execArgs = [...pubCommandExecArgs(useFlutter: false, workspace: workspace), 'publish', if (dryRun) '--dry-run' else '--force', ...]`.
3. It calls `_execForAllPackages(workspace, execArgs, executablePackages: unpublishedPackages, concurrency: 1, failFast: true, ...)`.

`_execForAllPackages` sets `workingDirectory: package.path` per package (`lib/src/commands/exec.dart`), i.e. **melos runs `dart pub publish` once per package, from inside that package's directory.** There is **no** pubspec rewriting, **no** `workspace:`/`resolution:` manipulation — which mirrors what the companion doc proved for pub itself: *"`dart pub publish` never rewrites `pubspec.yaml`."*

**[documented]** — melos's own publish doc confirms the same delegation:

> `<Info>Internally, Melos uses `pub publish` to publish the packages.</Info>`

### 3.2 Does `melos version` / `melos publish` touch `workspace:` / `resolution:`?

**No.** **[observed in source]** — the only pubspec writes in the version command are:

| what | code |
|---|---|
| bump `version:` | `editor.update(['version'], version.toString())` — `commands/version.dart` |
| rewrite a dependency constraint at a YAML path | `editor.update(path, ...)` in `_rewriteDependencyVersionAtPath` |
| rewrite a git ref at a YAML path | `editor.update(path, ref)` in `_rewriteGitRefAtPath` |

All use `YamlEditor` on specific paths; none touch a top-level `workspace:` or `resolution:` key. So a workspace member published via melos keeps whatever `resolution: workspace` it had — which is exactly what upstream ships.

**[observed empirically]** — published archives, downloaded from `pub.dev/api/archives/`:

| package | published | `resolution:` in archive | `workspace:` in archive |
|---|---|---|---|
| `melos` | 8.9.0 | `workspace` | absent |
| `drift_dev` | 2.35.1 | `workspace` | absent |
| `flame` | 1.38.2 | `workspace` | absent |
| `ume_core` | 2.0.3 | `workspace` | absent |
| `ume` | 2.0.8 | **absent** | **`[example, packages/*]`** ← the bug |

Also **[observed empirically]** — pub.dev's own metadata API reports `resolution: workspace` for `melos 7.0.0` and `8.9.0`:

```
$ curl -s https://pub.dev/api/packages/melos | jq '.versions[]|select(.version=="7.0.0")|.pubspec'
{ "name": "melos", "version": "7.0.0", "environment": {"sdk": "^3.9.0"}, "resolution": "workspace" }
```

**Conclusion:** publishing a member with `resolution: workspace` is normal, supported, and harmless downstream (see companion doc §1.3 and §2.2 — the same code path that breaks on a *dangling* `workspace:` treats `resolution: workspace` as a no-op). A `workspace:` field must **never** be present in anything you publish.

### 3.3 ⚠️ Two melos-specific publishing traps for `ume`

**(a) `melos publish` is all-or-nothing by default.** It collects **every** non-private, unpublished package in the workspace and publishes all of them in one run, with `failFast: true`, `concurrency: 1`:

```dart
final unpublishedPackages = <Package>[
  for (final entry in latestPublishedVersionForPackages.entries)
    if (entry.value == null || entry.value != workspace.filteredPackages[entry.key]!.version.toString())
      workspace.filteredPackages[entry.key]!,
];
```

**[observed in source]**. `ume` has **21** package directories under `packages/`, of which **20 are publishable** — `ume`, `ume_core`, and 18 kits. `ume_kit_example` is private (`publish_to: "none"`), and the root `ume_workspace` is `publish_to: none`. Both are excluded by `package.isPrivate` (which also treats a missing `version:` as private, per `lib/src/package.dart`), so the root is safely skipped — but a single `melos publish --no-dry-run` would attempt to publish **all 20 at once**. Use `--scope`/`--since` filters, or (as `ume` does today) per-package `dart pub -C packages/<x> publish`.

**(b) `melos version` corrupts quoted range constraints.** **[community-reported]**, [`#1039`](https://github.com/invertase/melos/issues/1039) — *"melos version corrupts quoted space-separated range constraints in dependents"*, filed 2026-07-03, **closed**, but the reporter verified the regex is unchanged on `melos-v7.8.2`, `melos-v8.0.0` **and `main`**:

> When `melos version` bumps a package and rewrites dependents' constraints, a dependency declared with a quoted, space-separated range constraint gets **corrupted** instead of rewritten.
> ```yaml
> dependencies:
>   crypto_keys_plus: ">=0.4.0 <1.0.0"
> ```
> Result in the dependent's pubspec:
> ```yaml
>   crypto_keys_plus: ^0.6.0 <1.0.0"
> ```
> ```
> Error on line 14, column 21 of packages/.../pubspec.yaml: Invalid version constraint: Cannot include other constraints with "^" constraint in "^0.6.0 <1.0.0"".
> ```
> Real-world occurrence: https://github.com/Bdaya-Dev/oidc/actions/runs/28638001109 (melos 7.8.2 via bluefireteam/melos-action).

Root cause per the report: `_versionConstraintRegExp`'s trailing character class contains no whitespace, so the match stops at the space and the rewrite splices over only part of the constraint. **`ume`'s members use plain caret constraints internally** (`ume_core: ^2.0.1`, `ume_kit_channel_monitor: ^2.0.0`, …), so `ume` is currently not exposed — but any future `">=x <y"` internal constraint would be a live hazard. Also **[community-reported]** [`#1057`](https://github.com/invertase/melos/issues/1057) (`--yes` ignored in `melos version -V` in non-interactive environments) — relevant if `ume` ever moves to `melos version` in CI.

**(c) The pre-publish registry read can 403.** **[community-reported]** [`#1083`](https://github.com/invertase/melos/issues/1083) (filed 2026-09-11, closed) — `melos publish` failed at *"Reading pub registry for package information..."* with a 403 because `PubHostedClient` sent the stored pub.dev credential on an unauthenticated pre-publish read. Reproduced in CI via `bluefireteam/melos-action@v3` OIDC mode against melos 8.7.0. Not a workspace issue, but it means *any* migration to `melos publish` inherits a second, independent failure mode that `dart pub -C … publish` does not have.

---

## 4. Upstream melos issues / gotchas

### 4.1 Workspace-migration issues

| # | Title | State | Created → Closed | Relevance |
|---|---|---|---|---|
| [747](https://github.com/invertase/melos/issues/747) | request: pub workspaces | **closed** (completed by 7.0.0) | 2024-08-07 → 2025-08-15 | **The origin.** Community request; spydon confirmed it was planned same day. Contains the pre-7.0.0 workarounds that are now obsolete. |
| [816](https://github.com/invertase/melos/pull/816) | feat!: Migrate to use the Pub workspaces feature | **merged** | 2025-01-06 → 2025-01-07 | The implementation. Replaces `pubspec_overrides.yaml` generation with pub workspaces. Closes #747. |
| [822](https://github.com/invertase/melos/pull/822) | fix: Only run pub get in workspace root | **merged** | 2025-01-07 → 2025-01-07 | *"We no longer need to run `pub get` in all packages, in one package, or the workspace root is enough."* Directly answers Q1. |
| [832](https://github.com/invertase/melos/pull/832) | feat!: Remove melos.yaml in favor of the root pubspec.yaml | **merged** | 2025-01-09 → 2025-01-10 | Directly answers Q2. |
| [927](https://github.com/invertase/melos/pull/927) | feat: Add useRootAsPackage for Melos 7.x root package support | **merged** | 2025-08-21 → 2025-08-21 | Directly answers Q2's `useRootAsPackage`. Closes #925, #893. |
| [893](https://github.com/invertase/melos/issues/893) | request: Melos for non-monorepos | **closed** | 2025-04-09 | Single-package use case, resolved by `useRootAsPackage`. |
| [925](https://github.com/invertase/melos/issues/925) | Repository root as a workspace package | **closed** | 2025-08-21 → 2025-08-21 | 6.x→7.x regression for root-as-package layouts; resolved by `useRootAsPackage: true`. |
| [931](https://github.com/invertase/melos/issues/931) | request: support non-workspace packages | **closed** | 2025-08-25 → 2025-09-13 | **Not supported.** *"With v7, it seems melos now requires dart workspaces."* Relevant if `ume` ever wants partially-checked-out packages (sparse checkout). Pub hard-fails on a missing workspace member. |
| [917](https://github.com/invertase/melos/issues/917) | fix: dart workspace includes assets from other apps | **closed** | 2025-06-27 → 2025-06-27 | **Workspace-side, not melos.** Multiple app members share one resolution, so `flutter build` on app1 picks up app2's assets. `ume` has `example/` + `ume_kit_example` — same class of layout, worth watching. |
| [918](https://github.com/invertase/melos/issues/918) | How to make melos run the command from the root of the workspace? | **closed** | 2025-07-10 → 2025-07-10 | **Answers Q4's "wrong directory" question: melos runs `exec` per-package by design** (see §4.3). The user wanted root-cwd; maintainers kept per-package. |
| [919](https://github.com/invertase/melos/issues/919) | fix: Workspace Dependency Boundaries Not Enforced in Dart + Melos Setup | **closed** | 2025-07-23 → 2025-07-24 | **Workspace semantics, not melos.** In a pub workspace every member can *see* every other member's packages without declaring them; also produced `Cannot override workspace packages`. Real gotcha for a 20-publishable-package workspace: `ume` kits can accidentally import siblings without a declared dependency and still analyze clean. |
| [920](https://github.com/invertase/melos/issues/920) | fix: melos bootstrap filtering options are ignored in v7 | **closed** | 2025-07-27 → 2025-07-27 | `melos bootstrap --scope=foo` silently bootstraps everything (one root `pub get`). **Expected**, per §1.3 — filters can't apply to a single root resolution, so `melos bootstrap --diff` is a no-op for `pub get` in v7. |
| [930](https://github.com/invertase/melos/issues/930) | fix: Null check operator used on null value exception (when using nested workspaces) | **closed** | 2025-08-24 → 2025-08-28 | Crash with nested workspaces; `discoverNestedWorkspaces` (7.4.0) formalized nested-workspace support. |
| [934](https://github.com/invertase/melos/issues/934) | fix: melos bootstrap fails if we upgrade environment constraints | **closed** | 2025-09-05 → 2025-09-27 | Bumping `melos.command.bootstrap.environment.sdk` and the root SDK together fails resolution. Relevant if `ume` ever adopts shared-dependency syncing. |
| [938](https://github.com/invertase/melos/issues/938) | `melos` should not be both in `dev_dependencies` and on `$PATH` | **closed** | 2025-09-13 → 2025-09-13 | Version-skew trap: `dart pub global activate melos` may install a different version than the `dev_dependencies` pin. melos 8.0.0 fixed nested invocation via `dart run melos:melos`. **`ume` hits this** — see §4.2. |
| [968](https://github.com/invertase/melos/issues/968) | feat: recursively discover packages in nested workspaces | **closed** | shipped in **7.4.0** (2026-01-27) | Adds `discoverNestedWorkspaces`. |
| [1089](https://github.com/invertase/melos/issues/1089) | fix: detect Flutter packages through the workspace dependency graph | **closed** | shipped in **8.9.0** | melos deciding `dart` vs `flutter` for `pub get`. Relevant: `ume` is a Flutter workspace, so bootstrap must use `flutter pub get`. |
| [1039](https://github.com/invertase/melos/issues/1039) | melos version corrupts quoted range constraints in dependents | **closed** | 2026-07-03 | **Unfixed at source on `main`** per the reporter. See §3.3(b). |
| [1003](https://github.com/invertase/melos/issues/1003) | Regression in 7.4.0: `--order-dependents` fails on `dev_dependency` cycles | **closed** | 2026-04-22 | Ordering regression, resolved. |
| [1057](https://github.com/invertase/melos/issues/1057) | Regression: `--yes` ignored in `melos version -V`, throws `StdinException` in non-interactive env | **closed** | 2026-07-30 | CI-relevant for `melos version`. |
| [1083](https://github.com/invertase/melos/issues/1083) | `PubHostedClient` sends stored pub.dev credential on pre-publish registry read → 403 | **closed** | 2026-09-11 | Breaks `melos publish` in OIDC CI. See §3.3(c). |
| [1062](https://github.com/invertase/melos/issues/1062) | request: avoid cascading releases when dependent constraints allow updated version | **closed** | 2026-08-24 | Became `command/version/smartDependents` (`false` by default). Relevant to `ume`'s 20-publishable-package graph: without it, one kit bump can cascade versions across dependents. |
| [478](https://github.com/invertase/melos/issues/478) | fix: change the default for non-core package functionality to false (IntelliJ project files gen) | **OPEN** | 2023-02-20 | The **only** open issue in the repo as of 2026-10-01 (`gh issue list --state open --limit 60` returned this single row). Not workspace-specific. |

### 4.2 The version-skew gotcha `ume` actually has

**[community-reported]** [`#938`](https://github.com/invertase/melos/issues/938):

> The docs currently suggest: adding `melos` to the `dev_dependencies` of the workspace root, and running `dart pub global activate melos`. This creates a contradiction, as `melos` installed via `dart pub global activate melos` may not be the same version as the one from `dev_dependencies` […] So my ask here is: which approach is the suggested one?

melos 8.0.0 addressed the *nested-invocation* half ([`#1031`](https://github.com/invertase/melos/issues/1031)) — **[observed in source]** `lib/src/command_runner.dart`:

```dart
List<String> _resolveMelosCommand(LaunchContext context) {
  if (context.localInstallation == null) {
    return defaultMelosCommand;
  }
  return ['dart', 'run', 'melos:melos'];
}
```

So when a **local** installation is detected (melos in `dev_dependencies`), nested `melos` calls inside scripts resolve to `dart run melos:melos` — the pinned version. But **[observed empirically]** on this machine the globally activated melos **is** 8.9.0 (`~/.pub-cache/global_packages/melos`, snapshot `melos.dart-3.13.4.snapshot` via `~/.pub-cache/bin/melos`), which happens to match the pin. **If a contributor's global melos diverges from `^8.9.0`, the `ume` workspace can be driven by two different melos versions.** Prefer `dart run melos:melos <cmd>` (or a `melos` alias to it) over the bare global `melos`.

### 4.3 "melos exec runs in the wrong directory" — **it does not; it is by design**

**[observed in source]** — `_execForAllPackages` → `workingDirectory: package.path`. Each package command runs with cwd = that package.

**[community-reported]** [`#918`](https://github.com/invertase/melos/issues/918) is a user asking for the opposite (*"How to make melos run the command from the root of the workspace?"*) after hitting a Flutter `uses-material-design` mismatch when running `flutter test` per-package. The workaround is to run `melos exec` with `--` and an explicit path, not to change cwd. **There is no open issue about `melos exec` using a wrong directory** — my searches for `exec working directory` returned nothing relevant.

### 4.4 What does **not** exist

- **No melos issue about `"No workspace packages matching"`.** `gh search issues --repo invertase/melos "No workspace packages matching"` returns **0 results**. That string is **pub's** error (`dart-lang/pub lib/src/package.dart`), so its home is `dart-lang/pub` — see the companion doc §4.
- **No melos issue about `.dart_tool` / `package_config.json` conflicts between melos and workspaces.** Searches for `.dart_tool` returned only 11 pre-workspace-era issues (2020–2024), none about workspace-root `.dart_tool`.
- **No melos issue about a "double `pub get`."** Searches for `pub get twice` and `publish workspace` return nothing.

---

## 5. Real-world repos using both (with pubspec evidence)

### 5.1 `invertase/melos` itself — the reference implementation

**[observed in source]** — `pubspec.yaml` at the melos repo root, verbatim:

```yaml
name: melos_workspace
repository: https://github.com/invertase/melos
workspace:
  - packages/conventional_commit
  - packages/melos

environment:
  sdk: ^3.9.0

# This allows us to use melos on itself during development.
executables:
  melos: melos_dev

dev_dependencies:
  melos:
    path: packages/melos
  path: ^1.9.0
  yaml: ^3.1.3

melos:
  ignore:
    - packages/melos_flutter_deps_check
  categories:
    all:
      - packages/*

  command:
    bootstrap:
      environment:
        sdk: ^3.9.0
      dependencies:
        ansi_styles: ^0.3.2+1
        ...
```

Key points:
- Name is `melos_workspace`; **no `publish_to: none`** (it is never published anyway, and the root is not a member).
- **`melos:` config is in the root `pubspec.yaml`** — not `melos.yaml`. **No `melos.yaml` exists** at the root. **[observed in source]** `ls melos.yaml` → absent.
- `useRootAsPackage` is **absent** → defaults to `false`.
- Members declare `resolution: workspace`: `packages/melos/pubspec.yaml` line 10 and `packages/conventional_commit/pubspec.yaml` line 6 both have `resolution: workspace`. **[observed in source]**
- Root uses an **explicit two-element `workspace:` list**, not a glob. Consistent with the "globs that can vanish are fragile" rule from the companion doc.
- Publishing: `.github/workflows/release-publish.yml` delegates to `bluefireteam/melos-action@v3` with `publish: true`; that action runs `melos publish -y --dry-run` / `melos publish`. **[observed in source]** — melos's own publish workflow:

```yaml
      - uses: bluefireteam/melos-action@v3
        with:
          publish: true
```

**This is the single strongest piece of evidence for Q1 + Q2:** the melos maintainers run melos on a pub workspace, with the config in the root pubspec and `useRootAsPackage` unset.

### 5.2 `flame-engine/flame` — large Flutter monorepo, virtual root

**[observed empirically]** — root `pubspec.yaml`:

```yaml
name: _
repository: https://github.com/flame-engine/flame
workspace:
  - doc/flame/examples
  - doc/tutorials/**/app
  - packages/**
  - examples
  - examples/games/**

environment:
  sdk: ">=3.12.0 <4.0.0"

dev_dependencies:
  melos: ^8.1.0

melos:
  command:
    version:
      branch: main
      releaseUrl: true
      includeCommitId: true
      linkToCommits: true

    bootstrap:
      environment:
        sdk: ">=3.12.0 <4.0.0"
        flutter: ">=3.44.0"
      dependencies: ...
    publish:
      hooks:
        pre: melos devtools-build
  scripts: ...
```

- Root named literally `_` (**the same placeholder the official Dart doc uses** → confirms the "virtual root" pattern is upstream-blessed). No `publish_to` — and `_` is never published.
- **`melos:` in the root pubspec; no `melos.yaml`.**
- Members: `packages/flame/pubspec.yaml` starts with `name: flame` then `resolution: workspace` on **line 2**. **[observed empirically]**
- Publishing: `.github/workflows/release-publish.yml` → `bluefireteam/melos-action@v3` with `publish: true, create-release: true`. **[observed empirically]**

### 5.3 `simolus3/drift` — Dart monorepo with a deliberate `publish:` hook

**[observed empirically]** — root `pubspec.yaml`:

```yaml
name: drift_workspace
publish_to: none
environment:
  sdk: ^3.6.0
workspace:
  - drift
  - drift_dev
  - drift_sqflite
  - drift_flutter
  - sqlparser
  - extras/benchmarks
  ...
  - examples/app
  - examples/migrations_example
  ...
dev_dependencies:
  melos: ^8.3.0

dependency_overrides:
  test_api: ^0.7.11

melos:
  name: drift
  repository: https://github.com/simolus3/drift
  scripts:
    test:
      exec:
        command: dart test
        concurrency: 1
      packageFilters:
        dependsOn: test
        ignore: drift_postgres
```

- **`publish_to: none` on the root** + explicit `useRootAsPackage` absent.
- `melos:` in root pubspec, **no `melos.yaml`**.
- Member `drift_dev/pubspec.yaml` has `resolution: workspace` (line 10). **[observed empirically]**
- **Publishing is NOT via melos.** `.github/workflows/publish.yml` triggers on `<pkg>-<version>` tags and runs `dart pub lish -f` with `working-directory: drift_dev` per package, job-by-job. **[observed empirically]** — the clearest existing example of the **per-package-tag** strategy `ume` already uses.

### 5.4 `bluefireteam/dashbook` — melos config in the root pubspec, `useRootAsPackage: true`

**[observed empirically]** — root `pubspec.yaml`:

```yaml
name: dashbook
version: 0.1.19
environment:
  sdk: ">=3.13.0 <4.0.0"
  flutter: ">=3.47.0"

workspace:
  - example

dev_dependencies:
  flutter_test:
    sdk: flutter
  melos: ^8.9.0
  mocktail: ^1.0.5
  very_good_analysis: ^11.0.0

melos:
  useRootAsPackage: true
  command:
    version:
      branch: main
      releaseUrl: true
      includeCommitId: true
      linkToCommits: true
  scripts:
    analyze:
      run: melos exec -- dart analyze --fatal-infos .
```

- **This is the "root package IS the published package" variant**: `dashbook` itself is published *from the root*, so it sets `useRootAsPackage: true`, and `example/` is a member of the root's own workspace list.
- `melos.yaml` absent (API returns 404).
- **[observed empirically]** the published `dashbook-0.1.19` archive **does** contain `workspace: [example]` **and** `melos:` in its pubspec, **and** contains 33 `example/` entries. So it publishes its example and the `workspace:` field leaks — the same class of leak as `ume 2.0.8`, just **benign here** because `example/` is present in the archive.
- **Takeaway for `ume`:** `useRootAsPackage: true` is only appropriate if the root package is meant to be published. `ume`'s root is `publish_to: none`, so `false` is right.

### 5.5 `appsup-dart/openid_client` — `useRootAsPackage: true`, plain Dart

**[observed empirically]** — root pubspec has `dev_dependencies: melos: ^7.0.0` and:

```yaml
melos:
  useRootAsPackage: true
  ide:
    intellij: false
  command:
    version:
      linkToCommits: true
      workspaceChangelog: false
  scripts:
    preversion:
      exec: dart test -j 1
```

No `workspace:` key at all — this is the **single-package** use of melos (documented in melos's own getting-started), not a monorepo. Published `openid_client-0.4.10+2` carries `melos:` in its pubspec.

### 5.6 Repos checked that do **NOT** use both

Cheap root-pubspec probe (`gh api repos/<r>/contents/pubspec.yaml`):

| repo | root `workspace:`? | `melos`? | note |
|---|---|---|---|
| `invertase/flutterfire` | **no** | yes | still `melos.yaml`-era / no native workspace at root |
| `fluttercommunity/plus_plugins` | **no** | yes | no native workspace |
| `felangel/bloc` | — | — | **no root `pubspec.yaml`** (monorepo via subdirectories/`melos.yaml`) |
| `VeryGoodOpenSource/very_good_cli` | no | **no** | neither |
| `rrousselGit/riverpod` | **yes** | **no** | pure pub workspace, no melos |
| `Baseflow/flutter-permission-handler` | **yes** | **no** | pure pub workspace, no melos |
| `dart-lang/tools` | — | — | no root pubspec |
| `dart-lang/http` | — | — | no root pubspec |
| `dart-lang/core` | — | — | no root pubspec |

**Interpretation:** among the repos checked, **the ones that use workspaces at all either go all-in on melos (`melos`, `flame`, `drift`) or skip melos entirely (`riverpod`, `permission_handler`).** There is no widely-used repo that uses *both* in a half-hearted way — the ecosystem has converged on "melos config lives in the root pubspec, root is virtual."

### 5.7 Search coverage (so the reader can judge exhaustiveness)

Every command below was run; counts are as returned.

```
gh search issues --repo invertase/melos "workspace"                        → 60 results
gh search issues --repo invertase/melos "resolution: workspace"            → 10 results
gh search issues --repo invertase/melos "pub workspace"                    → (subset of above)
gh search issues --repo invertase/melos "No workspace packages matching"   → 0 results
gh search issues --repo invertase/melos "bootstrap workspace"              → 0 results
gh search issues --repo invertase/melos "publish workspace"                → 0 results
gh search issues --repo invertase/melos "resolution"                       → 10 results
gh search issues --repo invertase/melos "exec working directory"           → 0 results
gh search issues --repo invertase/melos ".dart_tool"                       → 11 results (all 2020–2024)
gh search issues --repo invertase/melos "pub get twice"                    → 0 results
gh search issues --repo invertase/melos "melos.yaml"                       → (see §2.1)
gh issue list --repo invertase/melos --state open --limit 60               → 1 result (#478)
gh search code --filename pubspec.yaml 'useRootAsPackage'                  → 40 results (all sampled)
gh search code --language yaml 'resolution: workspace melos useRootAsPackage' → 0 results
gh search code --language yaml 'workspace melos'                           → 4 results (all noise)
gh search code --language yaml 'melos workspace resolution'                → 0 results
gh search issues --repo dart-lang/pub "resolution: workspace"              → 20 results
```

Note: GitHub code search does **not** index YAML keys across files in a single query, so `melos:` + `workspace:` in the *same* file could not be found by code search. I worked around this by probing known monorepos individually (§5.1–5.6) and by downloading published archives (§3.2). **The repo list in §5 is therefore a curated primary-source sample, not an exhaustive census** — see §7.

---

## 6. Recommended design for a melos+workspace monorepo that publishes members

The following is derived from the evidence above and from the companion doc's pub-side findings. It matches what `ume`'s working tree already does.

### 6.1 Layout

```
ume/
  pubspec.yaml                    # virtual root: name ume_workspace, publish_to: none,
                                  # workspace: [...], dev_dependencies: melos, melos: {...}
  melos.yaml                      # ← DELETE THIS IF PRESENT (ignored since 7.0.0)
  example/                        # member of the ROOT's workspace, never inside a published pkg
  docs/research/
  packages/
    ume/                          # published (façade); resolution: workspace; NO workspace: key
      pubspec.yaml
      lib/…
      CHANGELOG.md
      .pubignore
    ume_core/                     # published; resolution: workspace
    ume_kit_*/                    # published; resolution: workspace
```

**Rules (each traceable to evidence):**

| # | Rule | Why |
|---|---|---|
| R1 | The root is **never published** (`publish_to: none`, no `lib/`). | The root's `workspace:` list is the only thing that can dangle in a consumer's pub cache. Companion doc §1.3, §2.2. |
| R2 | Published members carry **`resolution: workspace`** and **never** a `workspace:` key. | Verified harmless (`melos 8.9.0`, `drift_dev 2.35.1`, `flame 1.38.2`, `ume_core 2.0.3`). A `workspace:` key is fatal if its members are stripped. |
| R3 | `melos:` config lives in the **root `pubspec.yaml`**; there is **no `melos.yaml`**. | melos ≥7 only reads the root pubspec. §2.1. |
| R4 | **`useRootAsPackage: false`** (or omit it — it is the default). | The root is virtual; `true` is only for single-package or root-app layouts. §2.2. |
| R5 | Drop **`runPubGetInParallel`** — it is dead config. | §2.3. |
| R6 | Never `.pubignore` a path that appears in the `workspace:` list of a **published** pubspec. | Companion doc §3. Currently satisfied: the root is `publish_to: none`. |
| R7 | Prefer **explicit `workspace:` paths over globs** whose match count can silently reach zero. | `packages/*/example` currently matches exactly 1 dir. A glob matching 0 → `dart pub get` hard-fails. Companion doc §2.2. |
| R8 | Drive melos as **`dart run melos:melos …`**, not the bare global `melos`. | Avoids version skew between the `^8.9.0` pin and a contributor's global activation. §4.2. |
| R9 | Publish **per package from its own directory** (`dart pub -C packages/<x> publish`), triggered by a `<pkg>-v<version>` tag. | Avoids `melos publish`'s all-or-nothing sweep, `melos version`'s constraint-corruption bug (#1039) and the pre-publish 403 (#1083). §3.3. This is `ume`'s current `.github/workflows/publish.yml` and is what `drift` does. |

### 6.2 Two concrete fixes for the current working tree

**(a) `packages/*/example` → explicit path.** The root currently has:

```yaml
workspace:
  - example
  - packages/*
  - packages/*/example
```

`packages/*/example` matches exactly one directory — `packages/ume_kit_shared_preferences/example` — and the commit history shows the `shared_preferences` example was *just* moved (`5dfdc42 refactor(shared_preferences): move demo scaffold into example/`). If it moves again the glob matches nothing and **`dart pub get` fails with `No workspace packages matching`**. Replace with the literal path:

```yaml
workspace:
  - example
  - packages/*
  - packages/ume_kit_shared_preferences/example
```

**(b) Confirm no `melos.yaml` exists.** `ume` has none at the root today (verified) — good, and it should stay that way. If one is ever added, it will be silently ignored while looking authoritative.

### 6.3 What `ume` gets for free by keeping this shape

- **One `pub get`, at the root** — `melos bootstrap` confirms this empirically (§1.3). No per-package lockfiles, no `pubspec_overrides.yaml`, no `.dart_tool` in members beyond a `workspace_ref.json` marker.
- **`melos exec` works per-package** with the correct cwd (§4.3), so `melos run test` / `melos run analyze` behave as written.
- **`melos:` scripts, filtering and category config all work** — they read the root pubspec's `melos:` map.
- **Publishing stays exactly as it is** — `dart pub -C packages/<x> publish` is unaffected by melos, and members ship a harmless `resolution: workspace` (verified against `ume_core 2.0.3`, which already does).

---

## 7. Open questions / unconfirmed

1. **Is `melos.yaml` truly *rejected*, or merely ignored?** I verified empirically that melos 8.9.0 ignores it (§2.1). **[observed empirically]** — but I did not find an explicit `if (melos.yaml exists) throw` anywhere, so a *hard* rejection is unconfirmed; it is silent ignoring.
2. **`runPubGetInParallel` removal timeline.** It is unreferenced in `lib/` on `main` **[observed in source]**, but I did not bisect when it stopped being read. It may have been dead since #822 (2025-01-07) rather than since 7.0.0. **Unconfirmed.**
3. **Whether `melos publish` would succeed against `ume`'s 20-publishable-package workspace end-to-end.** Not attempted — it would consume real pub.dev quota and mutate git state. The all-or-nothing sweep and `#1039`/`#1083` are documented risks, not reproduced here. **Unconfirmed.**
4. **Exhaustive census of repos using both melos and pub workspaces.** GitHub code search cannot query "file contains key A and key B" across YAML, and `gh search code` returned 0 for every combined query (§5.7). §5 is a curated primary-source sample of the well-known monorepos, not a census. **Unconfirmed / non-exhaustive.**
5. **`melos version` in `fixed` mode + `workspaceTag` for `ume`.** `command/version/mode: fixed` + `workspaceTag: true` (added in 7.6.0, [`#1073`](https://github.com/invertase/melos/issues/1073)) would produce a single `vX.Y.Z` tag for the whole workspace — which happens to match `ume`'s existing plain `v2.0.8` tags. But `ume` versions independently, so this is likely *not* what it wants. **Unconfirmed as a recommendation.**
6. **Does `melos exec` inherit the workspace-root `.dart_tool`?** Structurally it should — the single `package_config.json` at the root serves every member — but I did not run `melos run test` to confirm a member's test can resolve its siblings. §1.3 shows the artifacts exist; end-to-end execution was not exercised. **Unconfirmed.**
7. **The melos repo's own `resolution: workspace` + `melos:` coexistence in the *published* archive.** `melos 8.9.0`'s published archive contains `resolution: workspace` (verified). Whether it ever contained a `workspace:` key, I did not check for older versions. **Unconfirmed for 7.0.0–8.8.0.**

---

## References

**melos source — `invertase/melos` (cloned `--depth 1`, HEAD `073b15060c5269496b065aa5629008bb1b5a2bfe`, 2026-09-28)**
- `pubspec.yaml` (repo root) — the reference melos+workspace config — <https://github.com/invertase/melos/blob/main/pubspec.yaml>
- `packages/melos/pubspec.yaml:10` — `resolution: workspace` — <https://github.com/invertase/melos/blob/main/packages/melos/pubspec.yaml#L10>
- `packages/melos/lib/version.g.dart` — `melosVersion = '8.9.0'`
- `packages/melos/lib/src/workspace_config.dart` — `useRootAsPackage` default `false`; `melos:` read from `melosYaml`; `workspace:` read from `pubspecYaml`; `handleWorkspaceNotFound` / `_findRootPubspec` — <https://github.com/invertase/melos/blob/main/packages/melos/lib/src/workspace_config.dart>
- `packages/melos/lib/src/commands/bootstrap.dart` — `_runPubGetForWorkspace` (single root `pub get`), `runPubGetForPackage`, `_buildPubGetCommand`, `_writeWorkspaceDependencyOverrides` — <https://github.com/invertase/melos/blob/main/packages/melos/lib/src/commands/bootstrap.dart>
- `packages/melos/lib/src/commands/publish.dart` — `_performPublishing`, `_getLatestPublishedVersionForPackages`, `unpublishedPackages` — <https://github.com/invertase/melos/blob/main/packages/melos/lib/src/commands/publish.dart>
- `packages/melos/lib/src/commands/exec.dart` — `workingDirectory: package.path`
- `packages/melos/lib/src/commands/version.dart` — `_setPubspecVersionForPackage`, `_rewriteDependencyVersionAtPath`, `_rewriteGitRefAtPath`
- `packages/melos/lib/src/command_configs/bootstrap.dart` — `runPubGetInParallel` (parsed, never read)
- `packages/melos/lib/src/workspace.dart` — `allPackages` gated on `useRootAsPackage`
- `packages/melos/lib/src/command_runner.dart` — `_resolveConfig`, `_resolveMelosCommand`
- `packages/melos/lib/src/common/git.dart` — `gitTagForVersion`, root-package tag rule
- `packages/melos/lib/src/common/utils.dart` — `pubCommandExecArgs`, `isPubSubcommand`
- `packages/melos/CHANGELOG.md` — 2025-08-15 (`v7.0.0`), 2025-08-21 (`v7.1.0`), 2026-01-27 (`v7.4.0`), 2026-06-23 (`v8.0.0`), 2026-07-03 (`v8.1.0`), 2026-09-21 (`v8.9.0`)
- `.github/workflows/release-publish.yml` — `bluefireteam/melos-action@v3` `publish: true`
- `melos.yaml.schema.json` — shipped, unreferenced by `lib/`

**melos documentation**
- Configuration overview (incl. `useRootAsPackage`, `discoverNestedWorkspaces`, `command/bootstrap`, `command/version`, `command/publish`) — <https://melos.invertase.dev/configuration/overview> · source <https://github.com/invertase/melos/blob/main/docs/configuration/overview.mdx>
- Migrations (6.x→7.x, 7.x→8.0.0) — <https://melos.invertase.dev/guides/migrations> · source <https://github.com/invertase/melos/blob/main/docs/guides/migrations.mdx>
- Getting started (workspace setup, `resolution: workspace`, single-package) — <https://melos.invertase.dev/getting-started>
- Bootstrap command — <https://melos.invertase.dev/commands/bootstrap>
- Publish command — <https://melos.invertase.dev/commands/publish>
- Automated releases — <https://melos.invertase.dev/guides/automated-releases>
- README (migration steps, "What does a Melos workspace look like?") — <https://github.com/invertase/melos/blob/main/README.md>

**melos issues / PRs**
- <https://github.com/invertase/melos/issues/747> — request: pub workspaces (closed)
- <https://github.com/invertase/melos/pull/816> — feat!: Migrate to use the Pub workspaces feature (merged)
- <https://github.com/invertase/melos/pull/822> — fix: Only run pub get in workspace root (merged)
- <https://github.com/invertase/melos/pull/832> — feat!: Remove melos.yaml in favor of the root pubspec.yaml (merged)
- <https://github.com/invertase/melos/pull/927> — feat: Add useRootAsPackage (merged)
- <https://github.com/invertase/melos/issues/893> — request: Melos for non-monorepos (closed)
- <https://github.com/invertase/melos/issues/917> — dart workspace includes assets from other apps (closed)
- <https://github.com/invertase/melos/issues/918> — How to make melos run from the workspace root (closed)
- <https://github.com/invertase/melos/issues/919> — Workspace Dependency Boundaries Not Enforced (closed)
- <https://github.com/invertase/melos/issues/920> — bootstrap filtering ignored in v7 (closed)
- <https://github.com/invertase/melos/issues/925> — Repository root as a workspace package (closed)
- <https://github.com/invertase/melos/issues/930> — Null check operator, nested workspaces (closed)
- <https://github.com/invertase/melos/issues/931> — request: support non-workspace packages (closed)
- <https://github.com/invertase/melos/issues/934> — bootstrap fails on environment constraint upgrade (closed)
- <https://github.com/invertase/melos/issues/938> — melos in dev_dependencies vs `$PATH` (closed)
- <https://github.com/invertase/melos/issues/968> — recursively discover packages in nested workspaces (7.4.0)
- <https://github.com/invertase/melos/issues/1003> — `--order-dependents` regression in 7.4.0 (closed)
- <https://github.com/invertase/melos/issues/1039> — melos version corrupts quoted range constraints (closed, unfixed on `main`)
- <https://github.com/invertase/melos/issues/1057> — `--yes` ignored in `melos version -V` (closed)
- <https://github.com/invertase/melos/issues/1062> — avoid cascading releases (closed → `smartDependents`)
- <https://github.com/invertase/melos/issues/1073> — `workspaceTag` option (7.6.0)
- <https://github.com/invertase/melos/issues/1083> — pre-publish registry read 403 (closed)
- <https://github.com/invertase/melos/issues/1089> — detect Flutter packages via workspace dep graph (8.9.0)
- <https://github.com/invertase/melos/issues/478> — only open issue, 2023-02-20

**Dart / pub**
- Pub workspaces — <https://dart.dev/tools/pub/workspaces> (page last updated 2026-05-15; glob support & nested workspaces documented)
- `dart-lang/pub` `lib/src/package.dart` — `validateWorkspace`, `No workspace packages matching` — <https://github.com/dart-lang/pub/blob/main/lib/src/package.dart>
- `dart-lang/pub` `lib/src/pubspec.dart` — `workspace` / `resolution` parsing; `Resolution { external, workspace, local, none }`
- `dart-lang/pub` `lib/src/language_version.dart` — `firstVersionWithWorkspaces = 3.5`, `firstVersionWithWorkspaceGlobs = 3.11`
- `dart-lang/pub` `lib/src/entrypoint.dart` — workspace-root discovery
- Dart SDK `CHANGELOG.md` — <https://github.com/dart-lang/sdk/blob/main/CHANGELOG.md>
- pub.dev API — <https://pub.dev/api/packages/melos> · archives: <https://pub.dev/api/archives/melos-8.9.0.tar.gz>, <https://pub.dev/api/archives/drift_dev-2.35.1.tar.gz>, <https://pub.dev/api/archives/flame-1.38.2.tar.gz>, <https://pub.dev/api/archives/ume-2.0.8.tar.gz>, <https://pub.dev/api/archives/ume_core-2.0.3.tar.gz>, <https://pub.dev/api/archives/dashbook-0.1.19.tar.gz>, <https://pub.dev/api/archives/openid_client-0.4.10%2B2.tar.gz>

**Repos inspected via `gh api`**
- <https://github.com/flame-engine/flame/blob/main/pubspec.yaml> · <https://github.com/flame-engine/flame/blob/main/packages/flame/pubspec.yaml>
- <https://github.com/simolus3/drift/blob/master/pubspec.yaml> · <https://github.com/simolus3/drift/blob/master/drift_dev/pubspec.yaml> · `.github/workflows/publish.yml`
- <https://github.com/bluefireteam/dashbook/blob/main/pubspec.yaml>
- <https://github.com/appsup-dart/openid_client/blob/master/pubspec.yaml>
- <https://github.com/bluefireteam/melos-action/blob/main/action.yml>
- Probes (no root pubspec or no workspace): `invertase/flutterfire`, `fluttercommunity/plus_plugins`, `felangel/bloc`, `VeryGoodOpenSource/very_good_cli`, `rrousselGit/riverpod`, `Baseflow/flutter-permission-handler`, `dart-lang/tools`, `dart-lang/http`, `dart-lang/core`

**Local reproductions (this investigation)**
| path | what it demonstrates |
|---|---|
| `/tmp/mstest` | 2-member workspace (`ws_root` + `pkg_a` + `pkg_b`), melos 8.9.0, Dart 3.13.4. `melos list` → members from `pubspec.yaml`. `melos bootstrap` → **one** root `pub get`, no `pubspec_overrides.yaml`, member `.dart_tool/pub/workspace_ref.json` only. Legacy `melos.yaml` present → ignored; its script → `NoScriptException`. |
| `/tmp/melosres/melos` | `invertase/melos` @ `073b1506` (depth 1) |
| `/tmp/pubcache` | throwaway `PUB_CACHE` used because `~/.pub-cache` writes are blocked by the sandbox |
| `/tmp/pubarch/` | downloaded pub.dev archives for the `resolution:` / `workspace:` comparison (§3.2) |
