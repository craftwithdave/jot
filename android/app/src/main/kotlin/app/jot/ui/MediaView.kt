package app.jot.ui

import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.media.MediaPlayer
import android.view.Surface
import android.view.TextureView
import androidx.compose.material3.CircularProgressIndicator
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.delay
import android.widget.MediaController
import android.widget.VideoView
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import app.jot.JotMedia
import app.jot.Logic
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * An image / video in a note (tapped thumbnail), shown over the note itself: a dark rounded panel inside the editor
 * screen (like the Mac app), not a separate window. ✕, a tap on the dark area or Back closes it. Images: fit, pinch to
 * zoom, double-tap to reset. Videos: downloaded with progress, decrypted to a temp file, played with VideoView +
 * MediaController; the temp file is deleted when the viewer closes.
 */
@Composable
fun MediaViewer(media: Logic.Media, modifier: Modifier = Modifier, onClose: () -> Unit) {
    val ctx = LocalContext.current
    val density = LocalDensity.current
    val conf = LocalConfiguration.current
    val maxPx = with(density) { maxOf(conf.screenWidthDp, conf.screenHeightDp).dp.roundToPx() }.coerceIn(512, 2048)
    var progress by remember(media.id) { mutableFloatStateOf(-1f) }
    var image by remember(media.id) { mutableStateOf<Bitmap?>(null) }
    var video by remember(media.id) { mutableStateOf<File?>(null) }
    var err by remember(media.id) { mutableStateOf("") }

    LaunchedEffect(media.id) {
        val p: (Long, Long) -> Unit = { n, total -> if (total > 0) progress = n.toFloat() / total }
        try {
            if (media.kind == "video") video = withContext(Dispatchers.IO) { JotMedia.videoFile(ctx, media.id, p) }
            else image = withContext(Dispatchers.IO) { JotMedia.fullImage(ctx, media.id, maxPx, p) }
        } catch (e: kotlinx.coroutines.CancellationException) { throw e }
        catch (e: Exception) { err = "Unavailable" + (e.message?.let { ": $it" } ?: "") }
    }
    DisposableEffect(media.id) { onDispose { JotMedia.discard(video) } }

    BackHandler { onClose() }
    Box(modifier.fillMaxSize().padding(10.dp).clip(RoundedCornerShape(24.dp)).background(Color(0xF50A0A0A))
        .pointerInput(Unit) { detectTapGestures { onClose() } }) {             // the dark area around the media
        val img = image; val vid = video
        Box(Modifier.fillMaxSize().padding(start = 12.dp, end = 12.dp, top = 52.dp, bottom = 12.dp)) {
            when {
                img != null -> ZoomImage(img)
                vid != null -> AndroidView({ c ->
                    VideoView(c).apply {
                        val mc = MediaController(c); mc.setAnchorView(this); setMediaController(mc)
                        setVideoPath(vid.path)
                        setOnPreparedListener { start(); mc.show(2500) }
                        setOnErrorListener { _, _, _ -> err = "Can't play this video"; true }
                    }
                }, Modifier.align(Alignment.Center).fillMaxWidth(), onRelease = { it.stopPlayback() })
                err.isNotEmpty() -> Text(err, Modifier.align(Alignment.Center).padding(24.dp), color = Muted, fontSize = 14.sp)
                else -> Column(Modifier.align(Alignment.Center).width(200.dp), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (progress >= 0f) LinearProgressIndicator({ progress }, Modifier.fillMaxWidth(), color = Ink, trackColor = Color(0x33FFFFFF))
                    else LinearProgressIndicator(Modifier.fillMaxWidth(), color = Ink, trackColor = Color(0x33FFFFFF))
                    Text(if (media.kind == "video") "Loading video…" else "Loading…", color = Muted, fontSize = 13.sp)
                }
            }
        }
        GlassIcon(onClose, Modifier.align(Alignment.TopStart).padding(10.dp)) {
            Icon(Icons.Filled.Close, "Close", Modifier.size(20.dp))
        }
    }
}

@Composable
private fun ZoomImage(bmp: Bitmap) {
    var scale by remember { mutableFloatStateOf(1f) }
    var pan by remember { mutableStateOf(Offset.Zero) }
    val ib = remember(bmp) { bmp.asImageBitmap() }
    Image(ib, null, Modifier.fillMaxSize()
        .pointerInput(Unit) {
            detectTransformGestures { _, p, z, _ ->
                scale = (scale * z).coerceIn(1f, 6f)
                pan = if (scale == 1f) Offset.Zero else pan + p
            }
        }
        .pointerInput(Unit) { detectTapGestures(onDoubleTap = { scale = if (scale > 1f) 1f else 2.5f; pan = Offset.Zero }) }
        .graphicsLayer { scaleX = scale; scaleY = scale; translationX = pan.x; translationY = pan.y },
        contentScale = ContentScale.Fit)
}

/**
 * A video playing right on its thumbnail in the note ([modifier] gives the thumbnail's rect). The full part is
 * downloaded (progress ring over the thumbnail), decrypted to a temp file and played with sound on a TextureView
 * (it clips to the rounded corners and scrolls with the text, unlike SurfaceView / VideoView). Tap = pause / play;
 * a thin progress bar and the remaining time sit at the bottom. Leaving composition (line gone or revealed, note
 * closed, app in the background) releases the player and deletes the temp file. [onDone] = stop it.
 */
