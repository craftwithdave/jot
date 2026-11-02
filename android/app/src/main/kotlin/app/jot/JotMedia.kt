package app.jot

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Matrix
import android.net.Uri
import android.os.Build
import android.util.LruCache
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Images / videos in notes (`![alt](jot-media:<id>)`, Logic.MEDIA). Each one is two parts on the server, both sealed
 * on the phone (Crypto.sealMedia): "full" (the file) and "thumb" (a small JPEG). On this phone only SEALED copies are
 * kept on disk (cacheDir/media); thumbnails are opened in memory and kept in an LRU cache. The one exception is a
 * video being played: VideoView needs a file, so it is decrypted to cacheDir/media/play-<id> and deleted when the
 * viewer closes (and at the next start, if the app died meanwhile).
 */
object JotMedia {
    sealed class Thumb { object Loading : Thumb(); object Failed : Thumb(); class Ready(val bmp: Bitmap) : Thumb() }

    /** bumped when a thumbnail finished loading (or failed), so the editor redraws */
    val version = MutableStateFlow(0)
    private val mem = object : LruCache<String, Bitmap>(32 * 1024 * 1024) { override fun sizeOf(k: String, v: Bitmap) = v.allocationByteCount }
    private val failed = ConcurrentHashMap.newKeySet<String>()
    private val loading = ConcurrentHashMap.newKeySet<String>()
    @Volatile private var dir: File? = null

    private const val FULL_PX = 2048; private const val THUMB_PX = 640
    private const val CACHE_MAX = 300L * 1024 * 1024

    private fun dir(ctx: Context): File = dir ?: synchronized(this) {
        dir ?: File(ctx.cacheDir, "media").also { d ->
            d.mkdirs()
            d.listFiles()?.forEach { if (it.name.startsWith("play-") || it.name.endsWith(".tmp")) it.delete() }   // left by a crash
            val files = d.listFiles()?.sortedBy { it.lastModified() } ?: emptyList()
            var total = files.sumOf { it.length() }
            for (f in files) { if (total <= CACHE_MAX) break; total -= f.length(); f.delete() }
            dir = d
        }
    }
    private fun keys(): Pair<ByteArray, String> {
        val k = Jot.repo.key ?: throw IllegalStateException("locked")
        val a = Jot.repo.auth ?: throw IllegalStateException("locked")
        return k to a
    }

    /** the sealed part, from the disk cache or the server (then cached; parts never change) */
    private fun sealed(ctx: Context, id: String, part: String, progress: ((Long, Long) -> Unit)? = null): ByteArray {
        val f = File(dir(ctx), "$id.$part")
        if (f.exists()) { f.setLastModified(System.currentTimeMillis()); return f.readBytes() }
        val bytes = Api.getBytes("/api/media/$id?part=$part", keys().second, progress)
        val tmp = File(f.path + ".tmp"); tmp.writeBytes(bytes); tmp.renameTo(f)
        return bytes
    }
    private fun open(ctx: Context, id: String, part: String, progress: ((Long, Long) -> Unit)? = null) =
        Crypto.openMedia(keys().first, id, part, sealed(ctx, id, part, progress))

    /** a thumbnail, loading it in the background the first time (version bumps when done) */
    fun thumb(ctx: Context, id: String): Thumb {
        mem.get(id)?.let { return Thumb.Ready(it) }
        if (id in failed) return Thumb.Failed
        if (loading.add(id)) {
            val app = ctx.applicationContext
            Jot.scope.launch(Dispatchers.IO) {
                try {
                    val bmp = decode(open(app, id, "thumb"), THUMB_PX) ?: throw IllegalStateException("not an image")
                    mem.put(id, bmp)
                } catch (e: Exception) { failed.add(id) }
                loading.remove(id)
                version.value++
            }
        }
        return Thumb.Loading
    }
    /** a new note screen tries failed thumbnails again (e.g. offline before) */
    fun retryFailed() { if (failed.isNotEmpty()) { failed.clear(); version.value++ } }

    /** the full image, downsampled to at most [maxPx] on its long side (blocking) */
    fun fullImage(ctx: Context, id: String, maxPx: Int, progress: ((Long, Long) -> Unit)? = null): Bitmap =
        decode(open(ctx, id, "full", progress), maxPx) ?: throw IllegalStateException("not an image")

