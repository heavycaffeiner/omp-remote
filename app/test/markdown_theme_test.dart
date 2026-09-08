// The markdown sheet bakes scheme colours in. This app takes its palette
// from the wallpaper, so the colours can change while the brightness does
// not: a rendered body has to follow the scheme it is under, not the one it
// first saw.

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_omp/widgets/markdown_text.dart';

Color _codeBackground(WidgetTester tester) {
  final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
  final decoration = body.styleSheet!.codeblockDecoration! as BoxDecoration;
  return decoration.color!;
}

void main() {
  // MaterialApp lerps a theme change over kThemeAnimationDuration, so a
  // single frame still shows the old palette.
  Future<void> pump(
    WidgetTester tester, {
    required Color seed,
    required Brightness brightness,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: seed,
            brightness: brightness,
          ),
        ),
        home: const Scaffold(
          body: MarkdownText(text: 'text with `code` in it'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a new palette at the same brightness reaches the body', (
    tester,
  ) async {
    await pump(
      tester,
      seed: const Color(0xFF0000FF),
      brightness: Brightness.light,
    );
    final blue = _codeBackground(tester);

    // Same brightness, different wallpaper palette.
    await pump(
      tester,
      seed: const Color(0xFFFF8800),
      brightness: Brightness.light,
    );

    expect(_codeBackground(tester), isNot(blue));
  });

  testWidgets('a dark scheme reaches the body too', (tester) async {
    await pump(
      tester,
      seed: const Color(0xFF0000FF),
      brightness: Brightness.light,
    );
    final light = _codeBackground(tester);

    await pump(
      tester,
      seed: const Color(0xFF0000FF),
      brightness: Brightness.dark,
    );

    expect(_codeBackground(tester), isNot(light));
  });
}
