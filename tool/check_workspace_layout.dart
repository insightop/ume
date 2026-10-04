// pub workspace 布局守卫。
//
// 背景：ume 2.0.8 发布后，下游 `dart pub deps` / 子目录 `dart run` 报
//   No workspace packages matching `example`.
// 根因：可发布的包在 pubspec 里声明了 `workspace:`，而 `dart pub publish`
// 校验的是工作区、打包用的却是 `.pubignore` 过滤后的文件列表。当
// `workspace:` 的某个条目在归档里不存在时，pub 读「依赖的 pubspec」会硬失败。
//
// `dart pub publish --dry-run` 抓不住这类问题（2.0.8 正是从它眼皮下发布的），
// 因此用本脚本做独立守卫。
//
// 刻意只依赖 `dart:io`：本脚本要能在「workspace 已经坏掉」时照常运行，
// 那种状态下任何 package 依赖都可能解析不出来。
//
// 用法：dart run tool/check_workspace_layout.dart   （在仓库根执行）
// 退出码：0 = 通过；1 = 发现违规。
import 'dart:io';

/// `packages/` 下的一个成员包。
class _Package {
  _Package(this.path, this.name, this.publishable, this.hasWorkspaceKey);

  final String path;
  final String name;

  /// 无 `publish_to: none`，即会发布到 pub.dev。
  final bool publishable;
  final bool hasWorkspaceKey;
}

/// 极简 pubspec 读取：只做「顶层键 + 其原始值」的解析。
///
/// pubspec 的顶层结构简单，无需引入 YAML 解析器；保持零依赖是本脚本的硬要求。
class _Pubspec {
  _Pubspec(this.path, this._lines);

  final String path;
  final List<String> _lines;

  factory _Pubspec.read(String path) =>
      _Pubspec(path, File(path).readAsLinesSync());

  /// 返回顶层 `key:` 的原始值（去掉行内注释与引号）。不存在则返回 null。
  String? rawValue(String key) {
    final pattern = RegExp('^$key\\s*:(.*)\$');
    for (final line in _lines) {
      if (line.startsWith(' ') || line.startsWith('\t')) continue; // 排除嵌套
      if (line.trimLeft().startsWith('#')) continue;
      final match = pattern.firstMatch(line);
      if (match == null) continue;
      var value = match.group(1)!.trim();
      final comment = value.indexOf(' #');
      if (comment >= 0) value = value.substring(0, comment).trim();
      return value.replaceAll(RegExp('^["\']|["\']\$'), '').trim();
    }
    return null;
  }

  /// 顶层是否为列表键（`key:` 后跟 `- item` 的行）。
  bool hasKey(String key) => rawValue(key) != null;

  /// 读取顶层列表键的所有条目（形如 `  - value`）。
  List<String> listValues(String key) {
    final values = <String>[];
    var inBlock = false;
    var blockIndent = 0;
    final header = RegExp('^$key\\s*:\\s*(.*)\$');

    for (final line in _lines) {
      if (line.startsWith(' ') || line.startsWith('\t')) {
        if (!inBlock) continue;
        if (line.length - line.trimLeft().length < blockIndent) continue;
        final item = line.trim();
        if (!item.startsWith('-')) continue;
        var value = item.substring(1).trim();
        final comment = value.indexOf(' #');
        if (comment >= 0) value = value.substring(0, comment).trim();
        values.add(value.replaceAll(RegExp('^["\']|["\']\$'), '').trim());
        continue;
      }
      final match = header.firstMatch(line);
      if (match == null) {
        inBlock = false;
        continue;
      }
      inBlock = true;
      blockIndent = line.length - line.trimLeft().length + 1;
      // 也支持行内写法：`workspace: [example, packages/*]`
      final inline = match.group(1)!.trim();
      if (inline.startsWith('[') && inline.endsWith(']')) {
        for (final part in inline.substring(1, inline.length - 1).split(',')) {
          final value = part.trim().replaceAll(RegExp('^["\']|["\']\$'), '');
          if (value.isNotEmpty) values.add(value);
        }
      }
    }
    return values;
  }
}

Never _fail(String message) {
  stderr.writeln('❌ $message');
  exit(1);
}

void _note(String message) => stdout.writeln('   $message');

_Package? _readPackage(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;

  final pubspec = _Pubspec.read(path);
  final publishTo = pubspec.rawValue('publish_to') ?? '';
  final name = pubspec.rawValue('name') ?? '<unnamed>';
  // publish_to 为 none（含带引号形式）即「不发布」。
  final publishable = !publishTo.contains('none');

  return _Package(
    path,
    name,
    publishable,
    publishable && pubspec.hasKey('workspace'),
  );
}

