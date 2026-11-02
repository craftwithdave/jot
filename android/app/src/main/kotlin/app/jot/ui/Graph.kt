package app.jot.ui

import android.graphics.Paint
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.jot.Jot
import app.jot.NotesIndex
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.sqrt
import kotlin.random.Random

/** Every note as a dot, [[links]] as lines, mentions + related notes (autoEdges) as faint lines, laid out by a small force simulation (same as the Mac app's GraphSim). */
class GraphSim {
    class Node(val id: String, var title: String, var x: Float, var y: Float) { var vx = 0f; var vy = 0f; var deg = 0; var soft = 0 }
    var nodes = listOf<Node>(); var edges = listOf<Pair<Int, Int>>(); var heat = 1f
    class Soft(val a: Int, val b: Int, val mention: Boolean)
    var softEdges = listOf<Soft>()   // autoEdges: weaker pull, drawn faint (related dashed)

    fun rebuild(ix: NotesIndex) {
        val old = nodes.associateBy { it.id }
        nodes = ix.order.map { id -> (old[id] ?: Node(id, "", Random.nextFloat() * 400 - 200, Random.nextFloat() * 400 - 200)).also { it.title = ix.notes[id]?.title ?: ""; it.deg = 0; it.soft = 0 } }
        val slot = nodes.withIndex().associate { it.value.id to it.index }
        edges = ix.edges().mapNotNull { (a, b) -> val i = slot[a]; val j = slot[b]; if (i != null && j != null) i to j else null }
        for ((a, b) in edges) { nodes[a].deg++; nodes[b].deg++ }
        softEdges = ix.autoEdges().mapNotNull { e -> val i = slot[e.a]; val j = slot[e.b]; if (i != null && j != null) Soft(i, j, e.kind == "mention") else null }
        for (e in softEdges) { nodes[e.a].soft++; nodes[e.b].soft++ }
        heat = 1f
    }
    fun step(): Boolean {
        if (heat < 0.004f || nodes.isEmpty()) return false
        val n = nodes.size
        val fx = FloatArray(n); val fy = FloatArray(n)
        for (i in 0 until n) for (j in i + 1 until n) {
            var dx = nodes[i].x - nodes[j].x; var dy = nodes[i].y - nodes[j].y
            var d2 = dx * dx + dy * dy
            if (d2 < 0.01f) { dx = Random.nextFloat() - 0.5f; dy = Random.nextFloat() - 0.5f; d2 = 1f }
            if (d2 > 250_000f) continue
            val d = sqrt(d2); val k = 2600f / d2
            fx[i] += k * dx / d; fy[i] += k * dy / d; fx[j] -= k * dx / d; fy[j] -= k * dy / d
        }
        for ((a, b) in edges) {
            val dx = nodes[b].x - nodes[a].x; val dy = nodes[b].y - nodes[a].y
            val d = maxOf(sqrt(dx * dx + dy * dy), 0.1f); val k = 0.035f * (d - 70f)
            fx[a] += k * dx / d; fy[a] += k * dy / d; fx[b] -= k * dx / d; fy[b] -= k * dy / d
        }
        for (e in softEdges) {
            val dx = nodes[e.b].x - nodes[e.a].x; val dy = nodes[e.b].y - nodes[e.a].y
            val d = maxOf(sqrt(dx * dx + dy * dy), 0.1f); val k = 0.035f * 0.35f * (d - 112f)
            fx[e.a] += k * dx / d; fy[e.a] += k * dy / d; fx[e.b] -= k * dx / d; fy[e.b] -= k * dy / d
        }
        var moved = 0f
        for (i in 0 until n) {
            val p = nodes[i]
            fx[i] -= p.x * 0.012f; fy[i] -= p.y * 0.012f
            p.vx = (p.vx + fx[i]) * 0.6f; p.vy = (p.vy + fy[i]) * 0.6f
            val sp = sqrt(p.vx * p.vx + p.vy * p.vy)
            if (sp > 30f) { p.vx *= 30f / sp; p.vy *= 30f / sp }
            p.x += p.vx * heat; p.y += p.vy * heat
            moved += sp
        }
        heat *= 0.992f
        if (moved / n < 0.05f) heat = 0f
        return true
    }
    fun radius(p: Node) = 4f + sqrt(min(p.deg, 16).toFloat()) * 2f
}

private val Dash = PathEffect.dashPathEffect(floatArrayOf(8f, 8f))

