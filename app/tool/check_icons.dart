// Asserts the generated launcher icons are actually visible.
//
// The adaptive foreground is composited over a flat background color by the
// system. A fully opaque foreground therefore hides that background entirely,
// which is how a white square with a barely-visible glyph shipped once: the
// icon looked blank on a device while every build step reported success.

import 'dart:io';

import 'package:image/image.dart';

const _res = 'android/app/src/main/res';

int _fail(String message) {
  stderr.writeln('icon check failed: $message');
  return 1;
}

/// Mean alpha across the image, 0 (fully transparent) to 1 (fully opaque).
///
/// Converts first: a grayscale-with-alpha PNG reports `pixel.a` as zero,
/// which would read as an empty icon no matter what it contains.
double _alphaMean(Image source) {
  final image = source.convert(numChannels: 4);
  var total = 0.0;
  for (final pixel in image) {
    total += pixel.a / pixel.maxChannelValue;
  }
  return total / (image.width * image.height);
}

void main() {
  var failures = 0;

  final foreground = File('$_res/drawable-xxxhdpi/ic_launcher_foreground.png');
  if (!foreground.existsSync()) {
    failures += _fail('${foreground.path} is missing');
  } else {
    final image = decodePng(foreground.readAsBytesSync());
    if (image == null) {
      failures += _fail('${foreground.path} could not be decoded');
    } else {
      final alpha = _alphaMean(image);
      // A line-art glyph covers a small fraction of its canvas. Anything near
      // fully opaque is a filled rectangle, not a mark.
      if (alpha > 0.5) {
        failures += _fail(
          'adaptive foreground is ${(alpha * 100).toStringAsFixed(1)} percent opaque, '
          'so it covers the background instead of sitting on it',
        );
      }
      if (alpha < 0.005) {
        failures += _fail('adaptive foreground is effectively empty');
      }
    }
  }

  final notification = File('$_res/drawable-xxxhdpi/ic_notification.png');
  if (!notification.existsSync()) {
    failures += _fail('${notification.path} is missing');
  } else {
    final image = decodePng(notification.readAsBytesSync());
    if (image == null) {
      failures += _fail('${notification.path} could not be decoded');
    } else {
      final alpha = _alphaMean(image);
      // Android tints this from its alpha alone, so an opaque one is a block.
      if (alpha > 0.5) {
        failures += _fail('notification icon is opaque and will tint to a solid square');
      }
      if (alpha < 0.005) {
        failures += _fail('notification icon is effectively empty');
      }
    }
  }

  if (failures > 0) exit(1);
  stdout.writeln('launcher and notification icons look drawable');
}
