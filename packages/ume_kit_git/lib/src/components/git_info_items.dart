import 'dart:convert';

import 'package:flutter/material.dart';

class GitInfoItem {
  const GitInfoItem({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;
}

List<GitInfoItem> buildGitInfoItems() {
  const commit = String.fromEnvironment('UME_GIT_COMMIT');
  if (commit.isEmpty) return const [];
  const branch = String.fromEnvironment('UME_GIT_BRANCH');
  const author = String.fromEnvironment('UME_GIT_AUTHOR');
  const time = String.fromEnvironment('UME_GIT_TIME');
  const encodedMessage = String.fromEnvironment('UME_GIT_MESSAGE_BASE64');
  String message;
  try {
    message = encodedMessage.isEmpty
        ? ''
        : utf8.decode(base64Decode(encodedMessage));
  } on FormatException {
    message = 'Invalid commit message encoding';
  }
  const dirty = String.fromEnvironment('UME_GIT_DIRTY');
  return [
    GitInfoItem(title: 'Git Commit', subtitle: commit, icon: Icons.commit),
    GitInfoItem(
      title: 'Git Branch',
      subtitle: branch,
      icon: Icons.account_tree,
    ),
    GitInfoItem(
      title: 'Commit Message',
      subtitle: message,
      icon: Icons.subject,
    ),
    GitInfoItem(title: 'Commit Author', subtitle: author, icon: Icons.person),
    GitInfoItem(title: 'Commit Time', subtitle: time, icon: Icons.schedule),
    GitInfoItem(
      title: 'Working Tree',
      subtitle: dirty == 'true' ? 'Contains uncommitted changes' : 'Clean',
      icon: Icons.edit_note,
    ),
  ];
}