@Composable
fun GraphScreen(current: String?, onOpen: (String) -> Unit, onBack: () -> Unit) {
    val index by Jot.index.collectAsState()
    val sim = remember { GraphSim() }
    var frame by remember { mutableIntStateOf(0) }
    var scale by remember { mutableFloatStateOf(1.6f) }
    var pan by remember { mutableStateOf(Offset.Zero) }
    var focus by remember { mutableStateOf(current) }
    var relayouts by remember { mutableIntStateOf(0) }
    LaunchedEffect(index, relayouts) {
        sim.rebuild(index)
        while (sim.step()) { withFrameNanos { }; frame++ }
        frame++
    }
    val paint = remember { Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER } }

    Box(Modifier.fillMaxSize().background(Page)) {
        Canvas(Modifier.fillMaxSize()
            .pointerInput(Unit) { detectTransformGestures { _, p, z, _ -> scale = (scale * z).coerceIn(0.3f, 6f); pan += p } }
            .pointerInput(Unit) {
                detectTapGestures { o ->
                    val cx = size.width / 2f + pan.x; val cy = size.height / 2f + pan.y
                    val hit = sim.nodes.minByOrNull { hypot((cx + it.x * scale) - o.x, (cy + it.y * scale) - o.y) }
                    if (hit != null && hypot((cx + hit.x * scale) - o.x, (cy + hit.y * scale) - o.y) < 28f) {
                        if (focus == hit.id) onOpen(hit.id) else focus = hit.id     // first tap shows its links, second opens
                    } else focus = null
                }
            }) {
            frame.let { }
            val cx = size.width / 2f + pan.x; val cy = size.height / 2f + pan.y
            val nodes = sim.nodes
            val fi = nodes.indexOfFirst { it.id == focus }
            val near = HashSet<Int>()
            if (fi >= 0) { near += fi; for ((a, b) in sim.edges) if (a == fi || b == fi) { near += a; near += b }; for (e in sim.softEdges) if (e.a == fi || e.b == fi) { near += e.a; near += e.b } }
            for (e in sim.softEdges) {
                val hot = fi >= 0 && (e.a == fi || e.b == fi)
                drawLine(if (hot) LinkC.copy(alpha = 0.5f) else Color.White.copy(alpha = if (fi >= 0) 0.04f else 0.12f),
                    Offset(cx + nodes[e.a].x * scale, cy + nodes[e.a].y * scale), Offset(cx + nodes[e.b].x * scale, cy + nodes[e.b].y * scale),
                    strokeWidth = if (hot) 2f else 1.5f, pathEffect = if (e.mention) null else Dash)
            }
            for ((a, b) in sim.edges) {
                val hot = fi >= 0 && (a == fi || b == fi)
                drawLine(if (hot) LinkC else Color.White.copy(alpha = if (fi >= 0) 0.08f else 0.22f),
                    Offset(cx + nodes[a].x * scale, cy + nodes[a].y * scale), Offset(cx + nodes[b].x * scale, cy + nodes[b].y * scale), strokeWidth = if (hot) 3f else 2f)
            }
            for ((i, p) in nodes.withIndex()) {
                val dim = fi >= 0 && i !in near
                val c = if (i == fi) LinkC else if (p.deg + p.soft == 0) Color.Gray else Color.White
                val r = sim.radius(p) * scale.coerceIn(0.8f, 2.2f)
                val pt = Offset(cx + p.x * scale, cy + p.y * scale)
                drawCircle(c.copy(alpha = if (dim) 0.25f else 0.9f), r, pt)
                if (i in near || scale > 2.4f || p.deg >= 4) drawIntoCanvas {
                    paint.color = android.graphics.Color.argb(if (dim) 90 else 230, 255, 255, 255); paint.textSize = 30f
                    it.nativeCanvas.drawText(p.title.take(28), pt.x, pt.y + r + 34f, paint)
                }
            }
        }
        Row(Modifier.fillMaxWidth().systemBarsPadding().padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            GlassIcon(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", Modifier.size(20.dp)) }
            Text("${sim.nodes.size} notes · ${sim.edges.size} links · ${sim.softEdges.size} related", color = Muted, fontSize = 13.sp, modifier = Modifier.weight(1f).padding(start = 6.dp))
            GlassIcon({ relayouts++ }) { Icon(Icons.Filled.Refresh, "Lay out again", Modifier.size(20.dp)) }
        }
        if (focus != null) Text("Tap the dot again to open it", color = Muted, fontSize = 13.sp,
            modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(16.dp))
    }
}
