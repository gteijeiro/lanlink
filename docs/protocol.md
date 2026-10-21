# Protocolo LanLink v1

Todos los sistemas ejecutan el mismo código de protocolo en Dart. Un dispositivo escucha en TCP `47829` y anuncia sus direcciones IPv4 en un QR `lanlink://pair/<base64url-json>`. El JSON incluye versión, identificador de dispositivo, nombre, direcciones, puerto y una clave aleatoria de invitación de 256 bits.

## Emparejamiento

El lector del QR envía `POST /pair` con su identificador, nombre, puerto y 32 bytes aleatorios, cifrados con AES-256-GCM mediante la clave del QR. El anfitrión pide permiso al usuario. Si acepta, responde con su identificador, nombre y otros 32 bytes aleatorios, también cifrados. Ambos derivan la clave permanente del par con HMAC-SHA-256 sobre los dos valores aleatorios, los identificadores y un contexto de versión. La clave queda en el almacenamiento seguro del sistema. El anfitrión invalida la invitación después de aceptarla.

El QR debe compartirse solo con el dispositivo que se desea vincular. Quien lo obtenga mientras está vigente podría solicitar emparejamiento, sujeto a la aceptación del anfitrión. El protocolo actual no ofrece secreto futuro si se registra el tráfico y más tarde se revela la clave del QR.

## Transferencia

1. `POST /offer`: el emisor identificado envía nombre saneado, tamaño y SHA-256 dentro de un sobre AES-GCM autenticado. El receptor acepta o rechaza.
2. El receptor devuelve un identificador aleatorio de transferencia dentro de un sobre cifrado.
3. `POST /chunk`: el emisor envía bloques de hasta 128 KiB cifrados con nonce aleatorio. El identificador de transferencia y el desplazamiento se incluyen como datos autenticados adicionales. El receptor solo acepta el siguiente desplazamiento esperado.
4. Al completar el tamaño anunciado, el receptor verifica SHA-256 y renombra el archivo temporal al nombre final. Si falla, borra el temporal.

El cuerpo de cada mensaje es JSON; los bytes cifrados se codifican con base64url. Este formato simplifica la interoperabilidad inicial y añade sobrecarga de tamaño. Una versión futura puede transportar bloques binarios sin cambiar el modelo de emparejamiento.

## Límites actuales

- Solo IPv4 y red local alcanzable; el QR puede llevar varias direcciones y el lector intenta conectarse a cada una.
- Un archivo por envío, hasta 16 GiB.
- La app debe estar abierta en ambos dispositivos.
- No hay reanudación después de cerrar la app ni descubrimiento automático de una nueva IP.
- La recepción se escribe primero a un archivo `.part`; si una transferencia se interrumpe, el temporal se elimina al volver a abrir la app.
