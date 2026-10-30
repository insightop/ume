import 'dart:io';
import 'package:ume_kit_git/cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await generateGitInfo(args);
}
