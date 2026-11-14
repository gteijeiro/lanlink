import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/discovery_service.dart';
import 'package:lanlink/download_storage.dart';
import 'package:lanlink/transfer_service.dart';
import 'package:lanlink/ui/app_theme.dart';
import 'package:lanlink/ui/lanlink_dashboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final sdk = Platform.environment['FLUTTER_ROOT'];
    if (sdk == null) return;
    final fonts = '$sdk/bin/cache/artifacts/material_fonts';
    for (final (family, files) in [
      (
        'Roboto',
        ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf'],
      ),
      ('MaterialIcons', ['MaterialIcons-Regular.otf']),
    ]) {
      final loader = FontLoader(family);
      for (final name in files) {
        final bytes = await File('$fonts/$name').readAsBytes();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
      }
      await loader.load();
    }
  });

  final files = [
    ReceivedDownload(
      'Vacaciones en la costa.mp4',
      'video',
      DateTime(2026, 11, 14),
    ),
    ReceivedDownload(
      'Atardecer en el mar.heic',
      'image',
      DateTime(2026, 11, 14),
    ),
    ReceivedDownload('Itinerario del viaje.pdf', 'pdf', DateTime(2026, 11, 13)),
    ReceivedDownload('Notas de voz.m4a', 'audio', DateTime(2026, 11, 13)),
    ReceivedDownload('Presupuesto.xlsx', 'sheet', DateTime(2026, 11, 12)),
  ];

  Future<void> open(
    WidgetTester tester,
    Size size, {
    double scale = 1,
    Brightness brightness = Brightness.light,
    ValueChanged<ReceivedDownload>? onOpen,
    ValueChanged<ReceivedDownload>? onExport,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final link = TextEditingController();
    addTearDown(link.dispose);
    final iphone = Peer(
      id: 'iphone',
      name: 'iPhone de Ana',
      host: '192.168.1.20',
      port: 47829,
      trustedForFiles: true,
    )..verified = true;
    final windows = Peer(
      id: 'windows',
      name: 'PC Windows',
      host: '192.168.1.21',
      port: 47829,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: lanLinkTheme(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: const ValueKey('preview'),
          child: LanLinkDashboard(
            deviceName: size.width < 600 ? 'Samsung Galaxy' : 'MacBook de Ana',
            visible: true,
            peers: [iphone, windows],
            nearby: const [
              NearbyDevice(
                NearbyInvitation(
                  id: 'mac',
                  name: 'MacBook Air',
                  hosts: ['192.168.1.22'],
                  port: 47829,
                  publicKey: 'preview',
                ),
              ),
            ],
            files: Future.value(files),
            downloadsLabel: 'Download/LanLink',
            linkController: link,
            onEditName: () {},
            onVisibleChanged: (_) {},
            onShowQr: () {},
            onScanQr: () {},
            onConfigureKey: () {},
            onPairLink: (_) {},
            onPairNearby: (_) {},
            onSend: (_) {},
            onPeerAction: (_, _) {},
            onOpenFile: onOpen ?? (_) {},
            onExportFile: onExport ?? (_) {},
            onClearError: () {},
            canOpenFiles: size.width < 600,
            usesShareSheet: size.width < 600,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (Platform.environment['LANLINK_DESIGN_PREVIEW'] != '1') return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('preview')),
      );
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final folder = Directory('build/design-preview')
        ..createSync(recursive: true);
      await File('${folder.path}/$name.png')
          .writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  testWidgets(
    'Recibidos filtra y mantiene separadas las acciones Abrir y Compartir',
    (tester) async {
      final opened = <String>[];
      final shared = <String>[];
      await open(
        tester,
        const Size(390, 844),
        onOpen: (file) => opened.add(file.location),
        onExport: (file) => shared.add(file.location),
      );
      await screenshot(tester, 'devices-mobile');
      await tester.tap(find.text('Recibidos').last);
      await tester.pumpAndSettle();
      await screenshot(tester, 'files-mobile');
      await tester.enterText(find.byType(TextField), 'vacaciones');
      await tester.pumpAndSettle();
      expect(find.text('Vacaciones en la costa.mp4'), findsOneWidget);
      expect(find.text('Itinerario del viaje.pdf'), findsNothing);
      await tester.ensureVisible(find.text('Abrir con'));
      await tester.tap(find.text('Abrir con'));
      await tester.pumpAndSettle();
      expect(opened, ['video']);
      expect(shared, isEmpty);
      await tester.tap(find.text('Compartir'));
      await tester.pumpAndSettle();
      expect(shared, ['video']);
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.text('Imágenes'));
      await tester.pumpAndSettle();
      expect(find.text('Atardecer en el mar.heic'), findsOneWidget);
      expect(find.text('Vacaciones en la costa.mp4'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'El diseño se adapta a ventanas pequeñas, escritorio y texto grande',
    (tester) async {
      for (final (size, scale, brightness) in [
        (const Size(320, 640), 2.0, Brightness.light),
        (const Size(390, 844), 2.0, Brightness.light),
        (const Size(1000, 600), 2.0, Brightness.light),
        (const Size(1440, 960), 1.0, Brightness.light),
        (const Size(1440, 960), 1.0, Brightness.dark),
      ]) {
        await tester.pumpWidget(const SizedBox());
        await open(tester, size, scale: scale, brightness: brightness);
        expect(
          tester.takeException(),
          isNull,
          reason: 'Dispositivos: $size, texto $scale',
        );
        if (size.width == 1440 && brightness == Brightness.light) {
          await screenshot(tester, 'devices-desktop');
        }
        await tester.tap(find.text('Recibidos').last);
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'Recibidos: $size, texto $scale',
        );
        if (size.width == 1440) {
          await screenshot(
            tester,
            brightness == Brightness.light ? 'files-desktop' : 'files-dark',
          );
        }
      }
    },
  );
}
