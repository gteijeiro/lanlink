# LanLink

Aplicación instalada para enviar archivos directamente por una red local entre Android, iOS, Windows, macOS y Linux. No usa navegador, cuenta ni servidor externo.

## Estado

La primera versión funcional permite emparejar dos equipos con una invitación QR, aceptar o rechazar solicitudes, enviar un archivo por vez, ver el progreso y exportar los archivos recibidos. El contenido y los nombres de los archivos se cifran con AES-256-GCM usando una clave diferente para cada par de dispositivos. Cada bloque se autentica con su posición y el archivo terminado se comprueba con SHA-256.

La cámara para leer QR funciona en Android, iOS y macOS. En Windows y Linux se puede pegar el enlace contenido en el QR. Todos los sistemas pueden **mostrar** un QR. El enlace es una invitación secreta de un solo uso; no debe publicarse ni enviarse a personas desconocidas.

## Uso

1. Instalá y abrí LanLink en los dos dispositivos, conectados a la misma red Wi-Fi o Ethernet.
2. En uno, elegí **Mostrar mi QR**. En el otro, elegí **Escanear QR** o pegá el enlace.
3. Aceptá el emparejamiento en el dispositivo que mostró el QR.
4. En **Mis dispositivos**, elegí **Enviar archivo** y aceptá la solicitud en el receptor.
5. El archivo queda en **LanLink Recibidos**, dentro de los documentos de la app. En Android e iOS, usá el botón de compartir para guardarlo en otra ubicación; en escritorio, el botón de exportar abre un diálogo para elegir destino.

Las dos aplicaciones deben permanecer abiertas durante la transferencia. Si cambia la IP de un equipo, emparejalo de nuevo para actualizar su dirección. El puerto TCP usado es `47829`; el firewall del equipo debe permitir conexiones locales a la app. La aplicación no incluye todavía descubrimiento automático, transferencia entre redes distintas, reanudación de envíos interrumpidos ni recepción en segundo plano.

## Desarrollo

Requiere Flutter 3.47 o posterior. No se genera una versión web.

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d macos    # o windows, linux, android, ios
```

Las compilaciones de iOS y macOS requieren Xcode en un Mac. Android requiere Android SDK; Windows requiere Visual Studio con el entorno de C++; Linux requiere las bibliotecas de desarrollo de Flutter. Los identificadores de paquete generados por Flutter siguen siendo provisionales y deben configurarse antes de distribuir la app.

## Protocolo y seguridad

El protocolo v1 está descrito en [docs/protocol.md](docs/protocol.md). Usa HTTP sobre TCP para transportar mensajes cifrados por la propia aplicación. Aunque la conexión HTTP local no emplea TLS, la invitación y cada mensaje de archivo se protegen con AES-256-GCM. La app guarda las claves de pares en el almacenamiento seguro del sistema. Este protocolo todavía no tiene auditoría externa; no se presenta como listo para datos de alta sensibilidad.

La publicación en las tiendas y la elección de licencia del proyecto se decidirán por separado.
