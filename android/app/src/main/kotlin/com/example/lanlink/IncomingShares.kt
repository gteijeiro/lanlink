package com.example.lanlink

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class IncomingShares(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "lanlink/incoming")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val pending = mutableListOf<Map<String, Any>>()
    private var ready = false
    private val root get() = File(context.cacheDir, "shared-incoming")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "drain" -> { ready = true; result.success(pending.toList()); pending.clear() }
                "release" -> {
                    val token = call.arguments as? String
                    if (token != null && Regex("[a-f0-9-]{36}").matches(token)) worker.execute { File(root, token).deleteRecursively() }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        worker.execute {
            root.mkdirs()
            root.listFiles()?.filter { it.isDirectory && System.currentTimeMillis() - it.lastModified() > 48L * 3600 * 1000 }?.forEach { it.deleteRecursively() }
        }
    }

    fun accept(intent: Intent?) {
        if (intent == null || intent.action !in listOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) return
        val uris: List<Uri> = if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) ?: emptyList()
            else @Suppress("DEPRECATION") (intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList())
        } else {
            val uri = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                else @Suppress("DEPRECATION") intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            listOfNotNull(uri)
        }
        if (uris.isEmpty()) return
        // The Intent owns the transient read grant. Copy now, before it expires.
        worker.execute {
            val token = UUID.randomUUID().toString()
            val directory = File(root, token)
            try {
                require(uris.size <= 100) { "Podés compartir hasta 100 archivos." }
                directory.mkdirs()
                var totalBytes = 0L
                val files = uris.mapIndexed { index, uri ->
                    require(uri.scheme == "content") { "El origen del archivo no es válido." }
                    var name = "archivo-${index + 1}"
                    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                        if (it.moveToFirst() && !it.isNull(0)) name = it.getString(0)
                    }
                    name = name.substringAfterLast('/').substringAfterLast('\\').replace(Regex("[<>:\"|?*\\x00-\\x1f]"), "_").trim().takeLast(120)
                    if (name.isEmpty() || name == "." || name == "..") name = "archivo-${index + 1}"
                    val sub = File(directory, index.toString()).apply { mkdirs() }
                    val file = File(sub, name)
                    var bytes = 0L
                    context.contentResolver.openInputStream(uri)!!.use { source ->
                        file.outputStream().use { output ->
                            val buffer = ByteArray(128 * 1024)
                            while (true) {
                                val count = source.read(buffer)
                                if (count < 0) break
                                bytes += count
                                totalBytes += count
                                require(totalBytes <= 16L * 1024 * 1024 * 1024) { "El envío supera 16 GiB." }
                                require(bytes <= 16L * 1024 * 1024 * 1024) { "El archivo supera 16 GiB." }
                                require(StatFs(directory.path).availableBytes > count + 64L * 1024 * 1024) { "No hay espacio para preparar los archivos." }
                                output.write(buffer, 0, count)
                            }
                        }
                    }
                    mapOf("path" to file.path, "name" to name)
                }
                val batch = mapOf("token" to token, "files" to files)
                main.post { if (ready) channel.invokeMethod("files", listOf(batch)) else pending.add(batch) }
            } catch (error: Exception) {
                directory.deleteRecursively()
                main.post {
                    val message = "No se pudieron preparar los archivos compartidos: ${error.message}"
                    if (ready) channel.invokeMethod("error", message) else pending.add(mapOf("error" to message))
                }
            }
        }
    }
}
