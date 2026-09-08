// Generates every icon raster the app ships: the opaque launcher tile, the
// adaptive foreground, and the Android notification small icon in each
// density bucket.
//
// Android tints a small icon from its alpha channel alone, so that one is
// drawn as opaque white on a transparent canvas. The launcher tile cannot
// stand in: it is opaque, which tints to a solid square. The adaptive
// foreground cannot either: the system composites it over a flat background,
// so it has to stay mostly transparent.
//
// The outline below is the same path as assets/icon/omp-remote.svg, on the
// same 1024 grid. It is repeated here rather than rasterized from the SVG
// because no Dart SVG rasterizer is available offline, so a change to the
// mark means changing both files.
//
// This runs in CI, where ImageMagick is not installed and res/drawable is
// regenerated and gitignored. The `image` package arrives with
// flutter_launcher_icons.

import 'dart:io';

import 'package:image/image.dart';

const _buckets = <String, int>{
  'mdpi': 24,
  'hdpi': 36,
  'xhdpi': 48,
  'xxhdpi': 72,
  'xxxhdpi': 96,
};

// Vertical supersampling factor. Horizontal coverage is exact, so this only
// has to smooth the scanline steps.
const _scale = 8;
const _grid = 1024.0;

// The pi outline from STIX Two Math, Copyright (c) 2001-2021 by the STI Pub
// Companies, licensed under the SIL Open Font License 1.1
// (https://openfontlicense.org). Scaled so its longer side is 600 of the
// 1024 grid and centred on it. Absolute moveto, lineto, curveto, closepath.
const _mark =
    'M 812 269 L 812 251.6 L 424.7 251.6 '
    'C 311.8 251.6 240.2 287.4 212 387.2 L 233.7 398.1 '
    'C 268.4 339.5 292.3 338.4 419.2 338.4 '
    'C 407.3 432.8 391 494.6 346.5 590.1 '
    'C 312.9 663.9 304.2 676.9 264.1 746.4 L 267.3 762.6 L 369.3 762.6 '
    'C 401.9 687.8 454 452.3 460.5 338.4 L 621 338.4 '
    'C 602.6 437.1 574.4 558.7 574.4 647.6 '
    'C 574.4 718.1 602.6 772.4 667.7 772.4 '
    'C 733.9 772.4 768.6 737.7 797.9 682.3 L 780.5 667.2 '
    'C 765.3 681.3 749.1 696.4 710 696.4 '
    'C 664.4 696.4 647.1 649.8 647.1 572.8 '
    'C 647.1 493.6 661.2 378.5 667.7 338.4 L 797.9 338.4 Z';

// The mark's bounding box is 600 by 521, so its corners sit 397 from the
// centre. The adaptive foreground has to keep them inside the centre safe
// circle of radius 338, since the system masks and shifts that layer. The
// notification icon has no mask, only a 24dp canvas to stay legible on.
const _notificationScale = 1.44;
const _adaptiveScale = 0.84;

/// One straight segment of the flattened outline, in device pixels.
class _Edge {
  const _Edge(this.x1, this.y1, this.x2, this.y2);

  final double x1, y1, x2, y2;
}

/// Flattens the path into edges, mapping design-grid units to a `size` pixel
/// canvas with the glyph scaled about its centre.
List<_Edge> _flatten(String path, int size, double glyphScale) {
  // The grid is square and the scale uniform, so one mapping serves both
  // axes.
  double map(double v) =>
      ((v - _grid / 2) * glyphScale + _grid / 2) / _grid * size;

  final tokens = RegExp(r'[MLCZ]|-?\d+(?:\.\d+)?')
      .allMatches(path)
      .map((m) => m.group(0)!)
      .toList();

  final edges = <_Edge>[];
  var i = 0;
  double sx = 0, sy = 0, cx = 0, cy = 0;

  double next() => map(double.parse(tokens[i++]));

  void addLine(double x, double y) {
    edges.add(_Edge(cx, cy, x, y));
    cx = x;
    cy = y;
  }

  while (i < tokens.length) {
    final command = tokens[i++];
    switch (command) {
      case 'M':
        cx = next();
        cy = next();
        sx = cx;
        sy = cy;
      case 'L':
        addLine(next(), next());
      case 'C':
        final x0 = cx, y0 = cy;
        final x1 = next(), y1 = next();
        final x2 = next(), y2 = next();
        final x3 = next(), y3 = next();
        // Fixed subdivision: the longest curve here spans a few hundred
        // pixels even on the largest canvas, so 64 chords stay well under a
        // pixel of error.
        const steps = 64;
        for (var step = 1; step <= steps; step++) {
          final t = step / steps, u = 1 - t;
          final a = u * u * u;
          final b = 3 * u * u * t;
          final c = 3 * u * t * t;
          final d = t * t * t;
          addLine(
            a * x0 + b * x1 + c * x2 + d * x3,
            a * y0 + b * y1 + c * y2 + d * y3,
          );
        }
      case 'Z':
        addLine(sx, sy);
      default:
        throw FormatException('unexpected path token $command');
    }
  }
  return edges;
}

