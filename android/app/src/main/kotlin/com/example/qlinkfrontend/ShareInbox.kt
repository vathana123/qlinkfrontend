package com.example.qlinkfrontend

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import android.widget.Toast
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/** Private, bounded inbox. URI permissions are used immediately, never persisted. */
class ShareInbox(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "qlink/share")
    private val worker = Executors.newSingleThreadExecutor()
    private val root = File(activity.cacheDir, "share-inbox").apply { mkdirs() }
    @Volatile private var closed = false
    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pending" -> worker.execute {
                    evict()
                    val folder = root.listFiles()?.filter { File(it, "ready.json").exists() }?.minByOrNull { it.lastModified() }
                    val value = try { folder?.let { decode(JSONObject(File(it, "ready.json").readText())) } } catch (_: Exception) { null }
                    activity.runOnUiThread { result.success(value) }
                }
                "discard" -> worker.execute {
                    val id = call.arguments as? String
                    if (id != null && runCatching { UUID.fromString(id).toString() == id }.getOrDefault(false)) {
                        val folder = File(root, id)
                        if (folder.canonicalFile.parentFile == root.canonicalFile) folder.deleteRecursively()
                    }
                    activity.runOnUiThread { result.success(null); if (!closed) channel.invokeMethod("available", null) }
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun evict() {
        val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        root.listFiles()?.filter { it.lastModified() < cutoff }?.forEach { it.deleteRecursively() }
    }
    @Suppress("DEPRECATION")
    fun accept(intent: Intent?) {
        if (intent == null || intent.action !in listOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) return
        // Copy extras before clearing the activity intent, preventing rotation/redelivery duplicates.
        val incoming = Intent(intent)
        intent.action = null
        worker.execute {
            evict()
            if ((root.listFiles()?.size ?: 0) >= 4) {
                activity.runOnUiThread { Toast.makeText(activity, "Finish or cancel existing shares before sharing more files.", Toast.LENGTH_LONG).show() }
                return@execute
            }
            val id = UUID.randomUUID().toString()
            val folder = File(root, id).apply { mkdirs() }
            val data = JSONObject().put("id", id)
            try {
                val text = incoming.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() ?: ""
                require(text.length <= 4000) { "Shared text exceeds 4000 characters." }
                data.put("text", text)
                val uris = linkedSetOf<Uri>()
                if (incoming.action == Intent.ACTION_SEND_MULTIPLE) {
                    incoming.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
                } else incoming.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
                incoming.clipData?.let { clip ->
                    require(clip.itemCount <= 10) { "Share up to 10 files." }
                    for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) }
                }
                require(uris.size <= 10) { "Share up to 10 files." }
                require(uris.isNotEmpty() || text.isNotBlank()) { "No supported shared content." }
                val files = JSONArray()
                var total = 0L
                uris.forEachIndexed { index, uri ->
                    // No file:// paths or arbitrary URLs from exported-activity callers.
                    require(uri.scheme == "content") { "The sharing application did not grant a readable content URI." }
                    require(uri.authority?.startsWith(activity.packageName) != true) { "Share files from another application." }
                    var name = "shared-file"
                    activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) name = cursor.getString(0) ?: name
                    }
                    name = name.replace('\\', '/').substringAfterLast('/').take(180)
                    val extensions = setOf("jpg", "jpeg", "png", "gif", "webp", "pdf", "txt", "csv", "json", "doc", "docx", "xls", "xlsx", "ppt", "pptx")
                    val extension = name.substringAfterLast('.', "").lowercase()
                    require(extension in extensions) { "Unsupported shared file type." }
                    val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream"
                    val target = File(folder, "$index.$extension")
                    var size = 0L
                    activity.contentResolver.openInputStream(uri)?.use { input ->
                        target.outputStream().use { output ->
                            val buffer = ByteArray(64 * 1024)
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                size += count; total += count
                                require(size <= 32 * 1024 * 1024 && total <= 64 * 1024 * 1024) { "Shared files exceed the size limit." }
                                output.write(buffer, 0, count)
                            }
                        }
                    } ?: error("The shared file is unavailable.")
                    require(size > 0) { "The shared file is empty." }
                    files.put(JSONObject().put("path", target.absolutePath).put("name", name).put("mime", mime).put("size", size))
                }
                data.put("files", files)
            } catch (e: Exception) {
                folder.listFiles()?.forEach { it.delete() }
                data.remove("files")
                data.put("error", if (e is SecurityException) "Permission to read the shared file expired. Share it again." else if (e is IllegalArgumentException) e.message else "Unable to read the shared file. Share it again.")
            }
            File(folder, "ready.tmp").apply { writeText(data.toString()); renameTo(File(folder, "ready.json")) }
            activity.runOnUiThread { if (!closed) channel.invokeMethod("available", null) }
        }
    }
    private fun decode(json: JSONObject): Map<String, Any?> = json.keys().asSequence().associateWith { key ->
        when (val value = json.get(key)) {
            JSONObject.NULL -> null
            is JSONArray -> (0 until value.length()).map { decode(value.getJSONObject(it)) }
            else -> value
        }
    }
    fun close() { closed = true; channel.setMethodCallHandler(null); worker.shutdown() }
}
