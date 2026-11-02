package app.jot

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** The real server: BuildConfig.ORIGIN (your own server). Blocking calls: use them off the main thread. */
object Api : Server {
    override fun call(method: String, path: String, auth: String?, json: JSONObject?): Pair<Int, JSONObject> {
        val c = URL(BuildConfig.ORIGIN + path).openConnection() as HttpURLConnection
        try {
            c.requestMethod = method; c.connectTimeout = 15_000; c.readTimeout = 60_000; c.useCaches = false
            auth?.let { c.setRequestProperty("Authorization", "Bearer $it") }
            if (json != null) {
                val payload = json.toString().toByteArray()
                c.doOutput = true
                c.setRequestProperty("Content-Type", "application/json")
                c.setFixedLengthStreamingMode(payload.size)
                c.outputStream.use { it.write(payload) }
            }
            val code = c.responseCode
            val text = (if (code in 200..299) c.inputStream else c.errorStream)?.use { String(it.readBytes()) } ?: ""
            return code to (runCatching { JSONObject(text) }.getOrDefault(JSONObject()))
        } finally { c.disconnect() }
    }

    /** raw bytes (sealed media); [progress] gets (bytes so far, total or -1). Throws HttpError on a non-200 answer. */
    fun getBytes(path: String, auth: String, progress: ((Long, Long) -> Unit)? = null): ByteArray {
        val c = URL(BuildConfig.ORIGIN + path).openConnection() as HttpURLConnection
        try {
            c.connectTimeout = 15_000; c.readTimeout = 60_000; c.useCaches = false
            c.setRequestProperty("Authorization", "Bearer $auth")
            if (c.responseCode != 200) throw HttpError(c.responseCode, "HTTP ${c.responseCode}")
            val total = c.contentLengthLong
            c.inputStream.use { inp ->
                if (total in 0..Int.MAX_VALUE) {                     // known size: one buffer, no copies
                    val out = ByteArray(total.toInt()); var n = 0
                    while (n < out.size) {
                        val r = inp.read(out, n, minOf(65536, out.size - n)); if (r < 0) break
                        n += r; progress?.invoke(n.toLong(), total)
                    }
                    if (n != out.size) throw java.io.IOException("download cut off")
                    return out
                }
                val out = java.io.ByteArrayOutputStream(); val buf = ByteArray(65536)
                while (true) { val r = inp.read(buf); if (r < 0) break; out.write(buf, 0, r); progress?.invoke(out.size().toLong(), -1) }
                return out.toByteArray()
            }
        } finally { c.disconnect() }
    }

    /** uploads raw bytes (sealed media); returns the HTTP status */
    fun putBytes(path: String, auth: String, bytes: ByteArray): Int {
        val c = URL(BuildConfig.ORIGIN + path).openConnection() as HttpURLConnection
        try {
            c.requestMethod = "PUT"; c.connectTimeout = 15_000; c.readTimeout = 120_000; c.useCaches = false
            c.setRequestProperty("Authorization", "Bearer $auth")
            c.setRequestProperty("Content-Type", "application/octet-stream")
            c.doOutput = true
            c.setFixedLengthStreamingMode(bytes.size)
            c.outputStream.use { it.write(bytes) }
            val code = c.responseCode
            runCatching { (if (code in 200..299) c.inputStream else c.errorStream)?.use { it.readBytes() } }
            return code
        } finally { c.disconnect() }
    }

    /**
     * Server-Sent Events: blocks until the stream ends or the connection is disconnected from another thread.
     * [onConn] gets the connection (to disconnect it), [onOpen] once connected, [onEvent] for each event.
     */
    fun events(auth: String, onConn: (HttpURLConnection) -> Unit, onOpen: () -> Unit, onEvent: (JSONObject) -> Unit) {
        val c = URL(BuildConfig.ORIGIN + "/api/events").openConnection() as HttpURLConnection
        onConn(c)
        try {
            c.connectTimeout = 15_000; c.readTimeout = 90_000; c.useCaches = false   // the server pings every 25 s
            c.setRequestProperty("Authorization", "Bearer $auth")
            c.setRequestProperty("Accept", "text/event-stream")
            if (c.responseCode != 200) throw HttpError(c.responseCode, "events: HTTP ${c.responseCode}")
            onOpen()
            val data = StringBuilder()
            c.inputStream.bufferedReader().use { r ->
                while (true) {
                    val line = r.readLine() ?: break
                    if (line.isEmpty()) {
                        if (data.isNotEmpty()) { runCatching { onEvent(JSONObject(data.toString())) }; data.setLength(0) }
                    } else if (line.startsWith("data: ")) {
                        if (data.isNotEmpty()) data.append('\n')
                        data.append(line.substring(6))
                    }
                }
            }
        } finally { c.disconnect() }
    }
}
