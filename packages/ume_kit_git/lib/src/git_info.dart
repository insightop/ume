import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ume_core/ume_core.dart';

import 'components/git_info_items.dart';
import 'components/recent_commits.dart';
import 'git_icon.dart';

/// The host app's Git revision at build time. Populate it with `ume:flutter`.
class GitInfo extends StatelessWidget implements Pluggable {
  const GitInfo({super.key});

  @override
  String get name => 'GitInfo';

  @override
  String get displayName => 'Git Info';

  @override
  ImageProvider<Object> get iconImageProvider => MemoryImage(gitIconBytes);

  @override
  void onTrigger() {}

  @override
  Widget buildWidget(BuildContext? context) => this;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Git Info')),
    body: _buildContent(),
  );
  Widget _buildContent() {
    final items = buildGitInfoItems();
    if (items.isEmpty) {
      return const Center(child: Text('暂无 Git 信息'));
    }
    final recent = buildRecentGitCommits();
    return ListView(
      children: [
        const ListTile(title: Text('当前构建')),
        for (final item in items) ...[
          ListTile(
            leading: Icon(item.icon),
            title: Text(item.title),
            subtitle: Text(item.subtitle),
            trailing: const Icon(Icons.copy),
            onTap: () => Clipboard.setData(
              ClipboardData(text: '${item.title}: ${item.subtitle}'),
            ),
          ),
          const Divider(),
        ],
        if (recent.isNotEmpty)
          ExpansionTile(
            key: const PageStorageKey('ume_git_recent_commits'),
            leading: const Icon(Icons.history),
            title: Text('此前提交（${recent.length}）'),
            subtitle: const Text('不含当前构建，最多 5 条'),
            children: [
              for (final commit in recent)
                ListTile(
                  key: ValueKey(commit.hash),
                  title: Text(commit.time),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(commit.subject),
                      Text('${commit.shortHash}  ${commit.author}'),
                    ],
                  ),
                  isThreeLine: true,
                  trailing: IconButton(
                    icon: const Icon(Icons.copy),
                    tooltip: '复制提交信息',
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: commit.copyText)),
                  ),
                  onTap: () =>
                      Clipboard.setData(ClipboardData(text: commit.copyText)),
                ),
            ],
          ),
      ],
    );
  }
}
