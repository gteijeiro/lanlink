# Compartir con LanLink y desplegar 1.4

## Qué incorpora

Desde Galería/Fotos/Archivos, seleccioná uno o varios archivos, tocá **Compartir → LanLink**, elegí el equipo y compará el código de seis cifras en las dos pantallas. El receptor debe abrir LanLink y activar **Recibir cerca** (diez minutos), o tener **Visible en la red** para recibir por LAN. El receptor acepta la oferta y el emisor confirma que el código coincide. No se crea un vínculo guardado ni se modifica la confianza de los dispositivos existentes. Ambas apps deben mantenerse abiertas; en Apple también puede enviarse desde la propia extensión Compartir.

LanLink elige la red local, Wi-Fi directa entre equipos Apple o su propio transporte Bluetooth LE según lo que descubre. En **Otras opciones del sistema** podés abrir el menú nativo y elegir AirDrop, Quick Share o las alternativas que ofrezca el sistema. Esas opciones las gestiona el sistema operativo y pueden requerir su propia configuración.

| Transporte | Requisitos y alcance |
| --- | --- |
| Red local | Cualquier combinación de plataformas en una LAN que permita conexiones entre equipos; no necesita Internet. |
| Wi-Fi directa Apple | iPhone/Mac con Wi-Fi encendida, permiso de red local y LanLink compatible. Usa Network.framework con `includePeerToPeer`, sin una Wi-Fi compartida. |
| Bluetooth LE LanLink | Sin Wi-Fi compartida. Requiere Bluetooth, permisos y un adaptador con las funciones necesarias. El receptor necesita modo periférico/GATT; el emisor necesita modo central. Windows/Linux dependen del adaptador y sus controladores. |
| AirDrop / Quick Share / Compartir del sistema | Se elige en el menú del sistema. No constituye un protocolo universal ni garantiza comunicación entre todos los sistemas. |

Bluetooth es más lento, especialmente con videos. Si no hay ningún transporte compatible disponible se muestra el problema; no se simula un envío exitoso. No se implementa Wi-Fi Direct universal Android/Windows/Linux, transferencia por Internet ni recepción permanente en segundo plano. La selección automática prioriza los transportes disponibles al elegir el destino; si falla un envío se puede reintentar, no se promete cambiar de radio a mitad del archivo.

**Estado de verificación:** las pruebas automáticas cubren el protocolo, la integridad de archivos, el código de confirmación, cancelación, límites, repetición de acuses y fragmentación Bluetooth. Existe un vector común CryptoKit/Dart. Compilar no verifica las radios reales ni la aparición del menú Compartir en un teléfono. La comprobación con dispositivos físicos queda para después del despliegue del usuario.

## Despliegue desde tu Mac

El script no usa modelos ni APIs de IA. Cada dispositivo se procesa independientemente; un iPhone bloqueado no impide actualizar los demás. Conserva configuración y vínculos. Si encuentra una firma incompatible, falla sin desinstalar ni borrar los datos.

1. Abrí Terminal y entrá en el repositorio:

   ```sh
   cd "/Users/guille/Documents/Codex/2026-10-20/busca-el-chat-que-dice-x20/outputs/lanlink"
   ```

2. Revisá qué versión y equipos va a procesar, sin instalar:

   ```sh
   python3 scripts/deploy.py --plan
   ```

3. Si solo querés preparar/verificar paquetes, sin conectar equipos:

   ```sh
   python3 scripts/deploy.py --build-only
   ```

   Necesita GitHub CLI autenticado (`gh`), Flutter, Xcode y el certificado de desarrollo ya configurado en este Mac. Android y Windows se compilan en GitHub Actions con el mismo commit del repositorio. iOS necesita una sesión Apple válida para renovar perfiles; no requiere un teléfono conectado para preparar el paquete. El script informa la ubicación exacta de cada artefacto. Preparado no significa instalado ni probado en el dispositivo.

4. Para instalar, dejá Windows iniciado en Parallels, activá Depuración inalámbrica en Android y mantené Android/iPhone desbloqueados. El Mac y los dispositivos deben poder comunicarse para instalar por Wi-Fi; también se puede conectar el iPhone por USB. Ejecutá:

   ```sh
   python3 scripts/deploy.py
   ```

   Si solo querés algunos equipos:

   ```sh
   python3 scripts/deploy.py --devices macos,windows,android
   python3 scripts/deploy.py --devices ios
   ```

5. Si pide intervención, elegí **r** para reintentar, **e** para esperar o **s** para saltear ese dispositivo. La espera tiene un límite de quince minutos por defecto; se puede ajustar con `--wait-timeout 1800`. Si cambiaste de red, Android intenta descubrir la dirección; si no la encuentra, te pide `IP:puerto` y guarda la dirección e identidad verificadas fuera del repositorio. La vinculación ADB inicial, si se perdió, se realiza en Android/Terminal con el código del teléfono; el script no guarda códigos.

6. Al terminar, mirá el resumen. Los detalles están en `build/deploy/logs/FECHA/summary.json` y un log por equipo. Cada paquete se vincula al commit y se verifica su integridad. El estado `prepared` corresponde a preparar sin instalar; `verified` comprueba instalación/versión/arranque, pero no prueba que hayas enviado una foto.

