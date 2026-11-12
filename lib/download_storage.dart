import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

final temporaryDownloadSuffix = RegExp(r'\.[A-Za-z0-9_-]{22}\.part$');

class ReceivedDownload {
  ReceivedDownload(this.name, this.location, this.modified);
  final String name;
  final String location;
  final DateTime modified;
}

/// Mobile platforms publish completed files through their system storage APIs.
/// Unverified bytes remain private until the transfer's hash has been checked.
class DownloadStorage {
  DownloadStorage({this.overrideDirectory});
  final Directory? overrideDirectory;
  static const _channel = MethodChannel('lanlink/downloads');
  Directory? _directory;
  String label = 'Descargas/LanLink';
  Future<void> _publication = Future.value();
  bool get _native =>
      overrideDirectory == null && (Platform.isAndroid || Platform.isIOS);

  Future<Directory> get stagingDirectory async {
    if (_directory != null) return _directory!;
    if (overrideDirectory != null) {
      _directory = overrideDirectory;
    } else if (_native) {
      _directory = Directory(
        '${(await getApplicationSupportDirectory()).path}/incoming',
      );
    } else {
      final downloads = await getDownloadsDirectory();
      if (downloads == null) {
        throw StateError('El sistema no indicó una carpeta de descargas.');
      }
      _directory = Directory('${downloads.path}/LanLink');
      label = _directory!.path;
    }
    await _directory!.create(recursive: true);
    return _directory!;
  }

  Future<void> initialize() async {
    await stagingDirectory;
    if (_native) label = (await _channel.invokeMethod<String>('initialize'))!;
    if (overrideDirectory == null) {
      final legacy = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/LanLink Recibidos',
      );
      if (await legacy.exists()) {
        await for (final entry in legacy.list(followLinks: false)) {
          if (entry is File && !temporaryDownloadSuffix.hasMatch(entry.path)) {
            await publish(entry, entry.uri.pathSegments.last);
          }
        }
      }
    }
  }

  Future<void> chooseDirectory() async {
    if (!Platform.isIOS) return;
    final selected = await _channel.invokeMethod<String>('chooseDirectory');
    if (selected != null) label = selected;
  }

  Future<void> publish(File source, String name) {
    final result = _publication.then((_) => _publish(source, name));
    _publication = result.catchError((Object _) {});
    return result;
  }

  Future<void> _publish(File source, String name) async {
    if (_native) {
      await _channel.invokeMethod<String>('publish', {
        'path': source.path,
        'name': name,
      });
      await source.delete();
    } else {
      final directory = await stagingDirectory;
      final destination = await uniqueFile(directory, name);
      if (source.parent.path == directory.path) {
        await source.rename(destination.path);
      } else {
        // Copy privately first: failed migrations leave the original intact and
        // never expose a partial file among completed downloads.
        final staging = await directory.createTemp('.lanlink-migration-');
        try {
          final copy = await source.copy('${staging.path}/download');
          await copy.rename(destination.path);
          await source.delete();
        } finally {
          await staging.delete(recursive: true);
        }
      }
    }
  }

  Future<List<ReceivedDownload>> list() async {
    final List<ReceivedDownload> files;
    if (_native) {
      final rows = await _channel.invokeListMethod<dynamic>('list') ?? [];
      files = rows
          .map(
            (dynamic row) => ReceivedDownload(
              row['name'] as String,
              row['location'] as String,
              DateTime.fromMillisecondsSinceEpoch(
                (row['modified'] as num).toInt(),
              ),
            ),
          )
          .toList();
    } else {
      final dir = await stagingDirectory;
      files = [];
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is File && !temporaryDownloadSuffix.hasMatch(entry.path)) {
          files.add(
            ReceivedDownload(
              entry.uri.pathSegments.last,
              entry.path,
              await entry.lastModified(),
            ),
          );
        }
      }
    }
    files.sort((a, b) => b.modified.compareTo(a.modified));
    return files;
  }

  Future<XFile> forExport(ReceivedDownload file) async {
    if (!_native) return XFile(file.location);
    final path = await _channel.invokeMethod<String>('export', {
      'location': file.location,
    });
    return XFile(path!, name: file.name);
  }

  static Future<File> uniqueFile(Directory dir, String name) async {
    var candidate = File('${dir.path}/$name');
    var index = 1;
    while (await FileSystemEntity.type(candidate.path) !=
        FileSystemEntityType.notFound) {
      candidate = File('${dir.path}/$index-$name');
      index++;
    }
    return candidate;
  }
}
