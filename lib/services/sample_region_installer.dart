import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Installs the checked-in sample as a complete private region directory.
Future<void> installBucegiSample() async {
  final support = await getApplicationSupportDirectory();
  final regions = Directory('${support.path}${Platform.pathSeparator}regions');
  await regions.create(recursive: true);
  final target = Directory('${regions.path}${Platform.pathSeparator}bucegi');
  final nonce = DateTime.now().microsecondsSinceEpoch;
  final staged = Directory(
    '${regions.path}${Platform.pathSeparator}.bucegi-import-$nonce',
  );
  final backup = Directory(
    '${regions.path}${Platform.pathSeparator}.bucegi-backup-$nonce',
  );
  await staged.create();
  try {
    for (final filename in [
      'map.pmtiles',
      'terrain.pmtiles',
      'search.sqlite',
      'package.json',
      'manifest.json',
      'OSM-LICENSE.txt',
    ]) {
      final data = await rootBundle.load('samples/bucegi/$filename');
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      await File(
        '${staged.path}${Platform.pathSeparator}$filename',
      ).writeAsBytes(bytes, flush: true);
    }
    if (!await target.exists()) {
      await staged.rename(target.path);
      return;
    }
    final manifest = File(
      '${target.path}${Platform.pathSeparator}manifest.json',
    );
    final terrain = File(
      '${target.path}${Platform.pathSeparator}terrain.pmtiles',
    );
    if (!await manifest.exists() ||
        !await terrain.exists() ||
        !(await manifest.readAsString()).contains(
          '24b51fbeb6bfa747e7c8438a58d60e6af891218fdc1e15829c93c85a2251b026',
        )) {
      throw StateError(
        'Existing Bucegi region is not the bundled terrain sample',
      );
    }
    await target.rename(backup.path);
    try {
      await staged.rename(target.path);
    } catch (_) {
      await backup.rename(target.path);
      rethrow;
    }
    // The old bundled sample can be discarded after the replacement is visible.
    try {
      await backup.delete(recursive: true);
    } catch (_) {
      // A hidden backup is harmless and can be removed during later maintenance.
    }
  } catch (_) {
    if (await staged.exists()) await staged.delete(recursive: true);
    rethrow;
  }
}