    /** the full video decrypted into a temp file for playback (blocking); delete it with [discard] */
    fun videoFile(ctx: Context, id: String, progress: (Long, Long) -> Unit): File {
        val plain = Crypto.openMedia(keys().first, id, "full", Api.getBytes("/api/media/$id?part=full", keys().second, progress))
        val f = File(dir(ctx), "play-$id.mp4")
        f.writeBytes(plain)
        return f
    }
    fun discard(f: File?) { f?.delete() }

    private fun decode(bytes: ByteArray, maxPx: Int): Bitmap? {
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, o)
        if (o.outWidth <= 0 || o.outHeight <= 0) return null
        var sample = 1
        while (maxOf(o.outWidth, o.outHeight) / (sample * 2) >= maxPx) sample *= 2
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
    }

    // ---- adding an image ----

    /** a picked / pasted image → JPEGs (full ≤ 2048 px q85, thumb ≤ 640 px q75), sealed and uploaded; returns the
     *  new media id to put in the note (blocking; throws when anything fails, then nothing should be inserted) */
    fun upload(ctx: Context, uri: Uri): String {
        val (dk, auth) = keys()
        val src = load(ctx, uri, FULL_PX)
        val full = jpeg(src, 85)
        val thumb = jpeg(scaled(src, THUMB_PX), 75)
        val id = Crypto.newId()
        val sealedThumb = Crypto.sealMedia(dk, id, "thumb", thumb)
        for ((part, bytes) in listOf("full" to Crypto.sealMedia(dk, id, "full", full), "thumb" to sealedThumb)) {
            val code = Api.putBytes("/api/media/$id?part=$part", auth, bytes)
            if (code != 200 && code != 409) throw HttpError(code, when (code) { 413 -> "image too big"; 507 -> "server storage full"; else -> "upload failed (HTTP $code)" })
        }
        // ready to show without a download
        runCatching { File(dir(ctx), "$id.thumb").writeBytes(sealedThumb) }
        decode(thumb, THUMB_PX)?.let { mem.put(id, it) }
        return id
    }

    private fun load(ctx: Context, uri: Uri, maxPx: Int): Bitmap {
        if (Build.VERSION.SDK_INT >= 28) {
            return ImageDecoder.decodeBitmap(ImageDecoder.createSource(ctx.contentResolver, uri)) { dec, info, _ ->
                val w = info.size.width; val h = info.size.height
                val k = minOf(1f, maxPx.toFloat() / maxOf(w, h))
                if (k < 1f) dec.setTargetSize(maxOf(1, (w * k).toInt()), maxOf(1, (h * k).toInt()))
                dec.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        }
        val bytes = ctx.contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: throw IllegalStateException("can't read the image")
        var bmp = decode(bytes, maxPx) ?: throw IllegalStateException("not an image")
        val rot = runCatching {
            when (android.media.ExifInterface(bytes.inputStream()).getAttributeInt(android.media.ExifInterface.TAG_ORIENTATION, 1)) {
                6 -> 90f; 3 -> 180f; 8 -> 270f; else -> 0f
            }
        }.getOrDefault(0f)
        if (rot != 0f) bmp = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, Matrix().apply { postRotate(rot) }, true)
        return scaled(bmp, maxPx)
    }
    private fun scaled(b: Bitmap, maxPx: Int): Bitmap {
        val k = maxPx.toFloat() / maxOf(b.width, b.height)
        return if (k >= 1f) b else Bitmap.createScaledBitmap(b, maxOf(1, (b.width * k).toInt()), maxOf(1, (b.height * k).toInt()), true)
    }
    private fun jpeg(b: Bitmap, q: Int): ByteArray {
        var src = b
        if (b.hasAlpha()) {   // transparent PNGs: white behind, not black
            src = Bitmap.createBitmap(b.width, b.height, Bitmap.Config.ARGB_8888)
            Canvas(src).apply { drawColor(Color.WHITE); drawBitmap(b, 0f, 0f, null) }
        }
        return ByteArrayOutputStream().also { src.compress(Bitmap.CompressFormat.JPEG, q, it) }.toByteArray()
    }
}
