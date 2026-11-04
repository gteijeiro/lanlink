# LanLink

Aplicación instalada para enviar archivos directamente por una red local entre Android, iOS, Windows, macOS y Linux. No usa navegador, cuenta ni servidor externo.

## Estado

La app permite encontrar equipos visibles en la red local y conectarse sin QR, o emparejar dos equipos con una invitación QR. En ambos casos el receptor acepta o rechaza la solicitud. Se puede enviar un archivo por vez, ver el progreso y exportar los archivos recibidos. El contenido y los nombres de los archivos se cifran con AES-256-GCM usando una clave diferente para cada par de dispositivos. Cada bloque se autentica con su posición y el archivo terminado se comprueba con SHA-256.

La cámara para leer QR funciona en Android, iOS y macOS. En Windows y Linux se puede pegar el enlace contenido en el QR. Todos los sistemas pueden **mostrar** un QR. El enlace es una invitación secreta de un solo uso; no debe publicarse ni enviarse a personas desconocidas.

## Uso

1. Instalá y abrí LanLink en los dos dispositivos, conectados a la misma red Wi-Fi o Ethernet.
   LanLink propone un nombre visible a partir del equipo. Podés cambiarlo con el lápiz junto a **Este dispositivo**; el cambio se guarda para los próximos inicios y anuncios en la red.
2. Para aparecer en otros equipos, activá **Visible en la red**. La opción queda guardada y solo anuncia el equipo mientras LanLink está abierto. Viene desactivada inicialmente.
3. En el otro equipo, elegí **Conectar** en **Disponibles en mi red**. También podés seguir usando **Mostrar mi QR** y **Escanear QR**.
4. Aceptá el emparejamiento en el dispositivo receptor.
5. En **Mis dispositivos**, elegí **Enviar archivo** y aceptá la solicitud en el receptor.
6. El archivo queda en **LanLink Recibidos**, dentro de los documentos de la app. En Android e iOS, usá el botón de compartir para guardarlo en otra ubicación; en escritorio, el botón de exportar abre un diálogo para elegir destino.

Las dos aplicaciones deben permanecer abiertas durante la transferencia. Si cambia la red o la IP, LanLink busca otra vez al equipo guardado y comprueba su identidad con la clave secreta del vínculo antes de actualizar su dirección. Al menos uno de los dos equipos debe tener **Visible en la red** activado. La indicación **Identidad verificada** señala que la dirección se autenticó en esta sesión; el nombre o la IP publicados por Bonjour no bastan para identificar un equipo. El puerto TCP usado es `47829`; el firewall del equipo debe permitir conexiones locales a la app. Bonjour/mDNS debe poder circular por la red; algunas redes de invitados aíslan los dispositivos. En Linux se necesita el servicio Avahi. La aplicación no incluye todavía transferencia entre redes distintas, reanudación de envíos interrumpidos ni recepción en segundo plano.

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

El protocolo v1 está descrito en [docs/protocol.md](docs/protocol.md). Usa HTTP sobre TCP para transportar mensajes cifrados por la propia aplicación. Aunque la conexión HTTP local no emplea TLS, el emparejamiento cercano usa X25519 y cada mensaje de archivo se protege con AES-256-GCM. El anuncio Bonjour contiene una clave pública temporal, nunca una clave secreta. La app guarda las claves de pares en el almacenamiento seguro del sistema. La aprobación por nombre no protege frente a un atacante activo que suplante anuncios en la red; para redes que no sean de confianza, preferí el QR. Este protocolo todavía no tiene auditoría externa; no se presenta como listo para datos de alta sensibilidad.

La clave guardada de un dispositivo vinculado nunca se sustituye por otra solo porque un anuncio de red use el mismo identificador. Si uno de los equipos perdió su clave, hay que usar **Olvidar dispositivo** en ambos y vincularlos de nuevo. Para el primer vínculo en una red no confiable, usá QR: el emparejamiento por proximidad todavía requiere una verificación visual mutua para resistir a un intermediario activo. Un atacante que controle la red puede impedir o retransmitir conexiones, aunque no puede descifrar ni autenticar mensajes sin la clave del par.

La publicación en las tiendas y la elección de licencia del proyecto se decidirán por separado.