/// Scanline-fills the mark and returns per-pixel ink coverage, 0 to 1.
///
/// Horizontal coverage comes from the exact span overlap and vertical
/// coverage from `_scale` sample rows, which is what keeps the curves smooth
/// at 24 pixels without a supersampled bitmap.
List<double> _coverage(int target, double glyphScale) {
  final size = target * _scale;
  final edges = _flatten(_mark, size, glyphScale);
  final coverage = List<double>.filled(target * target, 0);
  final area = _scale * _scale;
  final xs = <double>[];
  final dirs = <int>[];

  for (var sy = 0; sy < size; sy++) {
    final y = sy + 0.5;
    xs.clear();
    dirs.clear();
    for (final e in edges) {
      if (e.y1 == e.y2) continue;
      // Half-open in y so a vertex shared by two edges counts once.
      if ((e.y1 <= y) == (e.y2 <= y)) continue;
      final t = (y - e.y1) / (e.y2 - e.y1);
      xs.add(e.x1 + (e.x2 - e.x1) * t);
      dirs.add(e.y2 > e.y1 ? 1 : -1);
    }
    if (xs.isEmpty) continue;

    final order = List<int>.generate(xs.length, (i) => i)
      ..sort((a, b) => xs[a].compareTo(xs[b]));
    final row = sy ~/ _scale;
    var winding = 0;
    for (var i = 0; i < order.length - 1; i++) {
      winding += dirs[order[i]];
      if (winding == 0) continue;
      final from = xs[order[i]], to = xs[order[i + 1]];
      final first = from.floor().clamp(0, size - 1) ~/ _scale;
      final last = to.ceil().clamp(0, size) ~/ _scale;
      for (var col = first; col <= last && col < target; col++) {
        final left = col * _scale.toDouble();
        final overlap =
            (to < left + _scale ? to : left + _scale) -
            (from > left ? from : left);
        if (overlap > 0) coverage[row * target + col] += overlap / area;
      }
    }
  }
  return coverage;
}

/// Renders the mark at `target` pixels square.
///
/// `background` is null for the transparent layers and an opaque grey level
/// for the launcher tile, where the glyph has to sit on something.
Image _render(int target, double glyphScale, {int? background}) {
  final coverage = _coverage(target, glyphScale);
  final out = Image(width: target, height: target, numChannels: 4);
  for (var y = 0; y < target; y++) {
    for (var x = 0; x < target; x++) {
      final ink = coverage[y * target + x].clamp(0.0, 1.0);
      if (background == null) {
        out.setPixelRgba(x, y, 255, 255, 255, (ink * 255).round());
      } else {
        // Composite over the tile here rather than shipping a transparent
        // glyph: the tile is what iOS uses, and iOS icons carry no alpha.
        final value = (background + (255 - background) * ink).round();
        out.setPixelRgba(x, y, value, value, value, 255);
      }
    }
  }
  return out;
}

void main() {
  for (final entry in _buckets.entries) {
    final directory = Directory(
      'android/app/src/main/res/drawable-${entry.key}',
    );
    directory.createSync(recursive: true);
    File('${directory.path}/ic_notification.png')
        .writeAsBytesSync(encodePng(_render(entry.value, _notificationScale)));
  }

  // Both launcher assets come from the same drawing rather than a second
  // source, so changing the mark is one edit. flutter_launcher_icons consumes
  // these PNGs and writes the per-density copies itself.
  final assets = Directory('assets/icon');
  assets.createSync(recursive: true);
  File('${assets.path}/omp-remote.png')
      .writeAsBytesSync(encodePng(_render(1024, 1, background: 0)));
  File('${assets.path}/omp-remote-foreground.png')
      .writeAsBytesSync(encodePng(_render(1024, _adaptiveScale)));

  // The notification icon is named as a Dart string, so the release build's
  // resource shrinker finds no reference to it and strips it, leaving
  // notifications with a blank icon. This tells it to keep the drawable.
  final rawDir = Directory('android/app/src/main/res/raw');
  rawDir.createSync(recursive: true);
  File('${rawDir.path}/keep.xml').writeAsStringSync(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<resources xmlns:tools="http://schemas.android.com/tools"\n'
    '    tools:keep="@drawable/ic_notification" />\n',
  );

  stdout.writeln(
    'wrote ic_notification.png in ${_buckets.length} density buckets, '
    'the launcher tile, the adaptive foreground, and res/raw/keep.xml',
  );
}