@Composable
fun InlineVideo(media: Logic.Media, modifier: Modifier, onDone: () -> Unit) {
    val ctx = LocalContext.current
    var progress by remember { mutableFloatStateOf(-1f) }
    var file by remember { mutableStateOf<File?>(null) }
    var err by remember { mutableStateOf("") }
    var player by remember { mutableStateOf<MediaPlayer?>(null) }
    var rendering by remember { mutableStateOf(false) }
    var paused by remember { mutableStateOf(false) }
    var pos by remember { mutableIntStateOf(0) }
    var dur by remember { mutableIntStateOf(0) }
    val gone = remember { AtomicBoolean(false) }
    val temp = remember { AtomicReference<File?>(null) }

    LaunchedEffect(Unit) {
        try {
            val f = withContext(Dispatchers.IO) {
                val f = JotMedia.videoFile(ctx, media.id) { n, total ->
                    if (gone.get()) throw java.io.InterruptedIOException("stopped")
                    if (total > 0) progress = n.toFloat() / total
                }
                temp.set(f)
                if (gone.get()) { temp.getAndSet(null)?.delete(); null } else f
            }
            file = f
        } catch (e: kotlinx.coroutines.CancellationException) { throw e }
        catch (e: Exception) { err = "unavailable"; delay(2500); onDone() }
    }
    DisposableEffect(Unit) {
        onDispose {
            gone.set(true)
            player?.let { runCatching { it.stop() }; it.release() }; player = null
            temp.getAndSet(null)?.let { JotMedia.discard(it) }
        }
    }
    // position for the progress bar / remaining time
    LaunchedEffect(player, paused) {
        val p = player ?: return@LaunchedEffect
        while (true) { runCatching { pos = p.currentPosition; dur = p.duration }; if (paused) break; delay(250) }
    }

    Box(modifier.clip(RoundedCornerShape(10.dp)).pointerInput(Unit) {
        // consumes the tap, so the note's caret stays where it was
        detectTapGestures { player?.let { p -> runCatching { if (p.isPlaying) { p.pause(); paused = true } else { p.start(); paused = false } } } }
    }) {
        val f = file
        if (f != null) AndroidView({ c ->
            TextureView(c).apply {
                isOpaque = false; alpha = 0f
                surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                    override fun onSurfaceTextureAvailable(st: SurfaceTexture, w: Int, h: Int) {
                        val tv = this@apply
                        val mp = MediaPlayer()
                        try {
                            mp.setDataSource(f.path)
                            mp.setSurface(Surface(st))
                            mp.setOnVideoSizeChangedListener { _, vw, vh ->
                                if (vw > 0 && vh > 0 && tv.width > 0 && tv.height > 0) {   // fit inside the rect, centred
                                    val k = minOf(tv.width.toFloat() / vw, tv.height.toFloat() / vh)
                                    tv.setTransform(Matrix().apply { setScale(vw * k / tv.width, vh * k / tv.height, tv.width / 2f, tv.height / 2f) })
                                }
                            }
                            mp.setOnInfoListener { _, what, _ -> if (what == MediaPlayer.MEDIA_INFO_VIDEO_RENDERING_START) { tv.alpha = 1f; rendering = true }; false }
                            mp.setOnPreparedListener { it.start(); dur = it.duration; paused = false }
                            mp.setOnCompletionListener { paused = true; pos = dur }
                            mp.setOnErrorListener { _, _, _ -> err = "can't play"; onDone(); true }
                            mp.prepareAsync()
                            player = mp
                        } catch (e: Exception) { mp.release(); err = "can't play"; onDone() }
                    }
                    override fun onSurfaceTextureSizeChanged(st: SurfaceTexture, w: Int, h: Int) {}
                    override fun onSurfaceTextureDestroyed(st: SurfaceTexture): Boolean {
                        player?.let { runCatching { it.stop() }; it.release() }; player = null
                        return true
                    }
                    override fun onSurfaceTextureUpdated(st: SurfaceTexture) {}
                }
            }
        }, Modifier.fillMaxSize().background(if (rendering) Color.Black else Color.Transparent))
        when {
            err.isNotEmpty() -> Text(err, Modifier.align(Alignment.Center).clip(RoundedCornerShape(8.dp)).background(Color(0x99000000))
                .padding(horizontal = 8.dp, vertical = 3.dp), color = Color.White, fontSize = 11.sp)
            !rendering -> Box(Modifier.align(Alignment.Center).size(48.dp).clip(RoundedCornerShape(24.dp)).background(Color(0x8C000000)), contentAlignment = Alignment.Center) {
                if (progress in 0f..1f) CircularProgressIndicator({ progress }, Modifier.size(34.dp), color = Color.White, strokeWidth = 3.dp, trackColor = Color(0x33FFFFFF))
                else CircularProgressIndicator(Modifier.size(34.dp), color = Color.White, strokeWidth = 3.dp)
            }
            else -> {
                if (paused) Box(Modifier.align(Alignment.Center).size(44.dp).clip(RoundedCornerShape(22.dp)).background(Color(0x8C000000)), contentAlignment = Alignment.Center) {
                    Text("▶", color = Color.White, fontSize = 18.sp)
                }
                val left = ((dur - pos).coerceAtLeast(0) + 999) / 1000
                Text("-%d:%02d".format(left / 60, left % 60), Modifier.align(Alignment.BottomEnd).padding(end = 6.dp, bottom = 9.dp)
                    .clip(RoundedCornerShape(50)).background(Color(0x99000000)).padding(horizontal = 6.dp, vertical = 2.dp),
                    color = Color.White, fontSize = 11.sp)
                Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(3.dp).background(Color(0x40FFFFFF))) {
                    Box(Modifier.fillMaxHeight().fillMaxWidth(if (dur > 0) (pos.toFloat() / dur).coerceIn(0f, 1f) else 0f).background(Color.White))
                }
            }
        }
    }
}
