# Ensayo AirDrop Android sin root

APK nativo aislado del producto LanLink. Intenta verificar los prerrequisitos
reales desde un UID de aplicación normal: un enlace AWDL utilizable o acceso
al radio que permita implementar ese enlace. No necesita una firma de Apple.
No instala módulos, no cambia SELinux, no usa `su`, no escribe en particiones
del sistema y no anuncia un receptor AirDrop incapaz de recibir archivos.

Incluye un intento real de abrir `AF_PACKET/SOCK_RAW` que se cierra sin leer ni
inyectar tramas, consulta pública de Wi-Fi Aware y enumeración de interfaces.
También implementa descubrimiento público BLE de registros AirDrop y búsqueda
DNS-SD `_airdrop._tcp`. Solo conserva contadores, sin nombres, MAC, hashes de
contactos ni contenido de anuncios. Los resultados se guardan en el contenedor
privado de esta app; no se suben a GitHub.

**Esto no es una implementación completa de AirDrop ni una prueba de que una
transferencia funcione.** Una interfaz Wi-Fi Aware, un anuncio BLE o un socket
permitido no se confunden con compatibilidad AirDrop. La prueba de transferencia
queda `NOT_RUN` mientras no haya un enlace compatible verificado. La ausencia de
ese enlace en la app tampoco demuestra incapacidad física del chip.

## Compilar y probar

En GitHub Actions, ejecutar **Prueba AirDrop Android sin root** para la referencia
a evaluar. Genera un APK depurable con ID `com.example.lanlink.airdropprobe`;
no reemplaza LanLink. También se puede usar Gradle 9.3.1 y Android SDK 36:

```sh
cd experiments/rootless-airdrop
gradle :app:assembleDebug
```

Con un teléfono propio autorizado en ADB:

```sh
adb install -r -g app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.example.lanlink.airdropprobe/.ProbeActivity --ez scan true
# Esperar a que termine el barrido de 15 segundos.
adb exec-out run-as com.example.lanlink.airdropprobe cat files/report.json
```

`-g` concede únicamente los permisos de ejecución declarados en este APK:
Bluetooth para descubrir y ubicación en versiones antiguas de Android.
`run-as` permite leer el informe privado de este APK depurable sin root; los
experimentos se ejecutan en el UID normal de la aplicación.

Para una prueba controlada de anuncios AirDrop, mantener un iPhone propio
cercano con Wi-Fi/Bluetooth activos y AirDrop visible. Cero anuncios sin un
emisor conocido no demuestra una falla del teléfono. Descubrir anuncios tampoco
prueba el enlace Wi-Fi ni una transferencia.

## Fuentes revisadas

- [OpenDrop](https://github.com/seemoo-lab/opendrop): requiere enlace AWDL.
- [OWL](https://github.com/seemoo-lab/owl): utiliza acceso directo al radio.
- [Mosey/Bada](https://github.com/FeelLiao/mosey-bada): depende de KernelSU y piezas del sistema.
- [AirDrop-for-Everything](https://github.com/BenItBuhner/AirDrop-for-Everything): diferencia transporte LAN de AWDL en Android.

El código de este ensayo es propio. No incorpora código GPL, bibliotecas
propietarias extraídas de firmware ni módulos de los proyectos citados.