No hace falta recompilar lo que ya está preparado para ese commit. Usá `--rebuild` solamente si querés regenerar los paquetes locales Apple. El repositorio debe estar limpio y el commit publicado en la referencia indicada (`main` por defecto). Para probar una rama publicada, agregá `--ref NOMBRE_DE_RAMA` a los comandos.

## Habilitar Compartir en cada sistema

### Android

La actualización registra LanLink como destino para uno o varios archivos. En Galería, **Compartir → Más → LanLink**. Permití **Dispositivos cercanos/Bluetooth** al usar conexión directa. Compartir texto o enlaces sin archivos no está incluido en esta versión.

### iPhone

La aplicación incluye una extensión nativa. En Fotos, **Compartir → Más**, habilitá LanLink si no figura inicialmente. Permití Red local y Bluetooth al solicitarlos. El envío se realiza en esa pantalla, sin necesitar abrir la app mediante mecanismos privados. El perfil de desarrollo de Apple puede vencer; si ocurre, el script informa el motivo y debe recompilarse con un perfil renovado.

### Mac

En Finder, seleccioná archivos y elegí **Compartir → LanLink**. Si no figura, habilitá la extensión LanLink en las extensiones de Compartir de Ajustes del sistema. También se acepta **Abrir con → LanLink** o arrastrar archivos al icono de la app. Las nuevas versiones deben conservar certificado, equipo e identificador para mantener la identidad del llavero.

### Windows: un paso adicional, una sola vez

El instalador agrega **Enviar a → LanLink**. Para aparecer además en el panel **Compartir**, Windows exige identidad de paquete. Esta versión de desarrollo incluye el receptor y un manifiesto para registro local. Activá **Modo para desarrolladores** en Configuración de Windows, abrí PowerShell en tu usuario y ejecutá:

```powershell
Add-AppxPackage -Register "$env:LOCALAPPDATA\Programs\LanLink\AppxManifest.xml" -DisableDevelopmentMode:$false
Get-AppxPackage -Name gteijeiro.LanLink
```

También se incluye `Install-WindowsShare.ps1 -RegisterDeveloperPackage` en esa carpeta para realizar el mismo registro. El despliegue general no activa el modo desarrollador ni modifica certificados o políticas de Windows. Si no querés registrar el paquete, seguí usando **Enviar a** o el selector de archivos de LanLink. El registro debe repetirse si movés la instalación; tras actualizar en la misma ruta, verificá que la opción siga disponible.

Este es un registro local de desarrollo; no es un paquete publicado en Microsoft Store ni un MSIX comercial firmado.

### Linux

En el propio Linux, con Flutter y las dependencias de compilación instaladas:

```sh
flutter pub get
flutter build linux --release
python3 scripts/install_linux.py
```

Instala en `~/.local/opt/lanlink` y agrega acciones por usuario: **Abrir con**, **Enviar a** de Thunar, acción de Dolphin y **Scripts** de Nautilus. Puede ser necesario reiniciar el gestor de archivos. Linux no tiene un único panel Compartir universal. La recepción Bluetooth usa BlueZ GATT/D-Bus y requiere un adaptador compatible; no se cambian permisos del sistema ni se enciende el adaptador automáticamente.

## Prueba después de instalar

1. Probá primero un archivo pequeño en la misma red, sin vincular: receptor en **Recibir cerca**, Galería del emisor → Compartir → LanLink; ambos códigos deben coincidir. Rechazá una oferta y comprobá que no se guarde el archivo.
2. Desconectá los equipos de la Wi-Fi compartida, dejando Wi-Fi/Bluetooth encendidos. Repetí: entre Apple debería ofrecer Wi-Fi directa; entre otras combinaciones, Bluetooth cuando el hardware lo permita.
3. Verificá el archivo terminado en Descargas/LanLink o el destino configurado, y abrilo. Comprobá que no aparece un vínculo nuevo en Mis dispositivos.
4. Si falla, guardá el mensaje exacto, la combinación de equipos y el transporte mostrado. Los logs del script corresponden al despliegue, no a la transferencia que hagas después.

## Implementación y fuentes

Sesiones X25519 efímeras con compromisos previos de ambas claves/nonces, HKDF-SHA256 y AES-256-GCM. El código comparado depende de la clave derivada; no se autentica un equipo por su IP o nombre. Los bloques autentican sesión/archivo/posición, el receptor verifica SHA-256 y publica únicamente archivos completos. Se limitan sesiones, intentos, tamaños y tiempos. Los nombres visibles y el descubrimiento no son secretos. La seguridad del envío sin vínculo depende de comparar correctamente el código en ambos equipos; no omitas esa comparación.

- [Apple: elegir la API de red](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)
- [Apple: migrar a Network framework](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)
- [Apple: extensiones Compartir](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html)
- [Microsoft: recibir desde Compartir](https://learn.microsoft.com/en-us/windows/apps/develop/windows-integration/integrate-sharesheet-receive)

Para cambiar las fuentes/targets Apple, `scripts/configure_share_targets.rb` requiere la gema `xcodeproj`; los proyectos generados ya están guardados, no hace falta ejecutar ese generador para desplegar. En un Mac, `bash scripts/check_apple_crypto.sh` verifica el vector nativo, y `flutter test` verifica la misma referencia en Dart.
