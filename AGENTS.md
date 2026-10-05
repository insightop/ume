# AGENTS.md — ume

Flutter 应用内调试工具集（in-app debug kits）。一个 pub workspace，一个对外 facade，
若干可独立发布的 kit。

## 架构

```
pubspec.yaml              虚拟 workspace 根：name: ume_workspace, publish_to: none
                          ├─ workspace: example, packages/*, packages/*/example
                          └─ melos 配置（唯一一处）
example/                  演示 app（workspace 成员，本地解析 ume）
packages/ume/             facade —— 对外唯一入口
packages/ume_core/        共享内核（无内部依赖）
packages/ume_kit_*/       各功能 kit，每个都依赖 ume_core
                          （ume_kit_example 例外：私有的 kit 开发模板）
tool/                     仓库级脚本
```

依赖方向是单向的：**kit → ume_core**，**ume(facade) → 它收录的各 kit + ume_core**。
新实现放进实现它的 kit 或 ume_core；`packages/ume/lib/ume.dart` 保持为纯 `export`。

两个 kit 有意未收入 facade：`ume_kit_bloc_inspector`（尚未发布到 pub.dev）与
`ume_kit_storage`（`lib/ume.dart` 里的 export 被注释掉）。要收录它们，需同时
加回 `packages/ume/pubspec.yaml` 的依赖与 facade 的 export：只加 export 会让
`dart analyze` 报 `uri_does_not_exist`（CI 变红）。

`packages/ume_kit_{appwrite,brick,catcher,firebase,get_it,supabase}` 是占位目录，
只有 `.gitkeep` 之类的占位文件，没有 `pubspec.yaml`。pub 会静默忽略这类目录，
可以留着。

### 不变式：归档自包含

**只有虚拟根可以声明 `workspace:`，而它永不发布。**

`dart pub publish` 不会改写 pubspec —— `workspace:` 会原样进入归档。pub 读取
「依赖的 pubspec」与读取本地 pubspec 走同一套校验，所以一旦某个 `workspace:`
条目在归档里不存在，下游执行 `dart pub deps`（或从子目录 `dart run`）就会报
`No workspace packages matching ...` 并直接失败。

ume 2.0.8 正是这样发布的，只能靠 2.0.9 补发 —— **已发布的归档无法撤回**。

`tool/check_workspace_layout.dart` 在 CI 与发布前强制这条不变式（4 项检查：
根必须 `publish_to: none`、可发布包不得带 `workspace:`、每个 `workspace:` 条目
须命中目录、根 `.pubignore` 须存在且覆盖噪声规则）。它刻意零依赖（仅 `dart:io`），
因此在 workspace 已损坏时仍能运行。

## 开发

```bash
flutter pub get                                  # 根解析一次，覆盖全部成员
dart tool/check_workspace_layout.dart            # 布局守卫
dart analyze --no-fatal-warnings .               # 0 error 即通过
melos run test                                   # 仅跑有 test/ 的包
```

`melos` 是本地便利工具（dev_dependency，未经全局安装时用 `dart run melos run test`），
**CI 不调用它**：`ci.yml` 直接跑 `dart analyze` 与逐包 `flutter test`。二者需保持
一致 —— 改 melos script 时同步改 CI（或反之）。

改动了 workspace 布局（增删成员、移动 example、动 `.pubignore`）后，**必须重跑
守卫**，并确认 `flutter pub get` 仍能解析。

## 发布

每个包各自发布，由 tag 触发 GitHub OIDC 免密发布（无本地凭据）。

1. **bump 版本** — 改目标包的 `pubspec.yaml` 与它的 `CHANGELOG.md`、`CHANGELOG_cn.md`。
   已发布过的版本号必须递增，pub.dev 拒绝重发。
2. **提交并推送 `master`** — 发布前守卫在 `publish` job 里跑，工作区得先干净。
3. **打 tag 并推送**：

   ```bash
   git tag -a v2.0.9 -m "ume 2.0.9"     # ume 本体：裸 v 前缀
   git tag -a ume_core-v2.0.4 -m "..."  # 其余包：<包名>-v<版本>
   git push origin v2.0.9
   ```

   完整 tag 约定与 glob 模式见 `.github/workflows/publish.yml` 顶部。

4. **完成判据** — `Publish to pub.dev` workflow 变绿，且
   `https://pub.dev/api/packages/<包名>` 的 `latest.version` 已是新版本。

### 发布相关的坑

**tag glob 只用 `*` 和 `[0-9]+`。** 仓库现用的三个模式都避开了方括号字符类：
GitHub 的 ref glob 会拒绝 `[a-z0-9_]` 这类写法（下划线触发
`invalid tags patterns`）。模式一旦非法，**整个 workflow 无法解析**：任何 push
都会生成一个 0 job 的失败 run，连 `master` 分支推送也会 —— 本该被 `tags:`
过滤器静默跳过。

**`.pubignore` 留在仓库根。** pub 从被发布的包目录向上查找它，直到 workspace
根为止，所以放在根才是所有可发布包的共同祖先；放进 `packages/ume/` 就会对
`packages/*` 下的 kit 完全失效。它还会**取代**同目录的 `.gitignore`（不是叠加），
所以 `.gitignore` 里对发布有意义的规则要在 `.pubignore` 重申一遍。其余细节见
该文件头部注释。

**`.pubignore` 只排除包内部的路径。** 排除祖先目录（如 `packages/`）会让 pub
找不到包内文件，发布会报缺少 README/CHANGELOG。

**验证归档时，新建一个消费者包依赖该版本再解析** ——
`tool/verify_published_archive.sh` 就是这么做的（发布后自动跑）。归档里的成员带
`resolution: workspace` 而没有 workspace 根，直接在解包目录里跑 `dart pub deps`
必然误报。

### workflow 一览

| 文件 | 触发 | 作用 |
|---|---|---|
| `ci.yml` | push/PR master | 布局守卫 → analyze → 逐包 test → example APK |
| `publish.yml` | tag `v*` / `<包名>-v*` | 守卫 → `pub publish` → 归档验证 |
| `release.yml` | tag `v*` | example release APK + GitHub Release |
| `coverage.yml` | push master（源码路径变更） | 重算 kit 覆盖率徽章并提交 |
| `flutter_drive.yml` | push/PR master（example/packages 变更） | 集成测试（Android + KVM） |
| `jekyll-gh-pages.yml` | push master | 部署 README 到 GitHub Pages |

## 文档索引

- `docs/research/pub-workspace-publishing.md` — `workspace:` 的发布语义、
  2.0.8 事故的完整机理、上游 issue 与官方布局调研
- `docs/research/melos-and-pub-workspace.md` — melos 7/8 与 pub workspace 的
  共存方式、`melos.yaml` 已废弃、发布行为