void main() {
  final rootFile = File('pubspec.yaml');
  if (!rootFile.existsSync()) {
    _fail('未找到根 pubspec.yaml —— 请在仓库根目录执行本脚本');
  }
  final root = _Pubspec.read('pubspec.yaml');

  final violations = <String>[];

  // ── 检查 1：根若声明 workspace:，自身必须 publish_to: none ──────────────
  // 根是唯一允许携带 workspace: 的包。它一旦可发布，这个键就会进入归档，
  // 把「归档内不存在的成员目录」暴露给所有下游。
  final rootPublishTo = root.rawValue('publish_to') ?? '';
  if (root.hasKey('workspace') && !rootPublishTo.contains('none')) {
    violations.add(
      '根 pubspec.yaml 声明了 workspace: 却不是 publish_to: none。\n'
      '      → workspace: 会被发布出去，任何成员目录缺失都会让下游解析失败。',
    );
  }

  // ── 检查 2：可发布包不得声明 workspace: ────────────────────────────────
  // 这是 2.0.8 的 bug 类：当时根包 name: ume 可发布且带 workspace:。
  final packages = <_Package>[];
  final packagesDir = Directory('packages');
  if (packagesDir.existsSync()) {
    for (final entry in packagesDir.listSync()) {
      if (entry is! Directory) continue;
      final pkg = _readPackage('${entry.path}/pubspec.yaml');
      if (pkg == null) continue;
      packages.add(pkg);
      if (pkg.hasWorkspaceKey) {
        violations.add(
          '${pkg.path} (${pkg.name}) 是可发布包，却声明了 workspace:。\n'
          '      → 该键会进入归档；归档内不含其成员时会击穿下游。',
        );
      }
    }
  }

  // ── 检查 3：根 workspace: 的每个条目必须匹配到 ≥1 个目录 ───────────────
  // 悬空 glob（例如目录被移动/删除后）会让 pub 直接硬失败。
  final workspaceEntries = root.listValues('workspace');
  for (final pattern in workspaceEntries) {
    if (_globMatchesDirectory(pattern)) continue;
    violations.add(
      '根 workspace: 的条目 `$pattern` 没有匹配到任何目录。\n'
      '      → pub 会报 "No workspace packages matching `$pattern`" 并失败。',
    );
  }

  // ── 检查 4：根 .pubignore 必须存在，且必须覆盖已跟踪的噪声目录 ─────────
  // pub 从包目录向上查找 .pubignore 直到 workspace 根；它只有在仓库根
  // 才是所有可发布包的共同祖先。挪进子目录即对其它包失效。
  // 另外 .pubignore 会「取代」同目录的 .gitignore，因此噪声规则必须在此重申
  // ——.gitignore 无法排除【已被 git 跟踪】的文件（如各 kit 的 coverage/lcov.info）。
  final pubignore = File('.pubignore');
  if (!pubignore.existsSync()) {
    violations.add(
      '缺少根 .pubignore。\n'
      '      → pub 会回退到 .gitignore，但 .gitignore 无法排除【已被 git 跟踪】的\n'
      '        文件（如各 kit 的 coverage/lcov.info），它们会被打进归档。',
    );
  } else {
    final rules = pubignore
        .readAsLinesSync()
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toSet();
    for (final required in const ['coverage/', 'build/', '*.iml']) {
      if (rules.contains(required)) continue;
      violations.add(
        '根 .pubignore 缺少规则 `$required`。\n'
        '      → .pubignore 会取代 .gitignore，缺这条会让对应文件进入归档。',
      );
    }
  }

  _note('根包: ${root.rawValue('name') ?? '<unnamed>'} '
      '(publish_to: ${rootPublishTo.isEmpty ? '<未声明>' : rootPublishTo})');
  _note('可发布包: ${packages.where((p) => p.publishable).length} 个'
      '（共 ${packages.length} 个成员）');
  _note('workspace 条目: ${workspaceEntries.length} 个，全部命中目录');

  if (violations.isEmpty) {
    stdout.writeln('\n✅ workspace 布局检查通过');
    return;
  }

  stderr.writeln('\n❌ workspace 布局检查发现 ${violations.length} 处问题：\n');
  for (final violation in violations) {
    stderr.writeln('   • $violation\n');
  }
  exit(1);
}

/// 判断一个 glob（可能含 `*`）是否匹配到至少一个目录。
///
/// 仅实现 workspace 条目实际会用到的形态：路径分隔的 `*` 通配。
bool _globMatchesDirectory(String pattern) {
  final segments = pattern.split('/');
  var candidates = <String>['.'];

  for (final segment in segments) {
    final next = <String>[];
    for (final base in candidates) {
      if (!segment.contains('*')) {
        final path = base == '.' ? segment : '$base/$segment';
        if (Directory(path).existsSync()) next.add(path);
        continue;
      }
      final parent = Directory(base);
      if (!parent.existsSync()) continue;
      final regex = RegExp(
        '^${RegExp.escape(segment).replaceAll(r'\*', '[^/]*')}\$',
      );
      for (final child in parent.listSync()) {
        if (child is! Directory) continue;
        final name = child.path.split(Platform.pathSeparator).last;
        if (regex.hasMatch(name)) next.add(child.path);
      }
    }
    candidates = next;
    if (candidates.isEmpty) return false;
  }

  return candidates.isNotEmpty;
}
