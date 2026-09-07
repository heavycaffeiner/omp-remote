// Generates the Android notification small icon in every density bucket.
//
// Android tints a small icon from its alpha channel alone, so this draws the
// mark as opaque white on a transparent canvas. The launcher icon cannot stand
// in: it is an opaque tile, which tints to a solid square. The adaptive
// foreground cannot either: it is an opaque white square whose glyph is only a
// faint value difference, which tints to the same block.
//
// The shapes are drawn here rather than rasterized from assets/icon/
// omp-remote.svg because no Dart SVG rasterizer is available offline. The
// coordinates below are the same 1024 grid that file uses, minus its
// background tile, so a change to the mark means changing both.
//
// This runs in CI, where ImageMagick is not installed and res/drawable is
// regenerated and gitignored. The `image` package arrives with
// flutter_launcher_icons.

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart';

const _buckets = <String, int>{
  'mdpi': 24,
  'hdpi': 36,
  'xhdpi': 48,
  'xxhdpi': 72,
  'xxxhdpi': 96,
};

// Supersampling factor. Drawing at 8x and averaging down is what gives the
// strokes clean edges at 24 pixels.
const _scale = 8;
const _grid = 1024.0;
const _glyphScale = 0.82;

class _Canvas {
  _Canvas(this.size) : coverage = List<double>.filled(size * size, 0);

  final int size;
  final List<double> coverage;

  // Maps a point on the 1024 design grid to canvas pixels, applying the same
  // centred scale the SVG uses.
  double _map(double v) => ((v - _grid / 2) * _glyphScale + _grid / 2) / _grid * size;

  void _mark(int x, int y) {
    if (x < 0 || y < 0 || x >= size || y >= size) return;
    coverage[y * size + x] = 1;
  }

  // Round-capped line, which is every stroke in this mark.
  void line(double x1, double y1, double x2, double y2, double width) {
    final ax = _map(x1), ay = _map(y1), bx = _map(x2), by = _map(y2);
    final radius = width / 2 * _glyphScale / _grid * size;
    final steps = math.max(2, (math.sqrt(math.pow(bx - ax, 2) + math.pow(by - ay, 2)) * 2).ceil());
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      _disc(ax + (bx - ax) * t, ay + (by - ay) * t, radius);
    }
  }

  void arc(double cx, double cy, double r, double from, double to, double width) {
    final mcx = _map(cx), mcy = _map(cy);
    final mr = r * _glyphScale / _grid * size;
    final radius = width / 2 * _glyphScale / _grid * size;
    final steps = math.max(8, (mr * 3).ceil());
    for (var i = 0; i <= steps; i++) {
      final angle = from + (to - from) * (i / steps);
      _disc(mcx + math.cos(angle) * mr, mcy + math.sin(angle) * mr, radius);
    }
  }

  void _disc(double cx, double cy, double r) {
    final minX = (cx - r).floor(), maxX = (cx + r).ceil();
    final minY = (cy - r).floor(), maxY = (cy + r).ceil();
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        final dx = x + 0.5 - cx, dy = y + 0.5 - cy;
        if (dx * dx + dy * dy <= r * r) _mark(x, y);
      }
    }
  }
}

// Draws the mark at the supersampled size, then box-filters down to `target`.
Image _render(int target) {
  final canvas = _Canvas(target * _scale);

  // Pi: crossbar, left stem, right stem with its foot.
  canvas.line(300, 330, 724, 330, 78);
  canvas.line(424, 330, 424, 596, 78);
  canvas.line(626, 330, 626, 554, 78);
  canvas.arc(668, 554, 42, math.pi, math.pi / 2, 78);
  canvas.line(668, 596, 696, 596, 78);

  // Two signal arcs beneath it, drawn as the lower half of each circle.
  canvas.arc(512, 700, 122, math.pi * 0.18, math.pi * 0.82, 54);
  canvas.arc(512, 786, 258, math.pi * 0.22, math.pi * 0.78, 54);

  final out = Image(width: target, height: target, numChannels: 4);
  final area = _scale * _scale;
  for (var y = 0; y < target; y++) {
    for (var x = 0; x < target; x++) {
      var hits = 0;
      for (var sy = 0; sy < _scale; sy++) {
        for (var sx = 0; sx < _scale; sx++) {
          final px = x * _scale + sx, py = y * _scale + sy;
          if (canvas.coverage[py * canvas.size + px] > 0) hits++;
        }
      }
      out.setPixelRgba(x, y, 255, 255, 255, (hits / area * 255).round());
    }
  }
  return out;
}

void main() {
  for (final entry in _buckets.entries) {
    final directory = Directory('android/app/src/main/res/drawable-${entry.key}');
    directory.createSync(recursive: true);
    File('${directory.path}/ic_notification.png')
        .writeAsBytesSync(encodePng(_render(entry.value)));
  }

  // The icon is named as a Dart string, so the release build's resource
  // shrinker finds no reference to it and strips it, leaving notifications
  // with a blank icon. This tells it to keep the drawable.
  final rawDir = Directory('android/app/src/main/res/raw');
  rawDir.createSync(recursive: true);
  File('${rawDir.path}/keep.xml').writeAsStringSync(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<resources xmlns:tools="http://schemas.android.com/tools"\n'
    '    tools:keep="@drawable/ic_notification" />\n',
  );

  stdout.writeln('wrote ic_notification.png in ${_buckets.length} density buckets, plus res/raw/keep.xml');
}
