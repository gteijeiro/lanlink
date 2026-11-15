import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

class SharedBatch {
  SharedBatch(this.files, {this.token});
  final List<XFile> files;
  final String? token;
}

class IncomingShares {
  static const channel = MethodChannel('lanlink/incoming');
  void Function(SharedBatch batch)? onBatch;
  void Function(String message)? onError;

  Future<void> start(List<String> arguments) async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'files') _receive(call.arguments);
      if (call.method == 'error') onError?.call(call.arguments.toString());
      if (call.method == 'arguments') {
        await _arguments((call.arguments as List).cast<String>());
      }
    });
    try {
      _receive(await channel.invokeMethod<dynamic>('drain'));
    } on MissingPluginException {
      /* Linux uses desktop file arguments. */
    }
    await _arguments(arguments);
  }

  void _receive(dynamic raw) {
    if (raw is! List) return;
    for (final value in raw) {
      if (value is Map && value['error'] is String) {
        onError?.call(value['error']);
        continue;
      }
      if (value is! Map || value['files'] is! List) continue;
      final files = <XFile>[];
      for (final item in (value['files'] as List).take(100)) {
        if (item is Map && item['path'] is String && item['name'] is String) {
          files.add(XFile(item['path'], name: item['name']));
        }
      }
      if (files.isNotEmpty) {
        onBatch?.call(SharedBatch(files, token: value['token'] as String?));
      }
    }
  }

  Future<void> _arguments(List<String> arguments) async {
    final files = <XFile>[];
    for (final argument in arguments.take(102)) {
      if (argument.startsWith('-')) continue;
      final uri = Uri.tryParse(argument);
      final path = uri?.scheme == 'file'
          ? uri!.toFilePath(windows: Platform.isWindows)
          : argument;
      if (!File(path).isAbsolute) continue;
      if (await FileSystemEntity.type(path, followLinks: true) ==
          FileSystemEntityType.file) {
        files.add(XFile(path));
      }
    }
    if (files.isNotEmpty && files.length <= 100) {
      onBatch?.call(SharedBatch(files));
    }
  }

  Future<void> release(SharedBatch batch) async {
    if (batch.token == null) return;
    try {
      await channel.invokeMethod<void>('release', batch.token);
    } on MissingPluginException {
      /* Arguments reference the user's original files: never delete them. */
    }
  }

  void dispose() => channel.setMethodCallHandler(null);
}
