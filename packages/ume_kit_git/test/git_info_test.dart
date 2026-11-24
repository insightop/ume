import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ume_kit_git/ume_kit_git.dart';
import 'package:ume_kit_git/src/components/git_info_items.dart';
import 'package:ume_kit_git/src/components/recent_commits.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Git model exposes injected revision or omits all metadata when unavailable',
    () async {
      final items = buildGitInfoItems();
      final values = {for (final item in items) item.title: item.subtitle};
      const commit = String.fromEnvironment('UME_GIT_COMMIT');
      if (commit.isEmpty) {
        expect(items, isEmpty);
      } else {
        expect(values['Git Commit'], commit);
        expect(
          values['Git Branch'],
          const String.fromEnvironment('UME_GIT_BRANCH'),
        );
        expect(
          values['Commit Message'],
          utf8.decode(
            base64Decode(
              const String.fromEnvironment('UME_GIT_MESSAGE_BASE64'),
            ),
          ),
        );
        expect(
          values['Commit Author'],
          const String.fromEnvironment('UME_GIT_AUTHOR'),
        );
        expect(
          values['Commit Time'],
          const String.fromEnvironment('UME_GIT_TIME'),
        );
        expect(
          values['Working Tree'],
          const String.fromEnvironment('UME_GIT_DIRTY') == 'true'
              ? 'Contains uncommitted changes'
              : 'Clean',
        );
      }
    },
  );
  testWidgets('standalone Git panel displays metadata and copies a row', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: GitInfo()));
    await tester.pumpAndSettle();
    expect(find.text('Git Info'), findsOneWidget);
    const commit = String.fromEnvironment('UME_GIT_COMMIT');
    if (commit.isEmpty) {
      expect(find.text('暂无 Git 信息'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
      return;
    }
    expect(find.text('Git Commit'), findsOneWidget);
    await tester.tap(find.text('Git Commit'));
    await tester.pump();
    expect(copied, startsWith('Git Commit: '));
    expect(copied, 'Git Commit: $commit');
  });
  test(
    'history ignores missing or malformed data and caps valid history at five',
    () {
      expect(buildRecentGitCommits(encoded: ''), isEmpty);
      expect(buildRecentGitCommits(encoded: 'not base64!'), isEmpty);
      String encode(Object value) =>
          base64Encode(utf8.encode(jsonEncode(value)));
      expect(buildRecentGitCommits(encoded: encode({'bad': 'shape'})), isEmpty);
      expect(
        buildRecentGitCommits(
          encoded: encode([
            {'hash': 42},
          ]),
        ),
        isEmpty,
      );
      final records = [
        for (var i = 0; i < 8; i++)
          {
            'hash': 'hash$i',
            'shortHash': 'h$i',
            'author': '作者',
            'time': '2026-10-29T20:00:00+08:00',
            'subject': '提交 "$i"',
          },
      ];
      final recent = buildRecentGitCommits(encoded: encode(records));
      expect(recent, hasLength(5));
      expect(recent.first.subject, '提交 "0"');
      expect(recent.first.copyText, contains('Commit: hash0'));
    },
  );

  testWidgets(
    'history starts collapsed, expands, copies full commit and collapses again',
    (tester) async {
      const commit = String.fromEnvironment('UME_GIT_COMMIT');
      final recent = buildRecentGitCommits();
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData')
            copied = (call.arguments as Map)['text'] as String;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: GitInfo()));
      await tester.pumpAndSettle();
      if (commit.isEmpty || recent.isEmpty) {
        expect(find.byType(ExpansionTile), findsNothing);
        return;
      }
      final first = recent.first;
      final title = find.descendant(
        of: find.byKey(ValueKey(first.hash)),
        matching: find.text(first.subject),
      );
      await tester.scrollUntilVisible(find.byType(ExpansionTile), 300);
      expect(title, findsNothing);
      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(title);
      await tester.pumpAndSettle();
      expect(title, findsOneWidget);
      expect(find.text('不含当前构建，最多 5 条'), findsOneWidget);
      final row = tester.widget<ListTile>(
        find.ancestor(of: title, matching: find.byType(ListTile)),
      );
      expect((row.title as Text).data, first.time);
      final lines = (row.subtitle as Column).children.cast<Text>();
      expect(lines.map((line) => line.data), [
        first.subject,
        '${first.shortHash}  ${first.author}',
      ]);
      await tester.tap(title);
      await tester.pump();
      expect(copied, first.copyText);
      await tester.ensureVisible(find.text('此前提交（${recent.length}）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('此前提交（${recent.length}）'));
      await tester.pumpAndSettle();
      expect(title, findsNothing);
    },
  );
}
