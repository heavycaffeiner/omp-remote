// The diff parser decides what a file change looks like in the app, and a
// misread marker silently turns an addition into context.

import 'package:flutter_test/flutter_test.dart';

import 'package:remote_omp/widgets/diff_view.dart';

void main() {
  test('classifies each unified-diff marker', () {
    final lines = parseUnifiedDiff(
      '--- a/lib/main.dart\n'
      '+++ b/lib/main.dart\n'
      '@@ -1,3 +1,3 @@\n'
      ' import x;\n'
      '-old line\n'
      '+new line\n',
    );

    expect(lines.map((l) => l.kind).toList(), [
      DiffLineKind.meta,
      DiffLineKind.meta,
      DiffLineKind.hunk,
      DiffLineKind.context,
      DiffLineKind.removed,
      DiffLineKind.added,
    ]);
  });

  test('strips the marker so the line can be read and copied', () {
    final lines = parseUnifiedDiff('-was\n+is\n context');
    expect(lines.map((l) => l.text).toList(), ['was', 'is', 'context']);
  });

  test('keeps a file header out of the removed count', () {
    // `---` starts like a removal. Counting it as one would report every
    // diff as having an extra deleted line.
    final lines = parseUnifiedDiff('--- a/f\n+++ b/f\n+only');
    expect(lines.where((l) => l.kind == DiffLineKind.removed), isEmpty);
    expect(lines.where((l) => l.kind == DiffLineKind.added), hasLength(1));
  });

  test('an empty line inside a hunk stays context', () {
    final lines = parseUnifiedDiff('@@ -1 +1 @@\n\n+x');
    expect(lines[1].kind, DiffLineKind.context);
    expect(lines[1].text, '');
  });

  test('lifts a line number out of the code text', () {
    // The edit tool emits `-2|beta`, not a bare `-beta`. Leaving the number
    // in the text runs it into the code and breaks copy.
    final lines = parseUnifiedDiff(' 1|alpha\n-2|beta\n+2|BETA');
    expect(lines.map((l) => l.lineNumber).toList(), [1, 2, 2]);
    expect(lines.map((l) => l.text).toList(), ['alpha', 'beta', 'BETA']);
    expect(lines[1].kind, DiffLineKind.removed);
    expect(lines[2].kind, DiffLineKind.added);
  });

  test('leaves an unnumbered diff alone', () {
    final lines = parseUnifiedDiff('+plain');
    expect(lines.single.lineNumber, isNull);
    expect(lines.single.text, 'plain');
  });
}
