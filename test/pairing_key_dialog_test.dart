import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanlink/pairing_key_dialog.dart';
import 'package:lanlink/pairing_password.dart';
import 'package:lanlink/transfer_service.dart';

class SettingsService extends TransferService {
  String? value;
  final saved = <String>[];
  SettingsService() {
    deviceName = 'Equipo de prueba';
  }
  @override
  String? get pairingKey => value;
  @override
  Future<String> setPairingKey(String password) async {
    validatePairingPassword(password);
    saved.add(password);
    value = password;
    return password;
  }

  @override
  Future<void> disablePairingKey() async {
    value = null;
  }

  @override
  Future<String> enablePairingKey() => setPairingKey(generatePairingPassword());
}

void main() {
  late SettingsService service;
  setUp(() {
    service = SettingsService();
  });
  tearDown(() => service.dispose());

  Future<void> open(WidgetTester tester, {PairingKeyShare? share}) async {
    tester.view.physicalSize = const Size(1000, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PairingKeyDialog(service: service, share: share),
        ),
      ),
    );
  }

  testWidgets(
    'Se guarda una clave muy débil de seis caracteres; cinco no habilitan Guardar',
    (tester) async {
      await open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('pairing-key-input')),
        '12345',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Guardar y activar'),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('pairing-key-input')),
        '123456',
      );
      await tester.pump();
      expect(find.text('Fortaleza: Muy débil'), findsOneWidget);
      await tester.tap(find.text('Guardar y activar'));
      await tester.pumpAndSettle();
      expect(service.saved, ['123456']);
      expect(find.text('Clave guardada y activada.'), findsOneWidget);
    },
  );

  testWidgets(
    'Compartir usa la clave guardada y se desactiva si hay cambios sin guardar',
    (tester) async {
      service.value = '123456';
      String? shared;
      Rect? origin;
      await open(
        tester,
        share: (text, rect) async {
          shared = text;
          origin = rect;
        },
      );
      await tester.ensureVisible(find.text('Compartir'));
      await tester.tap(find.text('Compartir'));
      await tester.pumpAndSettle();
      expect(shared, contains('Equipo de prueba'));
      expect(shared, endsWith('\n123456'));
      expect(origin!.isEmpty, false);
      await tester.enterText(
        find.byKey(const ValueKey('pairing-key-input')),
        'otra clave',
      );
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Compartir'))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'Si no se puede compartir, se ofrece Copiar y la clave permanece guardada',
    (tester) async {
      service.value = '123456';
      await open(
        tester,
        share: (_, _) async {
          throw UnsupportedError('Sin servicio');
        },
      );
      await tester.ensureVisible(find.text('Compartir'));
      await tester.tap(find.text('Compartir'));
      await tester.pumpAndSettle();
      expect(
        find.text('Este sistema no pudo abrir Compartir. Podés usar Copiar.'),
        findsOneWidget,
      );
      expect(service.value, '123456');
    },
  );

  testWidgets('Generar crea una clave corta como borrador', (tester) async {
    await open(tester);
    await tester.tap(find.text('Generar clave corta'));
    await tester.pump();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('pairing-key-input')),
    );
    expect(field.controller!.text.length, 12);
    expect(service.saved, isEmpty);
  });
}
