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
6. El archivo queda en **Descargas/LanLink** (en Android, **Download/LanLink**). En iPhone, el destino inicial está en **Archivos → En mi iPhone → LanLink → Downloads/LanLink**; para usar la carpeta Descargas de iCloud u otra ubicación, tocá **Elegir carpeta Descargas** y seleccioná esa carpeta una vez. LanLink crea la subcarpeta **LanLink** y conserva la autorización. iOS no permite elegir automáticamente una carpeta ajena a la app. En Android e iOS, usá el botón de compartir para guardarlo en otra ubicación; en escritorio, el botón de exportar abre un diálogo para elegir destino.

Las dos aplicaciones deben permanecer abiertas durante la transferencia. Si cambia la red o la IP, LanLink busca otra vez al equipo guardado y comprueba su identidad con la clave secreta del vínculo antes de actualizar su dirección. Al menos uno de los dos equipos debe tener **Visible en la red** activado. La indicación **Identidad verificada** señala que la dirección se autenticó en esta sesión; el nombre o la IP publicados por Bonjour no bastan para identificar un equipo. El puerto TCP usado es `47829`; el firewall del equipo debe permitir conexiones locales a la app. Bonjour/mDNS debe poder circular por la red; algunas redes de invitados aíslan los dispositivos. En Linux se necesita el servicio Avahi. La aplicación no incluye todavía transferencia entre redes distintas, reanudación de envíos interrumpidos ni recepción en segundo plano.

Los archivos recibidos con versiones anteriores se migran al nuevo destino al abrir la app. No se sobrescriben archivos con el mismo nombre. En Android moderno se publica cada archivo verificado con MediaStore, sin pedir acceso a todo el almacenamiento; las transferencias incompletas quedan privadas.

## Vinculación con clave y equipos de confianza

En el botón de la llave de la barra superior, activá **Permitir vinculación con clave**. LanLink genera una clave aleatoria de 256 bits con prefijo `LL1-`, guardada en el almacenamiento seguro del sistema. Copiala al otro equipo: en **Disponibles en mi red → Conectar**, pegala y elegí **Vincular con clave**. El receptor no pide confirmación. Ambos equipos deben estar abiertos en la misma red y el receptor debe tener **Visible en la red** activado. La clave nunca se anuncia por Bonjour ni se envía en texto claro. Podés desactivarla o renovarla; eso conserva los vínculos existentes. La clave no es una contraseña corta elegida a mano.

En **Mis dispositivos → Opciones → Aceptar archivos automáticamente**, podés marcar un equipo como de confianza. Solo ese receptor aceptará automáticamente sus ofertas autenticadas. Los vínculos nuevos y los guardados por versiones anteriores piden aprobación por defecto. **Pedir aprobación para archivos** desactiva la confianza.

**Desvincular en ambos equipos** elimina inmediatamente el vínculo y su confianza en este equipo y envía una notificación autenticada al otro. Si está desconectado, LanLink conserva una notificación pendiente y la reintenta cuando vuelve a encontrarlo, incluso después de reiniciar. Ambos deben usar esta versión o una posterior. Los archivos recibidos se conservan. Al desvincular, también se renueva la clave general de vinculación si estaba activada, para impedir que el equipo eliminado vuelva a entrar con una copia de esa clave. Los demás vínculos no se borran.

## Desarrollo

Requiere Flutter 3.47 o posterior. No se genera una versión web.

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d macos    # o windows, linux, android, ios
```

Las compilaciones de iOS y macOS requieren Xcode en un Mac. Android requiere Android SDK; Windows requiere Visual Studio con el entorno de C++; Linux requiere las bibliotecas de desarrollo de Flutter. Los identificadores de paquete generados por Flutter siguen siendo provisionales y deben configurarse antes de distribuir la app.

Para las pruebas en Android, el flujo manual **Android de prueba firmado** usa una clave de firma estable guardada fuera del repositorio y como secretos de GitHub Actions. Instalar por primera vez esta versión sobre un APK de depuración con otra firma requiere desinstalar aquel APK; las siguientes versiones generadas por este flujo pueden actualizarse sin borrar los vínculos. La clave de prueba no debe usarse para publicar en una tienda.

Para actualizar la app de macOS sin volver a pedir acceso al llavero en cada compilación, firmá todas las versiones locales con el **mismo certificado** y conservá el identificador `com.example.lanlink`. Las compilaciones ad hoc cambian de identidad con cada versión. En el Mac que tiene el certificado, consultá `security find-identity -p codesigning -v` y ejecutá:

```sh
export LANLINK_MACOS_SIGNING_IDENTITY=SHA1_DEL_CERTIFICADO_APPLE_DEVELOPMENT
export LANLINK_MACOS_TEAM_ID=ID_DEL_EQUIPO_APPLE
./scripts/build_macos_signed.sh
```

El paquete queda en `build/macos-signed/dist/LanLink-macOS-signed.zip`. El script comprueba la firma también después de extraer el ZIP. No se guardan certificados ni claves privadas en el repositorio. Al pasar desde una versión ad hoc a la primera firmada, macOS puede pedir autorización **una vez** para el elemento existente del llavero; elegí **Permitir siempre** e ingresá la contraseña directamente en el diálogo del sistema. Las siguientes actualizaciones firmadas con ese mismo certificado deberían mantener el permiso. Esta firma de desarrollo es para instalaciones locales; la distribución pública fuera del Mac requiere su propio proceso de firma y notarización.

## Protocolo y seguridad

El protocolo v1 está descrito en [docs/protocol.md](docs/protocol.md). Usa HTTP sobre TCP para transportar mensajes cifrados por la propia aplicación. Aunque la conexión HTTP local no emplea TLS, el emparejamiento cercano usa X25519 y cada mensaje de archivo se protege con AES-256-GCM. El anuncio Bonjour contiene una clave pública temporal, nunca una clave secreta. La app guarda las claves de pares en el almacenamiento seguro del sistema. La aprobación por nombre no protege frente a un atacante activo que suplante anuncios en la red; para redes que no sean de confianza, preferí el QR. Este protocolo todavía no tiene auditoría externa; no se presenta como listo para datos de alta sensibilidad.

La clave guardada de un dispositivo vinculado nunca se sustituye por otra solo porque un anuncio de red use el mismo identificador. Si uno de los equipos perdió su clave, hay que desvincular el equipo anterior y vincularlo de nuevo. Para el primer vínculo en una red no confiable, usá QR: el emparejamiento por proximidad todavía requiere una verificación visual mutua para resistir a un intermediario activo. Un atacante que controle la red puede impedir o retransmitir conexiones, aunque no puede descifrar ni autenticar mensajes sin la clave del par.

La publicación en las tiendas y la elección de licencia del proyecto se decidirán por separado.
