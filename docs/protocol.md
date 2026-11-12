# Protocolo LanLink v1

Todos los sistemas ejecutan el mismo código de protocolo en Dart. Un dispositivo escucha en TCP `47829` y anuncia sus direcciones IPv4 en un QR `lanlink://pair/<base64url-json>`. El JSON incluye versión, identificador de dispositivo, nombre, direcciones, puerto y una clave aleatoria de invitación de 256 bits. Cuando el usuario activa **Visible en la red**, la app también anuncia `_lanlink._tcp` mediante Bonjour/mDNS con identificador, nombre y una clave pública X25519 temporal en el registro TXT. Las otras instancias buscan ese servicio y presentan los equipos encontrados.

## Emparejamiento

El lector del QR envía `POST /pair` con su identificador, nombre, puerto y 32 bytes aleatorios, cifrados con AES-256-GCM mediante la clave del QR. El anfitrión pide permiso al usuario. Si acepta, responde con su identificador, nombre y otros 32 bytes aleatorios, también cifrados. Ambos derivan la clave permanente del par con HMAC-SHA-256 sobre los dos valores aleatorios, los identificadores y un contexto de versión. La clave queda en el almacenamiento seguro del sistema. El anfitrión invalida la invitación después de aceptarla.

El QR debe compartirse solo con el dispositivo que se desea vincular. Quien lo obtenga mientras está vigente podría solicitar emparejamiento, sujeto a la aceptación del anfitrión. El protocolo actual no ofrece secreto futuro si se registra el tráfico y más tarde se revela la clave del QR.

En el emparejamiento sin QR, el solicitante genera otra clave X25519 temporal y envía su clave pública junto con una solicitud cifrada a `POST /pair-nearby`. Ambos calculan un secreto compartido que no se publica ni viaja por la red. El receptor confirma la solicitud y responde cifrado; cada lado deriva y guarda una clave propia del par. El receptor rota su clave pública temporal después de aceptar. El nombre del solicitante no constituye prueba de identidad: un atacante activo podría suplantar anuncios o interponerse en la conexión. Para redes que no sean de confianza, preferí el QR. Una futura versión debería añadir verificación mutua con un código corto antes de confiar en un nuevo dispositivo.

Un identificador ya vinculado no puede volver a emparejarse ni reemplazar su clave mientras siga guardado. Para renovar un vínculo perdido, el usuario debe olvidarlo explícitamente en ambos equipos.

## Reconexión tras cambiar de red

El anuncio mDNS aporta direcciones candidatas, pero no se considera una prueba de identidad. Para cada candidato con un identificador ya vinculado, el cliente pide un desafío aleatorio de 256 bits a `POST /identify/start`. En `POST /identify/finish` envía otro valor aleatorio de 256 bits y un HMAC-SHA-256 calculado con la clave secreta del par. El HMAC cubre ambos identificadores, ambos desafíos, el nombre y el puerto. El receptor comprueba el HMAC, que el desafío no se haya usado ni expirado, y que la respuesta provenga de la misma dirección que lo solicitó. Solo entonces actualiza la dirección del par. Su respuesta incluye otro HMAC con una etiqueta de dominio distinta, por lo que el cliente también verifica al receptor antes de guardar la dirección nueva. Las comparaciones de HMAC se hacen en tiempo constante. Los desafíos caducan a los 30 segundos y se limitan a 64 simultáneos.

La clave simétrica de 256 bits ya se guarda en el almacenamiento seguro de cada plataforma. El cambio de dirección no crea una clave nueva ni depende de la IP o del nombre anunciado. Si ambos equipos están en otra red local alcanzable, al menos uno debe anunciarse con **Visible en la red** para que el otro lo encuentre. Esto no ofrece transferencia entre redes aisladas ni protección contra denegación de servicio o retransmisión en tiempo real por un intermediario.

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
- No hay reanudación después de cerrar la app. La IP de un par guardado se actualiza automáticamente solo después de la autenticación mutua y cuando mDNS permite encontrarlo en la red local.
- La recepción se escribe primero a un archivo `.part`; si una transferencia se interrumpe, el temporal se elimina al volver a abrir la app.


## Vinculación por clave, confianza y revocación (1.1)

`POST /pair-key` usa el intercambio X25519 de proximidad, pero mezcla su secreto con una clave aleatoria de 256 bits mediante HMAC-SHA-256 y un dominio que incluye el identificador receptor. Los mensajes AES-GCM usan AAD `pair-key-request-v1` y `pair-key-response-v1`, distintos del flujo manual. La clave general no se anuncia, no viaja por la red y no se usa directamente como clave de los pares. Las claves por par se derivan del secreto autenticado y de dos valores aleatorios nuevos; el receptor rota su clave X25519 temporal tras cada vínculo. Hay un máximo global de 10 intentos de este endpoint por minuto; el QR manual sigue disponible. Nunca se sustituye la clave de un identificador ya vinculado.

La confianza para aceptar archivos es una preferencia local por vínculo (`trustedForFiles`, falsa por defecto). La autenticación y validación de cada oferta ocurren antes de considerar esa preferencia. No otorga permisos de lectura, ejecución ni confianza a otros vínculos.

`POST /unpair` recibe `{peer, box}`. Su clave se deriva con HMAC-SHA-256 de la clave del par, el dominio `lanlink-revoke-key-v1` y ambos identificadores ordenados. La solicitud AES-GCM (AAD `revoke-request-v1`) contiene `from`, `to` y un nonce aleatorio de 32 bytes. La respuesta (AAD `revoke-response-v1`) devuelve esos identificadores invertidos, el mismo nonce y `revoked: true`. El emisor elimina el vínculo local antes de intentar la entrega; conserva solo la clave derivada para revocar y una cola persistente de notificaciones. Esa clave derivada no sirve para descifrar archivos ni para autenticarse como un par activo.

El receptor guarda un recibo duradero para contestar reintentos si se perdió la respuesta. Un recibo de una sesión vieja no puede borrar una sesión nueva con otra clave. La cola vuelve a intentar por la última dirección y por los candidatos de descubrimiento que coinciden con el identificador; una dirección anunciada no basta para confirmar la entrega. Las escrituras de metadatos se serializan y se reemplazan mediante archivos temporales. Los vínculos anteriores sobreviven a la actualización y no pasan a ser de confianza automáticamente. La desvinculación renueva la clave general local si estaba habilitada; no afecta a otros pares ya vinculados.
