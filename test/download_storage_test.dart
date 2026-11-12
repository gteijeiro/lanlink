import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/download_storage.dart';

void main() {
  test(
    'Publicar conserva archivos con el mismo nombre y oculta los incompletos',
    () async {
      final root = await Directory.systemTemp.createTemp('lanlink-downloads-');
      addTearDown(() => root.delete(recursive: true));
      final downloads = DownloadStorage(
        overrideDirectory: Directory('${root.path}/Downloads/LanLink'),
      );
      await downloads.initialize();
      final first = await File('${root.path}/first').writeAsString('primero');
      final second = await File('${root.path}/second').writeAsString('segundo');
      await Future.wait([
        downloads.publish(first, 'archivo.txt'),
        downloads.publish(second, 'archivo.txt'),
      ]);
      final dir = await downloads.stagingDirectory;
      await File('${dir.path}/oculto.${'a' * 22}.part')
          .writeAsString('incompleto');
      final rows = await downloads.list();
      expect(rows.map((row) => row.name).toSet(), {
        'archivo.txt',
        '1-archivo.txt',
      });
      expect(await File('${dir.path}/archivo.txt').readAsString(), 'primero');
      expect(await File('${dir.path}/1-archivo.txt').readAsString(), 'segundo');
      expect(await first.exists(), false);
      expect(await second.exists(), false);
    },
  );

  test('Una publicación fallida deja el original disponible', () async {
    final root = await Directory.systemTemp.createTemp(
      'lanlink-download-error-',
    );
    addTearDown(() => root.delete(recursive: true));
    final original = await File('${root.path}/original')
        .writeAsString('conservar');
    final blocker = await File('${root.path}/blocker')
        .writeAsString('no es directorio');
    final downloads = DownloadStorage(
      overrideDirectory: Directory(blocker.path),
    );
    await expectLater(
      downloads.publish(original, 'archivo.txt'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await original.readAsString(), 'conservar');
  });
}
