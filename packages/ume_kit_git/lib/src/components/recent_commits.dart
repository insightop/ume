import 'dart:convert';

/// A commit embedded at build time, ordered newest first by Git.
class RecentGitCommit {
  const RecentGitCommit({
    required this.hash,
    required this.shortHash,
    required this.author,
    required this.time,
    required this.subject,
  });

  final String hash;
  final String shortHash;
  final String author;
  final String time;
  final String subject;

  String get copyText =>
      'Commit: $hash\nMessage: $subject\nAuthor: $author\nTime: $time';
}

/// Older builds and malformed metadata simply omit the history section.
List<RecentGitCommit> buildRecentGitCommits({String? encoded}) {
  encoded ??= const String.fromEnvironment('UME_GIT_RECENT_COMMITS_BASE64');
  if (encoded.isEmpty) return const [];
  try {
    final data = jsonDecode(utf8.decode(base64Decode(encoded)));
    if (data is! List) return const [];
    final commits = <RecentGitCommit>[];
    for (final entry in data.take(5)) {
      if (entry is! Map) continue;
      const keys = ['hash', 'shortHash', 'author', 'time', 'subject'];
      if (keys.any((key) => entry[key] is! String)) continue;
      if ((entry['hash'] as String).isEmpty) continue;
      commits.add(
        RecentGitCommit(
          hash: entry['hash'] as String,
          shortHash: entry['shortHash'] as String,
          author: entry['author'] as String,
          time: entry['time'] as String,
          subject: entry['subject'] as String,
        ),
      );
    }
    return commits;
  } on FormatException {
    return const [];
  }
}
