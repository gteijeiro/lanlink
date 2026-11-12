package com.example.lanlink

import android.Manifest
import android.content.ContentValues
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var pendingPermission: MethodChannel.Result? = null
    private val relativePath = "${Environment.DIRECTORY_DOWNLOADS}/LanLink/"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lanlink/downloads")
            .setMethodCallHandler { call, result ->
                if (call.method == "initialize" && Build.VERSION.SDK_INT < 29 &&
                    checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
                    if (pendingPermission != null) {
                        result.error("busy", "Ya hay una solicitud de permiso abierta.", null)
                    } else {
                        pendingPermission = result
                        requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), 4782)
                    }
                } else {
                    worker.execute {
                        try {
                            val value = handleDownloads(call)
                            runOnUiThread { result.success(value) }
                        } catch (error: Exception) {
                            runOnUiThread { result.error("downloads", error.message, null) }
                        }
                    }
                }
            }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4782) {
            val result = pendingPermission
            pendingPermission = null
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
                result?.success("Download/LanLink")
            } else {
                result?.error("permission", "Hace falta permiso para guardar en Download/LanLink.", null)
            }
        }
    }

    private fun legacyDirectory(): File {
        @Suppress("DEPRECATION")
        val directory = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "LanLink")
        check(directory.isDirectory || directory.mkdirs()) { "No se pudo crear Download/LanLink." }
        return directory
    }

    private fun safeName(name: String): String {
        require(name.isNotBlank() && name != "." && name != ".." && !name.contains('/') && !name.contains('\\'))
        return name
    }

    private fun uniqueFile(directory: File, name: String): File {
        var file = File(directory, name)
        var index = 1
        while (file.exists()) file = File(directory, "${index++}-$name")
        return file
    }

    private fun handleDownloads(call: MethodCall): Any? = when (call.method) {
        "initialize" -> "Download/LanLink"
        "publish" -> {
            val source = File(call.argument<String>("path")!!)
            val name = safeName(call.argument<String>("name")!!)
            if (Build.VERSION.SDK_INT >= 29) {
                val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, MimeTypeMap.getSingleton()
                        .getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream")
                    put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(collection, values) ?: error("No se pudo crear la descarga.")
                try {
                    contentResolver.openOutputStream(uri, "w")!!.use { out -> source.inputStream().use { it.copyTo(out) } }
                    val published = contentResolver.update(uri, ContentValues().apply {
                        put(MediaStore.MediaColumns.IS_PENDING, 0)
                    }, null, null)
                    check(published == 1) { "No se pudo publicar la descarga." }
                    uri.toString()
                } catch (error: Exception) {
                    contentResolver.delete(uri, null, null)
                    throw error
                }
            } else {
                val file = uniqueFile(legacyDirectory(), name)
                try { source.copyTo(file) } catch (error: Exception) { file.delete(); throw error }
                MediaScannerConnection.scanFile(this, arrayOf(file.path), null, null)
                file.path
            }
        }
        "list" -> {
            if (Build.VERSION.SDK_INT >= 29) {
                val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                val rows = mutableListOf<Map<String, Any>>()
                contentResolver.query(collection, arrayOf("_id", "_display_name", "date_modified"),
                    "relative_path = ? AND is_pending = 0", arrayOf(relativePath), "date_modified DESC")?.use { cursor ->
                    while (cursor.moveToNext()) rows.add(mapOf(
                        "name" to cursor.getString(1),
                        "location" to Uri.withAppendedPath(collection, cursor.getLong(0).toString()).toString(),
                        "modified" to cursor.getLong(2) * 1000
                    ))
                }
                rows
            } else {
                legacyDirectory().listFiles()?.filter { it.isFile }?.map {
                    mapOf("name" to it.name, "location" to it.path, "modified" to it.lastModified())
                } ?: emptyList<Map<String, Any>>()
            }
        }
        "export" -> {
            val location = call.argument<String>("location")!!
            if (Build.VERSION.SDK_INT >= 29) {
                val uri = Uri.parse(location)
                require(uri.scheme == "content" && uri.authority == MediaStore.AUTHORITY)
                val name = contentResolver.query(uri, arrayOf("_display_name", "relative_path"), null, null, null)!!.use {
                    check(it.moveToFirst() && it.getString(1) == relativePath)
                    safeName(it.getString(0))
                }
                val directory = File(cacheDir, "exports/${java.util.UUID.randomUUID()}").apply { mkdirs() }
                val file = File(directory, name)
                contentResolver.openInputStream(uri)!!.use { input -> file.outputStream().use { input.copyTo(it) } }
                file.path
            } else {
                val file = File(location).canonicalFile
                require(file.parentFile == legacyDirectory().canonicalFile)
                file.path
            }
        }
        else -> error("Operación de descargas desconocida.")
    }
}
