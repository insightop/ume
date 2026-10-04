# Pub workspaces × publishing: why `ume 2.0.8` breaks downstream consumers

**Investigated:** 2026-10-01 · **Repo:** [insightop/ume](https://github.com/insightop/ume) · **SDK used for reproduction:** Dart 3.13.4 / Flutter 3.47.5
**pub source inspected:** [`dart-lang/pub`](https://github.com/dart-lang/pub) @ `90bb91c90cc8edc0d32693f16a4075be6b1e4fce` (2026-10-01)

Primary sources only: `dart.dev` docs, the `dart-lang/pub` source tree, the Dart SDK `CHANGELOG.md`, GitHub issues/PRs on `dart-lang/pub` and `flutter/flutter`, and the actual archives served by `pub.dev`. Each claim is marked **[documented]**, **[observed in source]**, **[observed empirically]**, or **[inferred]**.

---

## TL;DR

1. **`dart pub publish` never rewrites `pubspec.yaml`.** There is no stripping step for `workspace:` or `resolution:`. The uploaded archive contains the pubspec byte-for-byte as it appears in your working tree. **[observed in source]** — `lib/src/command/lish.dart` only reads the pubspec and tars `entrypoint.workPackage.listFiles()`; no serialization path exists.
2. **The published `ume` 2.0.8 pubspec still contains `workspace: [example, packages/*]`, and the archive contains no `example/`.** **[observed empirically]** — reproduced by downloading `https://pub.dev/api/archives/ume-2.0.8.tar.gz`.
3. **A dangling workspace glob is a hard `fail()` in pub — and the same `Package.load` code path is used to read a dependency's pubspec from the pub cache.** **[observed in source]** `lib/src/package.dart:162-247`, message at `package.dart:235`.
4. **Exact error message** (reproduced verbatim):
   ```
   No workspace packages matching `example`.
   That was included in the workspace of `/Users/…/.pub-cache/hosted/pub.dev/ume-2.0.8/pubspec.yaml`.
   ```
   **[observed empirically]** — the string `"No workspace packages matching"` is **real**; stack trace points at `package.dart:228 → entrypoint.dart:287 Entrypoint._createPackageGraph`.
5. **`dart pub get` does *not* fail.** Resolution uses the pubspec fetched from the server, not `Package.load`. The failure only appears on commands that build a `PackageGraph` by loading every `package_config.json` entry from disk: **`dart pub deps` (exit 1)**, and any `dart run` that must resolve a transitive executable. **[observed empirically]**
6. **`.pubignore` is applied at archive time only.** `dart pub publish` validates against the working tree (where `example/` exists), then tars `listFiles()` (where `.pubignore` has already removed it). Nothing re-validates the archive against its own pubspec. This is exactly how 2.0.8 shipped. **[observed in source + empirically]**
7. **Counter-intuitively, a *stale* `resolution: workspace` alone is harmless.** `ume_core 2.0.3` publishes `resolution: workspace` with no `workspace:` field, and consumers are fine. **[observed empirically]** The bug is specifically a `workspace:` list whose members are absent from the archive.
8. **The officially recommended layout is a virtual root package with `publish_to: none`, members as workspace members, and the shared `example/` *outside* the root package's own published contents.** This is what `dart-lang/source_gen`, `dart-lang/test`, `riverpod`, `drift`, and the `dart.dev` workspaces doc all do; `eventide` converged on it after hitting this exact bug. **[documented + observed in repos]**
9. **No upstream `dart-lang/pub` issue exists for this specific class of bug** (published archive with dangling workspace globs). The closest are `dart-lang/pub#4649` (open, asks for exactly this guidance) and the third-party `sncf-connect-tech/eventide#124`. **pub has no guard-rail here — the publisher is entirely responsible.** **[observed: search returned no matching primary issue]**
10. **⚠️ The repo's current uncommitted fix is sound**, but the root's `workspace: [example, packages/*, packages/*/example]` contains a glob — `packages/*/example` — that currently matches **exactly one** directory. It works today, but deleting that one directory turns it into the same hard failure on the maintainer's own machine. See §6.

---

## 1. Publish-time semantics of `workspace:` (with exact doc quotes + SDK versions)

### 1.1 Does `pub publish` strip `workspace:` / `resolution: workspace`?

**No. It never rewrites the pubspec.** Three independent lines of evidence:

**(a) Source inspection — there is no stripping code.**
The publish path in `dart-lang/pub@90bb91c` is:

- `lib/src/command/lish.dart:334` — `final filesAndDirs = entrypoint.workPackage.listFiles(includeDirs: true);`
- `lib/src/command/lish.dart:366` — `createTarGz(filesAndDirs, baseDir: entrypoint.workPackage.dir)`

The archive is a straight tar of the files on disk. I grepped the entire publish + validator surface for any pubspec serialization:

```
$ rg -n "toJson|encode\(|writeTextFile.*pubspec|pubspecYamlFilename" \
      lib/src/command/lish.dart lib/src/validator/*.dart lib/src/validator.dart
(no matches)
```
**[observed in source]**

**(b) Empirical — the published archive is byte-identical to the git commit.**
The `ume` 2.0.8 pubspec in the archive was diffed against `pubspec.yaml` at the 2.0.8 release commit `f9bf6f1`:

```
$ diff <(git show f9bf6f1:pubspec.yaml) <extracted>/pubspec.yaml
(IDENTICAL)
```
**[observed empirically]**

**(c) Every upstream workspace member on pub.dev ships `resolution: workspace`.**

| package | published version | field present in hosted pubspec |
|---|---|---|
| `source_gen` | 4.3.0 | `resolution: workspace` |
| `test` | 1.32.0 | `resolution: workspace` |
| `riverpod` | 3.4.3 | `resolution: workspace` |
| `drift` | 2.35.1 | `resolution: workspace` |
| `ume_core` | 2.0.3 | `resolution: workspace` |
| `ume` | 2.0.8 | `workspace: [example, packages/*]` |

**[observed empirically]** — downloaded from `https://pub.dev/api/archives/<pkg>-<ver>.tar.gz`.

### 1.2 SDK versions for the `workspace:` feature

**[observed in source]** — `dart-lang/pub@90bb91c`, `lib/src/language_version.dart`:

```dart
bool get supportsWorkspaces     => this >= firstVersionWithWorkspaces;      // line 66
bool get supportsWorkspaceGlobs => this >= firstVersionWithWorkspaceGlobs;  // line 68

static const firstVersionWithWorkspaces     = LanguageVersion(3, 5);   // line 114
static const firstVersionWithWorkspaceGlobs = LanguageVersion(3, 11);  // line 115
```

**[observed in source]** — `lib/src/pubspec.dart:71-76`:

```dart
if (workspaceNode != null && !languageVersion.supportsWorkspaces) {
  _error(
    '`workspace` and `resolution` requires at least language version '
    ...
```

**[documented]** — Dart SDK `CHANGELOG.md`, `## 3.6.0` (line 2233), `#### Pub` (line 2323):

> **Support for workspaces.** This allows you to develop and resolve multiple packages from the same repo together. See https://dart.dev/go/pub-workspaces for more info.

*Note:* the constant says language version `3.5`, the SDK changelog first announces it under `3.6.0`, and the doc example uses `sdk: ^3.6.0`. Treat "Dart 3.5/3.6+" as the practical floor; the exact first shipping SDK is **unconfirmed** (the `## 3.5.0` section of the changelog contains no `workspace` mention).

**[documented]** — Dart SDK `CHANGELOG.md`, `## 3.11.0` (line 775), `#### Pub` (line 851):

> **"Glob" support for pub workspaces.**
> Now to include all packages inside `pkgs/` in the workspace, simply write:
> ```yaml
> workspace:
>   - pkgs/*
> ```
> Supported if the Dart SDK constraint of the containing package is 3.11.0 or higher.

This is why `ume` 2.0.8 uses `sdk: ">=3.11.0 <4.0.0"` and a `packages/*` glob.

### 1.3 What the official documentation actually says

**[documented]** — <https://dart.dev/tools/pub/workspaces> (page last updated 2026-05-15):

> To create a workspace:
> Add a pubspec.yaml at the repository root directory with a `workspace` entry enumerating the paths to the packages of the repository (the workspace packages):
> ```yaml
> name: _
> publish_to: none
> environment:
>   sdk: ^3.6.0
> workspace:
>   - packages/shared
>   - packages/client_package
>   - packages/server_package
> ```

And, on publishing a member:

> Some pub commands, such as `dart pub add`, and `dart pub publish` operate on a "current" package. You can either change the directory, or use `-C` to point pub at a directory:
> ```
> $ dart pub -C packages/client_package publish
> # Same as
> $ cd packages/client_package ; dart pub publish ; cd -
> ```

**Key observation:** the canonical example uses `publish_to: none` on the root *and* member paths that are real subdirectories. The doc **does not** state whether the root's `workspace:` field survives publishing, and it **does not** warn about the dangling-glob failure mode. This documentation gap is precisely what `dart-lang/pub#4649` ("Dart workspaces clarification and documentation improvements", open since 2025-08-15) is about.

**Also:** there is no dedicated publish page to cite — `https://dart.dev/tools/pub/cmd/pub-publish` returns **HTTP 404** (verified 2026-10-01); the publish reference now lives at `https://dart.dev/tools/pub/cmd/pub-lish`. I checked its content and it contains **no** mention of workspaces.

---

## 2. The downstream failure mechanism

### 2.1 Exact error message

**[observed empirically]** — reproduced with `ume 2.0.8` as a hosted dependency (Dart 3.13.4):

```
$ dart pub deps
No workspace packages matching `example`.
That was included in the workspace of `/Users/bookshiyi/.pub-cache/hosted/pub.dev/ume-2.0.8/pubspec.yaml`.
$ echo $?
1
```

The reported message **"No workspace packages matching …"** is **real and exact**. Its source is:

**[observed in source]** — `lib/src/package.dart:234-238`:

```dart
          if (packages.isEmpty) {
            fail('''
No workspace packages matching `$workspacePath`.
That was included in the workspace of `${p.join(dir, 'pubspec.yaml')}`.$globHint
''');
          }
```

Stack trace confirming the call path (from `dart pub deps --verbose`):

```
ERR : No workspace packages matching `example`.
    | package:pub/src/package.dart 222      new Package.load.<fn>
    | package:pub/src/package.dart 228      new Package.load
    | package:pub/src/entrypoint.dart 287   Entrypoint._createPackageGraph
```

(`package.dart:222` / `:228` are the inner/outer `Package.load` frames inside the `.expand()` closure; the `fail()` itself is at `:234`.)

### 2.2 Trigger conditions

The mechanism is:

1. **`Package.load` resolves `pubspec.workspace` eagerly and fatally.** In the `factory Package.load(...)` at `lib/src/package.dart:162`, each entry in the `workspace:` list is expanded (`package.dart:177-241`). For a literal path (no glob wildcard), it checks `fileExists(pubspecPath)`; for a glob it expands and filters to directories containing a `pubspec.yaml`. If the resulting list is empty → `fail()`. **[observed in source]**
2. **`Package.load` is used to read *hosted* packages from the pub cache.** `lib/src/system_cache.dart:126-133`:
   ```dart
   Package load(PackageId id) {
     return Package.load(
       getDirectory(id),
       loadPubspec: Pubspec.loadRootWithSources(sources),
       expectedName: id.name,
     );
   }
   ```
3. **`Entrypoint._createPackageGraph()` calls it for *every* package in `package_config.json`.** `lib/src/entrypoint.dart:281-296`:
   ```dart
   Future<PackageGraph> _createPackageGraph() async {
     await ensureUpToDate(workspaceRoot.dir, cache: cache);
     final packages = {
       for (var packageEntry in packageConfig.packages)
         packageEntry.name: Package.load(
           packageEntry.resolvedRootDir(packageConfigPath),
           expectedName: packageEntry.name,
           loadPubspec: Pubspec.loadRootWithSources(cache.sources),
         ),
     };
   ```
   The consumer's own project is **not** a workspace — that is irrelevant. The *dependency* is loaded as if it were a workspace root, and its `workspace:` field is expanded against the pub-cache directory, where `example/` does not exist.

**Precise trigger matrix (all measured with `ume 2.0.8`, Dart 3.13.4):**

| Condition | Result |
|---|---|
| consumer is a workspace root | **not required** — plain non-workspace project fails identically |
| consumer runs pub from a subdirectory | **not required** — fails from the project root too |
| path dependency instead of hosted | **also fails** — reproduced with a local `path:` dep |
| `resolution: workspace` present but no `workspace:` field | **harmless** — `ume_core 2.0.3` works |
| a `workspace` glob matches **zero** directories | **hard failure** (also for `packages/*/example`-style nested globs) |
| an existing-but-empty directory matches | **fails too** — `.gitkeep` does not help ([confirmed independently](https://github.com/dip-develop/alteri-one/pull/5)) |

Commands swept against a consumer with a dangling-`workspace` dependency:

| command | exit | fails? |
|---|---|---|
| `dart pub get` | 0 | no |
| `dart pub get --offline` | 0 | no |
| `dart pub upgrade` / `--dry-run` | 0 | no |
| `dart pub downgrade --dry-run` | 0 | no |
| `dart pub upgrade --major-versions --dry-run` | 0 | no |
| `dart pub outdated` | 0 | no |
| `dart pub publish --dry-run` (consumer's own) | 65 | no (different validator errors) |
| `dart pub global activate -s path` | 0 | no |
| `dart analyze` | 0 | no |
| **`dart pub deps`** | **1** | **YES** |
| **`dart pub deps --json`** | **1** | **YES** |
| **`dart pub deps --no-dev`** | **1** | **YES** |
| `dart run bin/x.dart` (own entrypoint) | 0 | no |
| `dart run <transitive_pkg>:<exe>` | — | **would fail** — calls `(await entrypoint.packageGraph)` at `lib/src/executable.dart:62` |

**[observed empirically]**

> **Correction to the original report.** The claim "`dart run build_runner build` from a subdirectory fails" was **not reproduced**. Running `dart run <file>` from a subdirectory exited 0, and from a clean, non-workspace consumer `dart run` works. The reliable, deterministic symptom is **`dart pub deps` exiting 1**, plus `dart run` *of a transitive package's executable* (which is how `build_runner` would be reached if it were a transitive rather than direct dependency). Whether `dart run build_runner build` fails for a given consumer depends on how `build_runner` entered the dependency graph — **unconfirmed** for the general case.

### 2.3 Why this is not caught before publishing

The full reproduction of the original accident:

**Precondition (the repo's real state):** `.pubignore` (committed at `4384f8e`, extended at `5dfdc42`) excludes `example/` **and** — at `cf47660` — `packages/`:

```gitignore
example/
packages/          # ← present at cf47660, removed by 4384f8e
build/
coverage/
screenshots/
.github/
openspec/
```

**Reproduced end-to-end in `/tmp/wstest4/repro`:**

```
########## publish --dry-run (example/ EXISTS on disk, .pubignore hides it) ##########
Resolving dependencies...
Got dependencies!
Publishing repro 1.0.0 to https://pub.dev:
├── lib
│   └── repro.dart (<1 KB)
├── packages
│   └── kit
│       ├── lib
│       └── pubspec.yaml (<1 KB)
└── pubspec.yaml (<1 KB)

Total compressed archive size: <1 KB.
Validating package...
Package validation found the following error:
* You must have a LICENSE file in the root directory.
...
```

**`dart pub publish` emits no workspace warning, and no workspace error**, because at that moment `example/` is present on disk. The archive it produces omits `example/` — and `pubspec.yaml` inside it still declares `workspace: [example, …]`. **[observed empirically]**

Conversely, if the workspace directory is genuinely absent from disk, publish **refuses**:

```
$ dart pub publish --dry-run        # workspace: [example, packages/*] and example/ absent
No workspace packages matching `example`.
That was included in the workspace of `./pubspec.yaml`.
EXIT=1
```

**[observed empirically]**

**Conclusion [inferred]:** `ume 2.0.8` could be published only because `.pubignore` hid `example/` from the tarball *after* the working-tree validation had already passed. `dart pub publish --skip-validation` / `--force` are not required to explain it. There is **no** point in the pipeline where the produced archive is re-validated against its own pubspec.

---

## 3. `.pubignore` interaction

**Answer to the question as posed:** *No*, pub does **not** validate that workspace globs match directories when reading a pubspec from the **hosted pub cache** — it does the opposite: it **fails hard** when they don't match.

**[observed in source]** — `lib/src/package.dart:290-306` (doc comment on `listFiles`) and the `ignoreForDir` closure at `lib/src/package.dart:392-402`:

```dart
final pubIgnore = resolve('$dir/.pubignore');
final gitIgnore = resolve('$dir/.gitignore');
final ignoreFile = fileExists(pubIgnore) ? pubIgnore
                                         : (fileExists(gitIgnore) ? gitIgnore : null);
```

Key facts:

- **`.pubignore` is consumed only inside `Package.listFiles()`**, which is called from exactly one publish site: `lib/src/command/lish.dart:334`. It has no role in resolution, in `Package.load`, or in reading cached packages. **[observed in source]**
- **`.pubignore` takes precedence over `.gitignore` per directory**, and ignore files are collected from the **repo root downward** (`root = git.repoRoot(packageDir) ?? packageDir`, `package.dart:315`). This is why a root `.pubignore` containing `packages/` also hid `packages/` from *every* member's publish — and why the repo later added the comment *"pub 发布子包时会沿父目录向上读取本文件 … 否则子包发布会报 'The pubspec is hidden'"*.
- That error string is real: `lib/src/validator/pubspec.dart:22` — `'The pubspec is hidden, probably by .gitignore or pubignore.'` **[observed in source]**
- **Built-in defaults** (`package.dart:_basicIgnoreRules`) exclude dot-files, `pubspec.lock`, and `/pubspec_overrides.yaml`. `example/` is **not** excluded by default — the repo's own `.pubignore` comment is correct about this.

**Therefore:** nothing detects the inconsistency. The archive is self-contradictory — `pubspec.yaml` declares members that the tarball does not contain — and only the *consumer's* pub discovers it, at `dart pub deps` time.

---

## 4. Known upstream issues

Search method: `gh search issues` / `gh api search/issues` over `dart-lang/pub`, `flutter/flutter`, `dart-lang/pub-dev`, plus a global full-text search for the exact error string.

### 4.1 Directly on point

| repo | # | title | status | relevance |
|---|---|---|---|---|
| `dart-lang/pub` | [4649](https://github.com/dart-lang/pub/issues/4649) | Dart workspaces clarification and documentation improvements | **open** (created 2025-08-15, reopened) | **The closest upstream issue.** Filed by Shorebird; explicitly asks *"Is there a valid case for allowing developers to include library implementations directly within a workspace root?"* and requests layout guidance. No maintainer resolution recorded yet. |
| `dart-lang/pub` | [4393](https://github.com/dart-lang/pub/issues/4393) | `dart pub unpack` fails with dependency published from a workspace | **closed / completed** (2024-10-07) | Same *family*: a workspace member's `resolution: workspace` breaks a consumer-side tool because there is no workspace root above it in the cache. Fixed for `unpack`; the dangling-`workspace:` variant was **not** covered. |
| `dart-lang/pub` | [4809](https://github.com/dart-lang/pub/issues/4809) | \[feature] Workspaces: pre-publish resolution of sibling package paths → versions | **closed / not planned** (2026-04-27) | Explicitly about publishing from workspaces. Maintainers declined an automated `dart pub workspace publish`. |
| `dart-lang/pub` | [4388](https://github.com/dart-lang/pub/issues/4388) | Ability to publish package by name on workspace environments | **closed / not planned** (2024-09-24) | Maintainer position: publishing is done **per member directory** (`dart pub -C packages/x publish`). |
| `dart-lang/pub` | [4629](https://github.com/dart-lang/pub/issues/4629) | could 'pub publish' pick up the LICENSE file from workspace root? | **closed / not planned** (2025-08-12) | Confirms pub does **not** reach up out of the package directory when publishing — consistent with "the root pubspec is nobody's business at publish time". |
| `dart-lang/pub` | [4252](https://github.com/dart-lang/pub/issues/4252) | Confirm `pub publish` works in workspace. | **closed / completed** (2024-05-24) | The original "does publishing a workspace member work?" ticket. |
| `sncf-connect-tech/eventide` | [124](https://github.com/sncf-connect-tech/eventide/issues/124) | Published archive omits `example/more-complex/*` | **closed** (2026-09-24) | **The exact same bug in the wild — independently reported 8 days before this investigation.** Reporter hit `No workspace packages matching example/more-complex/full-permission. That was included in the workspace of …/eventide-2.4.0/pubspec.yaml.` The maintainer replied: *"I might have broken this with the .pubignore I created"*, and the recommendation from the reporter: *"I think the package itself should be placed in a subfolder, and the root pubspec should only manage the workspace."* Fixed in 2.4.1. |

### 4.2 Adjacent / useful context

| repo | # | title | status | relevance |
|---|---|---|---|---|
| `dart-lang/pub` | [4674](https://github.com/dart-lang/pub/issues/4674) | `Failed to parse … package_graph.json: dependencies for 'example' missing` | **closed/completed** 2025-09-25 | `example/` **as a workspace member**: `flutter pub get` crashed when a member's `example/` had not been resolved. Fixed by [PR #4679](https://github.com/dart-lang/pub/pull/4679), shipped in **Dart 3.9.4** — `dart pub get --example` now resolves `example/` folders *in the entire workspace*. |
| `dart-lang/pub` | [4718](https://github.com/dart-lang/pub/issues/4718) | `pub workspace add` | closed 2025-11-27 | Tooling around workspace membership. |
| `dart-lang/pub` | [4713](https://github.com/dart-lang/pub/issues/4713) | Support referencing workspace packages by name in `pubspec.yaml` | closed 2025-11-21 | — |
| `dart-lang/pub` | [4863](https://github.com/dart-lang/pub/pull/4863) | Use workspace root when constructing Entrypoint in `getExecutableForCommand` | **merged** 2026-09-01 | **Directly relevant to the "run from a subdirectory" symptom.** States: *"when invoked from a sub-directory without a `pubspec.yaml` while resolution was out of date … `Entrypoint` was constructed with `workingDir` pointing to the sub-directory … failing with `Could not find a file named "pubspec.yaml" in ".../lib"`."* Also notes `isLockFileUpToDate` previously only checked `root.immediateDependencies`, missing other workspace packages' dependencies. |
| `dart-lang/pub` | [3184](https://github.com/dart-lang/pub/issues/3184) | `.gitignore` validator triggers even when I have a different `.pubignore` in mono_repos | open since 2021 | The `.pubignore`-vs-mono-repo interaction is a long-standing rough edge. |
| `dart-lang/pub` | [3948](https://github.com/dart-lang/pub/issues/3948) | Pub Publish Incorrectly Publishes 'packages' folder | closed 2023-06-19 | Directly relevant to `.pubignore: packages/` in a monorepo. |
| `dip-develop/alteri-one` | [PR #5](https://github.com/dip-develop/alteri-one/pull/5) | docs(adr): the workspace glob list names only subprojects that hold a package | merged 2026-09-29 | Independent confirmation, with measured evidence, that **a glob matching nothing is a hard error, an empty directory does not help, and there is no optional-glob form**. Their ADR-0021 rule: *"The `workspace:` entry lists **exactly** the subprojects holding a package at the current commit. A pattern joins the list in the same commit that creates its first package."* |

### 4.3 What does **not** exist

- **No `dart-lang/pub` issue tracks "published archive contains a `workspace:` field whose members were stripped by `.pubignore`."** A full-text GitHub search for `"No workspace packages matching"` returns 172 loosely-matching results, **none** of them a dart-lang/pub issue about a *published* package. The upstream bug class is **unreported** upstream — only downstream consumers report it (eventide, alteri-one, and now ume).
- No `dart-lang/pub-dev` issue on the topic (server-side validation) was found.

---

## 5. How upstream projects actually lay this out

The convergent pattern is: **a virtual root package that is never published, with `publish_to: none` and no library of its own.** The published packages are its members.

### 5.1 `dart-lang/source_gen`

```yaml
# https://github.com/dart-lang/source_gen/blob/master/pubspec.yaml
name: source_gen_workspace
publish_to: none
environment:
  sdk: ^3.11.0

workspace:
  - source_gen
  - example
  - example_usage
  - _test_annotations

dev_dependencies:
  dart_flutter_team_lints: ^3.1.0
```
- Root is a throwaway (`source_gen_workspace`), `publish_to: none`.
- `example` **is** a workspace member, but it belongs to the **root's** workspace — it is **not** inside `source_gen/`.
- Published `source_gen 4.3.0` archive: contains `pubspec.yaml` with `resolution: workspace`; **no `example/`, no `workspace:` field**.

### 5.2 `dart-lang/test`

```yaml
# https://github.com/dart-lang/test/blob/master/pubspec.yaml
name: test_workspace
publish_to: none
environment:
  sdk: ^3.5.0
workspace:
  - integration_tests/cross_compiler_hang
  - integration_tests/regression
  - integration_tests/spawn_hybrid
  - integration_tests/wasm
  - pkgs/checks
  - pkgs/checks_codegen
  - pkgs/checks_codegen/example
  - pkgs/test
  - pkgs/test_api
  - pkgs/test_core
dev_dependencies:
  dart_flutter_team_lints: ^3.1.0
```
Note the **explicit enumeration** — no globs, and `pkgs/checks_codegen/example` is listed by hand.

Member `pkgs/test/pubspec.yaml`:
```yaml
name: test
version: 1.33.0-wip
...
resolution: workspace
environment:
  sdk: ^3.11.0
```
Published `test 1.32.0`: `resolution: workspace` present, **no `example/` in the archive, no `workspace:` field**.

### 5.3 `riverpod`

```yaml
# https://github.com/rrousselGit/riverpod/blob/master/pubspec.yaml
name: workspace
publish_to: none

environment:
  sdk: ^3.12.0

workspace:
  - benchmarks
  - examples/first_app
  ...
  - packages/flutter_riverpod/example
  - packages/flutter_riverpod
  - packages/hooks_riverpod/example
  - packages/hooks_riverpod
  ...
  - packages/riverpod/example
  - packages/riverpod
  ...
  - website
```
- Root named literally `workspace`, `publish_to: none`.
- **Every `packages/<x>/example` is listed individually.** The root uses explicit paths, not a `packages/*/example` glob — a glob would be fragile, and note that *a glob matching nothing is fatal* (see §4.2, alteri-one ADR-0021).
- Published `riverpod 3.4.3`: `resolution: workspace`, `example/` **is** included (they publish it deliberately).

### 5.4 `drift`

```yaml
# https://github.com/simolus3/drift/blob/master/pubspec.yaml
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
  - extras/drift_devtools_extension
  ...
  - examples/app
  - examples/app_drift3
  ...
```
Root virtual, `publish_to: none`; shared examples live under a top-level `examples/` that is a member of the **root's** workspace. Published `drift 2.35.1`: `resolution: workspace`, `example/` present.

### 5.5 `eventide` (post-mortem of this exact bug)

Before the fix the repo published the *root* package. After `#124`, the layout became:

```yaml
# https://github.com/sncf-connect-tech/eventide/blob/main/pubspec.yaml  (after 2.4.1)
name: eventide_repository
publish_to: 'none'

environment:
  sdk: ^3.12.0

workspace:
  - package/
  - examples/full-permission
  - examples/write-only
  - examples/native-only
```
Repo now has top-level `package/`, `examples/`, `doc/` — and **no root `.pubignore`**. The published package moved one level down, out of the root. This is exactly the `homeserve-lsaudon` recommendation in `#124`.

### 5.6 `bloc`

Published `bloc 9.2.1` has **no** `resolution: workspace` and **no** `workspace:` field — its root pubspec was not fetched successfully via `gh api` (empty response), so its layout is **unconfirmed**. Do not use it as evidence.

### 5.7 `flutter/packages`

`gh api repos/flutter/packages/contents/` shows **no root `pubspec.yaml`**, and a code search for `"resolution: workspace"` in that repo returns **0 results**. The Flutter plugin monorepo publishes each plugin independently with no pub workspace at the root. **[observed empirically]**

### 5.8 Summary of layout choices

| repo | root package | root `publish_to` | example location | example a member? | archive includes example? |
|---|---|---|---|---|---|
| `source_gen` | virtual (`source_gen_workspace`) | `none` | `example/` at repo root | yes | no |
| `dart-lang/test` | virtual (`test_workspace`) | `none` | `pkgs/checks_codegen/example` only | yes | no |
| `riverpod` | virtual (`workspace`) | `none` | `packages/*/example` + `examples/*` | yes | yes (deliberate) |
| `drift` | virtual (`drift_workspace`) | `none` | `examples/*` at root | yes | yes (deliberate) |
| `eventide` (post-fix) | virtual (`eventide_repository`) | `none` | `examples/*` at root | yes | unknown |
| `flutter/packages` | **none** | n/a | per-plugin `example/` | n/a (no workspace) | yes |

**Universal rule [inferred from all six]:** *the package that is published must never contain a `workspace:` field, and a shared `example/` must never be reachable as a stripped member of a published package's own workspace list.*

---

## 6. Viable fixes (ranked)

### ✅ Option 1 (recommended) — Virtual root + published members; `example/` at the root

The root `pubspec.yaml` is a throwaway named e.g. `ume_workspace` with `publish_to: none` and **no `lib/`**, and the real package moves to `packages/ume/`. `example/` stays a member of the *root's* workspace and is never inside a published package's own directory.

**Why:**
- The root is **never published**, so its `workspace:` list (dangling or not) can never reach a consumer. **[observed empirically]** — the failure requires `Package.load` on a *cached hosted* pubspec.
- Published members carry only `resolution: workspace` — which is **proven harmless downstream** (`ume_core 2.0.3`, `source_gen 4.3.0`, `test 1.32.0`, `riverpod 3.4.3` all ship it and work).
- Matches the official doc example (`name: _`, `publish_to: none`) and every flagship upstream repo (§5).

**Evidence it works:** this is exactly what the repo's current uncommitted state does, and `packages/ume/pubspec.yaml` already has `resolution: workspace` with **no** `workspace:` field. `ume_core 2.0.3` (already published this way) was verified working downstream:

```
$ dart pub deps                # consumer depending on ume_core 2.0.3
Dart SDK 3.13.4
app 0.0.0
└── ume_core 2.0.3
    ├── flutter 0.0.0
...
EXIT=0
```

**Pros:** no `.pubignore` gymnastics; examples keep working in-repo; publishing is uniform (`dart pub -C packages/<x> publish`); matches upstream. **Cons:** requires moving files (already largely done via `git mv` in the working tree); version bump needed.

**⚠️ Caveat for the current working tree.** The root pubspec is

```yaml
workspace:
  - example
  - packages/*
  - packages/*/example
```

`packages/*/example` matches **exactly one** directory — `packages/ume_kit_shared_preferences/example` (verified: `glob.glob('packages/*/example')` → `['packages/ume_kit_shared_preferences/example']`; its pubspec declares `name: ume_kit_shared_preferences_example`, `resolution: workspace`). So the glob is **currently satisfied and the layout is valid**. Two residual risks remain:

- **It is a one-match-away-from-failure glob.** If that single `example/` directory is ever moved, renamed, or deleted (e.g. by the ongoing `shared_preferences` refactor), `packages/*/example` matches nothing and the root workspace **hard-fails** — the same `fail()` path as §2, now on the maintainer's own machine. Prefer an explicit path (`packages/ume_kit_shared_preferences/example`) over a glob that has exactly one match.
- It violates the rule that *"a pattern joins the list in the same commit that creates its first package"* ([alteri-one ADR-0021](https://github.com/dip-develop/alteri-one/pull/5)) — a glob whose only match can disappear silently.

Neither risk is a downstream bug, because the root is never published (that is the whole point of Option 1).

### ✅ Option 2 — Do not let `example/` be a member of a published package's workspace

If `example/` must stay a member, keep it but ensure the *published* member's pubspec never lists it. Since only the **root** can have `workspace:`, and members only have `resolution: workspace`, this is automatically satisfied once Option 1 is adopted. If you *cannot* restructure the root, the fallback is: **remove `example` from the published root's `workspace:` list** and let it resolve independently (drop `resolution: workspace` from `example/pubspec.yaml`).

**Pros:** minimal file movement. **Cons:** `example/` loses its shared resolution and gets its own `pubspec.lock`/`.dart_tool`, which is what workspaces exist to avoid.

### ✅ Option 3 — Move the published package into a subdirectory (Option 1's core move)

Even keeping a non-virtual root, moving the published package to `packages/ume/` means the root pubspec is only a workspace manifest. This is the `eventide` fix and the `homeserve-lsaudon` recommendation. Equivalent in effect to Option 1 as long as the root is also `publish_to: none`.

### ⚠️ Option 4 — Per-package `.pubignore`, never excluding a workspace member

Only viable if `example/` is **not** in the published root's `workspace:` list. If it *is*, excluding it with `.pubignore` is precisely the bug: **publish-time validation sees the working tree (valid), the tarball does not (invalid), and nothing reconciles them** (§2.3).

**Rule:** a `.pubignore` must never exclude a path that appears in the `workspace:` list of the pubspec being published (or, transitively, in the `workspace:` list of any pubspec that ends up in the archive).

### ⚠️ Option 5 — Add a post-publish verification step

No upstream guard exists, so add your own. In CI, after `dart pub publish --dry-run`, assert that every entry under `workspace:` in the *archive's* pubspec is present in the archive. Cheap approximation: a test that fails if `pubspec.yaml` contains `workspace:` **and** the package is publishable (`publish_to != none`).

**Pros:** catches the class of bug, including future variants. **Cons:** it is a workaround for a missing upstream check.

### ❌ Option 6 — Rely on `dart pub publish` validation

**Does not work.** `dart pub publish` validated 2.0.8 successfully (modulo LICENSE/README, which is what the maintainer would have fixed) while the archive was already broken. Only a genuinely-absent `example/` directory triggers the failure at publish time — `.pubignore` masks it. **[observed empirically]**

### ❌ Option 7 — `--skip-validation` / `--force` theories

Not needed to explain 2.0.8. `--skip-validation` would also skip the LICENSE/README errors, but the archive would be identical; and `--force` only bypasses *warnings*. The `.pubignore` explanation is sufficient and is confirmed by the archive contents.

---

## 7. Open questions / unconfirmed

1. **Exact first SDK shipping workspaces** — the `pub` constant says language version `3.5` (`language_version.dart:114`); the SDK changelog first announces it under `3.6.0`; docs use `^3.6.0`. The `## 3.5.0` changelog section has no `workspace` entry. **Unconfirmed.**
2. **Whether `dart run build_runner build` specifically fails** for a consumer of `ume 2.0.8`. `dart run <file>` does **not** fail. A failure would require `build_runner` to be reachable only as a *transitive* dependency, hitting `executable.dart:62`. **Unconfirmed for the general case.**
3. **Whether `dart-lang/pub` maintainers consider the dangling-workspace-in-a-published-archive a bug worth guarding.** No issue exists. `#4649` (open) is the only place it could surface. **Unknown.**
4. **Whether `bloc` uses a pub workspace** — `gh api` returned an empty root pubspec; the published `bloc 9.2.1` has no workspacing fields. **Unconfirmed.**
5. **`flutter/packages`'s current position on workspaces** — no root pubspec and 0 code matches for `resolution: workspace` as of 2026-10-01, but [flutter/flutter#161385 ("\[packages\] Migrate package groupings to use workspaces", open)](https://github.com/flutter/flutter/issues/161385) indicates a migration is planned. **Unconfirmed.**
6. **Whether `packages/*/example` would have been the same hard failure in ume 2.0.8 had `packages/` been published with zero matching `example/` dirs.** By the source (`package.dart:183-241`) yes — the same `packages.isEmpty` check governs globs. **Confirmed in source; not reproduced against 2.0.8 specifically** (2.0.8 never got that far because `example` failed first).
7. **Why `dart pub deps` needs the full `PackageGraph`** — this is the reason the failure is limited to `deps`/transitive-`run` rather than all commands. I traced it to `lib/src/entrypoint.dart:281` and `lib/src/command/deps.dart:105`, but did not audit every consumer of `packageGraph`. **Partially confirmed.**

---

## References

**`dart-lang/pub` source — pinned at commit `90bb91c90cc8edc0d32693f16a4075be6b1e4fce` (2026-10-01)**
- `lib/src/package.dart:162` — `factory Package.load` — <https://github.com/dart-lang/pub/blob/90bb91c90cc8edc0d32693f16a4075be6b1e4fce/lib/src/package.dart#L162>
- `lib/src/package.dart:183` — glob vs literal workspace entry — <https://github.com/dart-lang/pub/blob/90bb91c90cc8edc0d32693f16a4075be6b1e4fce/lib/src/package.dart#L183>
- `lib/src/package.dart:234` — **`No workspace packages matching`** — <https://github.com/dart-lang/pub/blob/90bb91c90cc8edc0d32693f16a4075be6b1e4fce/lib/src/package.dart#L234>
- `lib/src/package.dart:243` — `does not have 'resolution: workspace'` — <https://github.com/dart-lang/pub/blob/90bb91c90cc8edc0d32693f16a4075be6b1e4fce/lib/src/package.dart#L243>
- `lib/src/package.dart:392` — `.pubignore` / `.gitignore` selection in `listFiles` — <https://github.com/dart-lang/pub/blob/90bb91c90cc8edc0d32693f16a4075be6b1e4fce/lib/src/package.dart#L392>
- `lib/src/package.dart:480` — `validateWorkspace` — <https://github.com/dart-lang/pub/blob/90bb91c90cc8edc0d32693f16a4075be6b1e4fce/lib/src/package.dart#L480>
- `lib/src/entrypoint.dart:147` — `Found a pubspec.yaml … But found no workspace root` — <https://github.com/dart-lang/pub/blob/90bb91c90cc8edc0d32693f16a4075be6b1e4fce/lib/src/entrypoint.dart#L147>
- `lib/src/entrypoint.dart:281` — `Entrypoint._createPackageGraph` — <https://github.com/dart-lang/pub/blob/90bb91c90cc8edc0d32693f16a4075be6b1e4fce/lib/src/entrypoint.dart#L281>
- `lib/src/command/lish.dart:334` — archive file list — <https://github.com/dart-lang/pub/blob/90bb91c90cc8edc0d32693f16a4075be6b1e4fce/lib/src/command/lish.dart#L334>
- `lib/src/executable.dart:62` — `entrypoint.packageGraph` in `runExecutable` — <https://github.com/dart-lang/pub/blob/90bb91c90cc8edc0d32693f16a4075be6b1e4fce/lib/src/executable.dart#L62>
- `lib/src/language_version.dart:114-115` — `firstVersionWithWorkspaces` / `firstVersionWithWorkspaceGlobs` — <https://github.com/dart-lang/pub/blob/90bb91c90cc8edc0d32693f16a4075be6b1e4fce/lib/src/language_version.dart#L114>
- `lib/src/pubspec.dart:67-131` — `workspace` / `resolution` parsing — <https://github.com/dart-lang/pub/blob/90bb91c90cc8edc0d32693f16a4075be6b1e4fce/lib/src/pubspec.dart#L67>
- `lib/src/system_cache.dart:126` — `SystemCache.load` — <https://github.com/dart-lang/pub/blob/90bb91c90cc8edc0d32693f16a4075be6b1e4fce/lib/src/system_cache.dart#L126>
- `lib/src/validator/pubspec.dart:22` — `The pubspec is hidden` — <https://github.com/dart-lang/pub/blob/90bb91c90cc8edc0d32693f16a4075be6b1e4fce/lib/src/validator/pubspec.dart#L22>
- `lib/src/utils.dart:109` — `workspacesDocUrl` — <https://github.com/dart-lang/pub/blob/90bb91c90cc8edc0d32693f16a4075be6b1e4fce/lib/src/utils.dart#L109>

**Official documentation**
- Pub workspaces — <https://dart.dev/tools/pub/workspaces> (page last updated 2026-05-15)
- Short link used in error messages — <https://dart.dev/go/pub-workspaces>
- `pubspec.yaml` reference — <https://dart.dev/tools/pub/pubspec>
- Publish reference (note: `/cmd/pub-publish` is **404**; the live page is) — <https://dart.dev/tools/pub/cmd/pub-lish>

**Dart SDK changelog** — <https://github.com/dart-lang/sdk/blob/main/CHANGELOG.md>
- `## 3.6.0`, `#### Pub` — "Support for workspaces"
- `## 3.9.4`, `#### Pub` — `dart pub get --example` / `dart-lang/pub#4674`
- `## 3.11.0`, `#### Pub` — "Glob support for pub workspaces" / `dart pub cache gc` / `--ignore-warnings`
- `## 3.13.0` — `dart pub workspace list`
- `## 3.6.1` — stray `.dart_tool/package_config.json` cleanup

**pub.dev archives inspected**
- <https://pub.dev/api/archives/ume-2.0.8.tar.gz> · <https://pub.dev/api/archives/ume-2.0.7.tar.gz> · <https://pub.dev/api/archives/ume-2.0.6.tar.gz> · <https://pub.dev/api/archives/ume-2.0.5.tar.gz>
- <https://pub.dev/api/archives/source_gen-4.3.0.tar.gz> · <https://pub.dev/api/archives/test-1.32.0.tar.gz> · <https://pub.dev/api/archives/riverpod-3.4.3.tar.gz> · <https://pub.dev/api/archives/drift-2.35.1.tar.gz> · <https://pub.dev/api/archives/bloc-9.2.1.tar.gz> · <https://pub.dev/api/archives/ume_core-2.0.3.tar.gz>
- <https://pub.dev/api/packages/ume>

**Upstream repository pubspecs**
- `dart-lang/source_gen` — <https://github.com/dart-lang/source_gen/blob/master/pubspec.yaml>
- `dart-lang/test` — <https://github.com/dart-lang/test/blob/master/pubspec.yaml> and <https://github.com/dart-lang/test/blob/master/pkgs/test/pubspec.yaml>
- `rrousselGit/riverpod` — <https://github.com/rrousselGit/riverpod/blob/master/pubspec.yaml>
- `simolus3/drift` — <https://github.com/simolus3/drift/blob/master/pubspec.yaml>
- `sncf-connect-tech/eventide` — <https://github.com/sncf-connect-tech/eventide/blob/main/pubspec.yaml>
- `flutter/packages` — <https://github.com/flutter/packages> (no root pubspec; 0 matches for `resolution: workspace`)

**Issues / PRs**
- <https://github.com/dart-lang/pub/issues/4649> — workspaces clarification (open)
- <https://github.com/dart-lang/pub/issues/4393> — `pub unpack` fails with a workspace dependency
- <https://github.com/dart-lang/pub/issues/4809> — pre-publish sibling path → version resolution (not planned)
- <https://github.com/dart-lang/pub/issues/4388> — publish package by name in a workspace (not planned)
- <https://github.com/dart-lang/pub/issues/4629> — LICENSE from workspace root (not planned)
- <https://github.com/dart-lang/pub/issues/4252> — confirm `pub publish` works in workspace
- <https://github.com/dart-lang/pub/issues/4674> — `package_graph.json` example missing
- <https://github.com/dart-lang/pub/pull/4679> — handle all examples in workspace (`--example`), shipped 3.9.4
- <https://github.com/dart-lang/pub/pull/4863> — workspace root for `getExecutableForCommand`
- <https://github.com/dart-lang/pub/issues/3184> — `.gitignore` validator vs `.pubignore` in mono-repos
- <https://github.com/dart-lang/pub/issues/3948> — pub publish incorrectly publishes `packages` folder
- <https://github.com/sncf-connect-tech/eventide/issues/124> — published archive omits `example/more-complex/*`
- <https://github.com/dip-develop/alteri-one/pull/5> — ADR: a glob matching nothing is a `dart pub get` error
- <https://github.com/flutter/flutter/issues/161385> — migrate package groupings to workspaces (open)

---

## Reproduction artifacts

All commands were run with `dart` 3.13.4 on macOS (arm64). Reproductions live in throwaway directories outside the repo:

| path | what it demonstrates |
|---|---|
| `/tmp/wstest/consumer` | consumer with `ume: 2.0.8` — `dart pub deps` → exit 1, exact error |
| `/tmp/wstest2` | minimal `path:`-dependency reproduction (independent of pub.dev) |
| `/tmp/wstest3/pubtest` | `dart pub publish --dry-run` **fails** when the workspace member is truly absent |
| `/tmp/wstest4/repro` | **the actual 2.0.8 accident**: member present + `.pubignore` → publish succeeds, archive broken |
| `/tmp/wstest5/app` | `ume_core 2.0.3` (`resolution: workspace`, no `workspace:`) is harmless downstream |
| `/tmp/pubsrc` | shallow clone of `dart-lang/pub` @ `90bb91c` |
| `/tmp/ume208`, `/tmp/umev/{2.0.5,2.0.6,2.0.7}` | extracted published archives |
