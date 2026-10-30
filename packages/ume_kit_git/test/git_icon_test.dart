import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ume_kit_git/ume_kit_git.dart';

void main() {
  testWidgets('plugin icon decodes without a bundled asset', (tester) async {
    final provider = const GitInfo().iconImageProvider;
    // Use an ImageConfiguration without an asset bundle, as in dev-only hosts.
    await tester.runAsync(() async {
      final stream = provider.resolve(ImageConfiguration.empty);
      final result = Completer<ImageInfo>();
      final listener = ImageStreamListener(
        (image, synchronousCall) => result.complete(image),
        onError: (Object error, StackTrace? stack) =>
            result.completeError(error, stack),
      );
      stream.addListener(listener);
      try {
        final image = await result.future.timeout(const Duration(seconds: 5));
        expect(image.image.width, 96);
        expect(image.image.height, 96);
        image.dispose();
      } finally {
        stream.removeListener(listener);
      }
    });
    await tester.pumpWidget(MaterialApp(home: Image(image: provider)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
