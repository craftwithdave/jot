package app.jot.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextIndent
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import android.content.ClipboardManager
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import kotlin.math.roundToInt
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.jot.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest

val LinkC = Color(0xFF64B5FF)
val TagC = Color(0xFFC792EA)

val Blue = Color(0xFF0A84FF)                    // lists, numbers, checkboxes, quote tint (the Mac's system blue)

/** sizes the list layout needs, measured once with the body font (sp) */
data class Metrics(val one: Float, val space: Float, val bullet: Float, val gap: Float = 6f, val quote: Float = 12f, val media: Float = 172f)

/** what the editor draws behind the text (display offsets), refreshed by every LiveMarkdown.filter */
class Deco {
    var checks = listOf<Pair<Int, Boolean>>()         // widened space before a task's text, done?
    var quotes = listOf<IntRange>()
    var codes = listOf<Pair<IntRange, String>>()      // block, language label
    var rules = listOf<Int>()
    var media = listOf<Pair<Int, Logic.Media>>()      // where a media line's text starts (its thumbnail's left edge)
    /** thumbnails as last drawn (text layout coordinates), for taps */
    @Volatile var hits = listOf<Pair<Rect, Logic.Media>>()
}

/**
 * Live preview like the Mac editor: Markdown symbols are hidden (Markup.Shown, with the offset mapping, so the caret
 * never stops inside them), lists / numbers / checkboxes / quotes are blue, code blocks are coloured by highlight.js.
 * [Title](url) links show only the title, except the ones the caret touches (`shown`, from Markup.shownAt).
 * Media lines (`![image](jot-media:…)`) become one tall line with a thumbnail drawn on it (drawDeco), except the one
 * the caret is on, which shows its text dimmed. Their last character stays (transparent) so the line always has a
 * display character to carry the tall paragraph style, also when it is the note's last line.
 */
class LiveMarkdown(
    private val exists: (String) -> Boolean,
    private val metrics: Metrics,
    private val highlight: (String, String) -> Highlighter.Result?,
    val deco: Deco,
    private val shown: List<IntRange> = emptyList(),
) : VisualTransformation {
    companion object {
        val SIZES = listOf(24, 21, 19, 17, 16, 16)
        val URL = Regex("https?://[^\\s<>()\\[\\]]+[^\\s<>()\\[\\].,;:!?'\"]")
        private val GLYPHS = listOf('•', '◦', '▪')
    }

    override fun filter(text: AnnotatedString): TransformedText {
        val s = text.text
        val sh = Markup.Shown(s, Markup.hidden(s, shown))
        val disp = StringBuilder(sh.display)
        val checks = ArrayList<Pair<Int, Boolean>>(); val quotes = ArrayList<IntRange>(); val codes = ArrayList<Pair<IntRange, String>>(); val rules = ArrayList<Int>()
        val styles = ArrayList<Triple<SpanStyle, Int, Int>>()
        val paras = ArrayList<Triple<ParagraphStyle, Int, Int>>()
        val m = metrics
        fun span(st: SpanStyle, r: IntRange) { sh.range(r)?.let { styles.add(Triple(st, it.first, it.last + 1)) } }
        fun para(ls: Int, st: ParagraphStyle) {
            // the range includes the line's newline, else Compose starts the next paragraph with an empty line
            val a = sh.toDisplay(ls); val b = sh.toDisplay(minOf(s.length, Markup.lineEnd(s, ls) + 1))
            if (paras.none { it.second == a }) paras.add(Triple(st, a, b))
        }
        fun listPara(ls: Int, textStart: Float) = para(ls, ParagraphStyle(textIndent = TextIndent(0.sp, textStart.sp), lineHeight = 28.sp))
        val dim = Color(0x59FFFFFF)

        for (h in Markup.HEADING.findAll(s)) {
            val lvl = h.groupValues[1].length
            span(SpanStyle(fontSize = SIZES[lvl - 1].sp, fontWeight = FontWeight.SemiBold), h.range)
        }
        // bullets: "-" shown as a blue • ◦ ▪ by depth; text starts one "1." + gap in
        for (b in Markup.BULLET.findAll(s)) {
            val indent = b.groupValues[1]; val dash = b.groups[2]!!.range.first
            val d = sh.toDisplay(dash)
            disp.setCharAt(d, GLYPHS[Markup.depth(indent) % 3])
            styles.add(Triple(SpanStyle(color = Blue, fontWeight = FontWeight.Bold), d, d + 1))
            styles.add(Triple(SpanStyle(letterSpacing = (m.one + m.gap - m.bullet).coerceAtLeast(0f).sp), d + 1, d + 2))
            listPara(Markup.lineStart(s, dash), indent.length * m.space + m.one + m.gap + m.space)
        }
        // numbers / letters: blue, text lines up after "1." + gap (wider numbers push it a little)
        for (n in Markup.NUMBER.findAll(s)) {
            val mk = n.groups[2]!!.range
            val tok = n.groupValues[2].dropLast(1)
            if (!(tok.length == 1 || tok.all { it.isDigit() } || ListMarker.fromRoman(tok) != null)) continue
            span(SpanStyle(color = Blue, fontWeight = FontWeight.Medium, fontFeatureSettings = "tnum"), mk)
            val w = n.groupValues[2].length * m.one / 2f                      // ≈ width of the marker (tabular digits)
            val sp = sh.toDisplay(mk.last + 1)
            styles.add(Triple(SpanStyle(letterSpacing = (maxOf(m.one, w) - w + m.gap).sp), sp, sp + 1))
            listPara(Markup.lineStart(s, mk.first), n.groupValues[1].length * m.space + maxOf(m.one, w) + m.gap + m.space)
        }
        // tasks: "- [ ]" hidden, a box is drawn on the widened space after it
        for (c in Markup.CHECK.findAll(s)) {
            val done = c.groupValues[3] != "[ ]"
            val after = c.groups[2]!!.range.last + 1
            if (after < s.length && s[after] == ' ') {
                val d = sh.toDisplay(after)
                checks.add(d to done)
                styles.add(Triple(SpanStyle(letterSpacing = (m.one + m.gap).sp), d, d + 1))
            }
            listPara(Markup.lineStart(s, after), c.groupValues[1].length * m.space + m.one + m.gap + m.space)
            if (done) c.groups[4]?.range?.let { if (!it.isEmpty()) span(SpanStyle(color = Muted, textDecoration = TextDecoration.LineThrough), it) }
        }
        // a list item's indented follow-on lines ("  Summary text") line up with the item's text
        for (ls in Markup.continuations(s)) {
            val above = sh.toDisplay(Markup.lineStart(s, ls - 1))
            val rest = paras.firstOrNull { it.second == above }?.first?.textIndent?.restLine ?: continue
            val lead = s.substring(ls, Markup.lineEnd(s, ls)).takeWhile { it == ' ' || it == '\t' }.length
            para(ls, ParagraphStyle(textIndent = TextIndent((rest.value - lead * m.space).coerceAtLeast(0f).sp, rest), lineHeight = 28.sp))
        }
        // quotes: blue-tinted block behind, white text inset
        for (q in Markup.QUOTE.findAll(s)) {
            val sp = sh.toDisplay(q.range.first + 1)
            styles.add(Triple(SpanStyle(letterSpacing = m.quote.sp), sp, sp + 1))
            para(q.range.first, ParagraphStyle(textIndent = TextIndent(0.sp, (m.quote + m.space).sp)))
            sh.range(q.range)?.let { r -> val last = quotes.lastOrNull(); if (last != null && last.last + 2 >= r.first) quotes[quotes.size - 1] = last.first..r.last else quotes.add(r) }
        }
        for (r in Markup.RULE.findAll(s)) rules.add(sh.toDisplay(r.range.first))
        for (b in Markup.BOLD.findAll(s)) span(SpanStyle(fontWeight = FontWeight.Bold), b.range)
        for (i in Markup.ITALIC.findAll(s)) span(SpanStyle(fontStyle = FontStyle.Italic), i.range)
        for (u in Markup.UNDERLINE.findAll(s)) span(SpanStyle(textDecoration = TextDecoration.Underline), u.range)
        for (st in Markup.STRIKE.findAll(s)) span(SpanStyle(color = Muted, textDecoration = TextDecoration.LineThrough), st.range)
        for (u in URL.findAll(s)) span(SpanStyle(color = LinkC, textDecoration = TextDecoration.Underline), u.range)
        for (t in Logic.TAG.findAll(s)) { val g = t.groups[2]!!.range; span(SpanStyle(color = TagC), (g.first - 1)..g.last) }
        for (l in Logic.LINK.findAll(s)) {
            val ok = exists(l.groupValues[1].split("|")[0].split("#")[0])
            span(SpanStyle(color = if (ok) LinkC else LinkC.copy(alpha = 0.55f), textDecoration = if (ok) null else TextDecoration.Underline), l.groups[1]!!.range)
            span(SpanStyle(color = dim), l.range.first..l.range.first + 1); span(SpanStyle(color = dim), (l.range.last - 1)..l.range.last)
        }
        // [Title](url): the title in link blue; "[" "](url)" are hidden unless the caret touches the link, then dim
        for (l in Markup.mdLinks(s)) {
            val t = l.groups[1]!!.range
            span(SpanStyle(color = LinkC, textDecoration = TextDecoration.None), t)
            if (l.range in shown) {
                span(SpanStyle(color = dim), l.range.first..l.range.first)
                span(SpanStyle(color = dim, textDecoration = TextDecoration.None), (t.last + 1)..l.range.last)
            }
        }
        for (c in Markup.CODE.findAll(s)) span(SpanStyle(fontFamily = FontFamily.Monospace, background = Color(0x1FFFFFFF)), c.range)
        // code blocks: mono, One Dark colours (fence language, else detected), language label
        for (f in Markup.fences(s)) {
            val innerA = f.first.last + 1; val innerB = maxOf(innerA, f.close.first - 1)
            span(SpanStyle(fontFamily = FontFamily.Monospace, fontSize = 14.sp, fontWeight = FontWeight.Normal, fontStyle = FontStyle.Normal,
                color = CodeTheme.plain, textDecoration = TextDecoration.None, background = Color.Transparent), f.block)
            val tag = s.substring(f.first.first, f.first.last).drop(3).trim()
            val code = s.substring(innerA, innerB)
            val r = highlight(code, tag)
            r?.spans?.forEach { sp ->
                val col = CodeTheme.color(sp.cls) ?: return@forEach
                val a = innerA + sp.range.first
                span(SpanStyle(color = col, fontStyle = if (sp.cls in CodeTheme.italic) FontStyle.Italic else null), a..(innerA + sp.range.last))
            }
            var ls = f.block.first
            while (ls <= f.block.last) { para(ls, ParagraphStyle(textIndent = TextIndent(10.sp, 10.sp))); ls = Markup.lineEnd(s, ls) + 1 }
            val label = CodeTheme.names[(r?.language ?: "").ifEmpty { tag.lowercase() }] ?: "Auto"
            sh.range(f.block)?.let { codes.add(it to label) }
        }

        // images / videos: a tall line with the thumbnail drawn on it, or (caret on the line) the dimmed text
        val media = ArrayList<Pair<Int, Logic.Media>>()
        for (r in Markup.mediaLines(s)) {
            if (r in shown) { span(SpanStyle(color = dim, fontSize = 14.sp), r); continue }
            val md = Logic.media(s.substring(r.first, r.last + 1)).firstOrNull() ?: continue
            span(SpanStyle(color = Color.Transparent), r.last..r.last)
            val a = sh.toDisplay(r.first); val b = sh.toDisplay(minOf(s.length, r.last + 2))
            val tall = ParagraphStyle(lineHeight = m.media.sp, lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None))
            val i = paras.indexOfFirst { it.second == a }
            if (i >= 0) paras[i] = Triple(paras[i].first.merge(tall), a, b) else paras.add(Triple(tall, a, b))
            media.add(sh.toDisplay(Markup.mediaStart(s, r)) to md)
        }

        deco.checks = checks; deco.quotes = quotes; deco.codes = codes; deco.rules = rules; deco.media = media
        val out = buildAnnotatedString {
            append(disp.toString())
            styles.forEach { (st, a, b) -> if (a < b && b <= length) addStyle(st, a, b) }
            paras.sortedBy { it.second }.fold(-1) { end, (st, a, b) -> if (a > end && b <= length) { addStyle(st, a, b); b } else end }
        }
        return TransformedText(out, object : OffsetMapping {
            override fun originalToTransformed(offset: Int) = sh.toDisplay(offset)
            override fun transformedToOriginal(offset: Int) = sh.toText(offset)
        })
    }
}

/** draws checkboxes, quote / code blocks, dividers and image / video thumbnails behind the text */
fun DrawScope.drawDeco(deco: Deco, layout: TextLayoutResult?, measurer: TextMeasurer, thumb: (String) -> JotMedia.Thumb = { JotMedia.Thumb.Loading }) {
    val l = layout ?: return
    val n = l.layoutInput.text.length
    fun line(o: Int) = l.getLineForOffset(o.coerceIn(0, n))
    for ((r, label) in deco.codes) {
        val top = l.getLineTop(line(r.first)) - 2f; val bottom = l.getLineBottom(line(r.last)) + 2f
        drawRoundRect(Color(0x0FFFFFFF), Offset(0f, top), Size(size.width + 6.dp.toPx(), bottom - top), CornerRadius(8.dp.toPx()))
        val t = measurer.measure(label, TextStyle(color = Muted, fontSize = 11.sp, fontWeight = FontWeight.Medium))
        drawText(t, topLeft = Offset(size.width - t.size.width - 4.dp.toPx(), top + 4.dp.toPx()))
    }
    for (r in deco.quotes) {
        val top = l.getLineTop(line(r.first)) - 2f; val bottom = l.getLineBottom(line(r.last)) + 2f
        drawRoundRect(Blue.copy(alpha = 0.16f), Offset(0f, top), Size(size.width, bottom - top), CornerRadius(7.dp.toPx()))
    }
    for (o in deco.rules) {
        val li = line(o); val y = (l.getLineTop(li) + l.getLineBottom(li)) / 2f
        drawLine(Color(0x29FFFFFF), Offset(0f, y), Offset(size.width, y), 1.dp.toPx())
    }
    for ((o, done) in deco.checks) {
        if (o >= n) continue
        val li = line(o); val cy = (l.getLineTop(li) + l.getLineBottom(li)) / 2f
        val x = l.getHorizontalPosition(o, true); val d = 16.dp.toPx()
        val tl = Offset(x, cy - d / 2)
        if (done) {
            drawRoundRect(Blue, tl, Size(d, d), CornerRadius(4.dp.toPx()))
            val p = Path().apply { moveTo(x + d * 0.26f, cy + d * 0.02f); lineTo(x + d * 0.43f, cy + d * 0.2f); lineTo(x + d * 0.75f, cy - d * 0.18f) }
            drawPath(p, Color.White, style = Stroke(1.8.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
        } else drawRoundRect(Blue, tl + Offset(0.7f, 0.7f), Size(d - 1.4f, d - 1.4f), CornerRadius(4.dp.toPx()), style = Stroke(1.4.dp.toPx()))
    }
    deco.hits = deco.media.mapNotNull { (o, md) -> if (o > n) null else drawThumb(l, o.coerceAtMost(n), md, thumb(md.id), measurer)?.let { it to md } }
}

/** where the thumbnail of the media line whose text starts at display offset [o] goes (text layout coordinates):
 *  160 dp high, aspect-fit, at most the text width (320 dp), from the line's text start. Shared by the drawing and
 *  the inline video player, which sits exactly on it. */
fun Density.thumbRect(l: TextLayoutResult, o0: Int, t: JotMedia.Thumb): Rect? {
    val o = o0.coerceIn(0, l.layoutInput.text.length)
    val li = l.getLineForOffset(o)
    val x = l.getHorizontalPosition(o, true)
    val maxW = minOf(l.size.width - x, 320.dp.toPx()); if (maxW <= 0f) return null
    var h = 160.dp.toPx(); var w: Float
    if (t is JotMedia.Thumb.Ready) {
        w = h * t.bmp.width / t.bmp.height.coerceAtLeast(1)
        if (w > maxW) { h = maxW * t.bmp.height / t.bmp.width.coerceAtLeast(1); w = maxW }
    } else w = minOf(maxW, h * 4f / 3f)
    val y = (l.getLineTop(li) + l.getLineBottom(li)) / 2f - h / 2f
    return Rect(x, y, x + w, y + h)
}

/** one thumbnail on its tall line: 160 dp high, aspect-fit, at most the text width (320 dp), from the line's text
 *  start; videos get a ▶ and their duration. Returns where it was drawn. */
private fun DrawScope.drawThumb(l: TextLayoutResult, o: Int, md: Logic.Media, t: JotMedia.Thumb, measurer: TextMeasurer): Rect? {
    val r = thumbRect(l, o, t) ?: return null
    val round = CornerRadius(10.dp.toPx())
    when (t) {
        is JotMedia.Thumb.Ready -> clipPath(Path().apply { addRoundRect(RoundRect(r, round)) }) {
            drawImage(t.bmp.asImageBitmap(), srcSize = IntSize(t.bmp.width, t.bmp.height),
                dstOffset = IntOffset(r.left.toInt(), r.top.toInt()), dstSize = IntSize(r.width.toInt(), r.height.toInt()))
        }
        else -> {
            drawRoundRect(Color(0x14FFFFFF), r.topLeft, r.size, round)
            if (t is JotMedia.Thumb.Failed) {
                val tx = measurer.measure("unavailable", TextStyle(color = Muted, fontSize = 11.sp))
                drawText(tx, topLeft = Offset(r.center.x - tx.size.width / 2f, if (md.kind == "video") r.bottom - tx.size.height - 8.dp.toPx() else r.center.y - tx.size.height / 2f))
            }
        }
    }
    if (md.kind == "video") {
        val c = r.center; val rad = 22.dp.toPx()
        drawCircle(Color(0x8C000000), rad, c)
        val k = rad * 0.42f
        drawPath(Path().apply { moveTo(c.x - k * 0.7f, c.y - k); lineTo(c.x + k * 1.05f, c.y); lineTo(c.x - k * 0.7f, c.y + k); close() }, Color.White)
        if (md.duration.isNotEmpty()) {
            val tx = measurer.measure(md.duration, TextStyle(color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Medium))
            val pw = tx.size.width + 12.dp.toPx(); val ph = tx.size.height + 4.dp.toPx()
            val tl = Offset(r.right - pw - 6.dp.toPx(), r.bottom - ph - 6.dp.toPx())
            drawRoundRect(Color(0x99000000), tl, Size(pw, ph), CornerRadius(ph / 2f))
            drawText(tx, topLeft = tl + Offset(6.dp.toPx(), 2.dp.toPx()))
        }
    }
    return r
}

/** text fades out towards the top and bottom edges (content scrolls under the top bar like on the Mac) */
fun Modifier.fadeEdges(top: Dp = 18.dp, bottom: Dp = 18.dp) = this
    .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
    .drawWithContent {
        drawContent()
        val t = top.toPx() / size.height; val b = bottom.toPx() / size.height
        drawRect(Brush.verticalGradient(0f to Color.Transparent, t to Color.Black, (1f - b) to Color.Black, 1f to Color.Transparent), blendMode = BlendMode.DstIn)
    }

// ---- caret helpers ----
private fun lineStart(s: String, at: Int) = Markup.lineStart(s, at)

/** "[[" start + typed text when the caret is in an unfinished link, else null */
fun linkQuery(v: TextFieldValue): Pair<Int, String>? {
    if (!v.selection.collapsed) return null
    val at = v.selection.start; val s = v.text
    val ls = lineStart(s, at)
    val before = s.substring(ls, at)
    val i = before.lastIndexOf("[[")
    if (i < 0) return null
    val q = before.substring(i + 2)
    if (q.contains('[') || q.contains(']') || q.length > 80) return null
    return (ls + i) to q
}
/** the link the caret is inside, e.g. [[Wed|ding]] → "Wed" */
fun linkAt(v: TextFieldValue): String? {
    val at = v.selection.start
    return Logic.LINK.findAll(v.text).firstOrNull { at > it.range.first && at <= it.range.last }?.groupValues?.get(1)?.split("|")?.get(0)?.split("#")?.get(0)
}

/** the url of the [Title](url) link the caret touches */
fun urlAt(v: TextFieldValue): String? {
    val r = Markup.touched(v.text, v.selection.min, v.selection.max).firstOrNull() ?: return null
    return Markup.MDLINK.matchEntire(v.text.substring(r.first, r.last + 1))?.groupValues?.get(2)
}

fun TextFieldValue.ed() = Ed(text, selection.start, selection.end)
fun Ed.tfv() = TextFieldValue(text, TextRange(start, end))

/**
 * Every edit goes through here: taps never leave the caret on hidden symbols (and a tap on a checkbox toggles it,
 * a tap inside a [Title](url) link's title opens the url), Backspace / Delete act only on visible text
 * (Markup.smartDelete), Return continues lists.
 */
fun editorChange(old: TextFieldValue, nv: TextFieldValue, open: (String) -> Unit = {}, media: (Logic.Media) -> Unit = {}): TextFieldValue {
    if (nv.text == old.text) {
        if (nv.selection.collapsed && nv.selection != old.selection) {
            val p = nv.selection.start
            // a tap on a thumbnail opens it and leaves the caret where it was; the caret walking onto the line (keyboard
            // cursor swipe, arrows) skips over it: a media line never shows its text
            Markup.mediaLines(nv.text).firstOrNull { p >= it.first && p <= it.last + 1 }?.let { r ->
                val o = old.selection.start
                val h = Markup.hidden(old.text, Markup.shownAt(old.text, old.selection.min, old.selection.max))
                if ((minOf(p, o) until maxOf(p, o)).count { it < h.size && !h[it] } > 1 && !(o > r.last + 1 && o <= r.last + 3)) {
                    Logic.media(nv.text.substring(r.first, r.last + 1)).firstOrNull()?.let(media)
                    return old
                }
                return nv.copy(selection = TextRange(Markup.offMedia(nv.text, p, forward = p >= o)))
            }
            // a tap well inside a link's title (shown as just the title) opens it and leaves the caret where it was;
            // the caret moving one visible character at a time (keyboard cursor swipe) walks in instead
            Markup.mdLinks(nv.text).firstOrNull { p > it.groups[1]!!.range.first && p <= it.groups[1]!!.range.last }?.let { l ->
                val o = old.selection.start
                val shown = Markup.shownAt(old.text, old.selection.min, old.selection.max)
                val h = Markup.hidden(old.text, shown)
                if (l.range !in shown && (minOf(p, o) until maxOf(p, o)).count { !h[it] } > 1) { open(l.groupValues[2]); return old }
            }
            val ls = Markup.lineStart(nv.text, p)
            Markup.CHECK.find(nv.text.substring(ls, Markup.lineEnd(nv.text, ls)))?.let { c ->
                val boxEnd = ls + c.groups[2]!!.range.last + 1
                if (p == boxEnd) { Markup.toggleTask(nv.text, p)?.let { return TextFieldValue(it, TextRange(boxEnd + 1)) } }
            }
            val q = Markup.safeCaret(nv.text, p)
            if (q != p) return nv.copy(selection = TextRange(q))
        }
        return nv
    }
    val k = old.text.length - nv.text.length
    if (old.selection.collapsed && nv.selection.collapsed && (k == 1 || k == 2)) {
        val p = nv.selection.start
        if (p + k <= old.text.length && old.text.removeRange(p, p + k) == nv.text) {
            val c = old.selection.start
            if (c == p + k) return Markup.smartDelete(Ed(old.text, c), false).tfv()
            if (c == p) return Markup.smartDelete(Ed(old.text, c), true).tfv()
        }
    }
    if (!old.selection.collapsed && nv.selection.collapsed && nv.text.length < old.text.length)
        return Markup.cleanEmptyMarks(Ed(nv.text, nv.selection.start)).tfv()
    // Return on a list line
    if (old.selection.collapsed && nv.text.length == old.text.length + 1) {
        val at = old.selection.start
        if (nv.selection.start == at + 1 && nv.text[at] == '\n' && nv.text.startsWith(old.text.substring(0, at)))
            Markup.continueList(Ed(old.text, at))?.let { return it.tfv() }
    }
    return nv
}

/** what the editor screen needs to remember about the open note */
class NoteSession(val id: String) {
    var lastSaved = Jot.repo.content(id)?.body ?: ""
    var openedKey = lastSaved.takeIf { it.isNotBlank() }?.let { Logic.titleKey(Logic.title(it)) } ?: ""

    fun save(text: String) {
        if (text == lastSaved) return
        lastSaved = text
        if (text.isBlank() && Jot.repo.record(id) == null) return
        Jot.repo.edit(id, text)
        Jot.syncSoon()
    }
    /** leaving the note: drop it if empty, and fix [[links]] to it if its title changed */
    fun commit(text: String) {
        save(text)
        val body = Jot.repo.content(id)?.body ?: return
        if (body.isBlank()) { Jot.repo.remove(id); Jot.syncSoon(); return }
        val newTitle = Logic.title(body); val newKey = Logic.titleKey(newTitle)
        if (openedKey.isNotEmpty() && openedKey != newKey && openedKey != "untitled") {
            val others = Jot.repo.live().filter { it.first != id }
            if (others.none { Logic.titleKey(Logic.title(it.second.body)) == openedKey }) {
                for ((oid, c) in others) if (openedKey in Logic.links(c.body)) Jot.repo.edit(oid, Logic.renameLinks(c.body, openedKey, newTitle))
            }
            Jot.syncSoon()
        }
        openedKey = newKey
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EditorScreen(id: String, initial: String?, onOpen: (String) -> Unit, onNew: (String) -> Unit, onBack: () -> Unit) {
    val ctx = LocalContext.current
    val session = remember(id) { NoteSession(id) }
    var value by remember(id) {
        val body = Jot.repo.content(id)?.body ?: initial ?: ""
        mutableStateOf(TextFieldValue(body, TextRange(body.length)))
    }
    val index by Jot.index.collectAsState()
    val version by Jot.repo.version.collectAsState()
    val hlVersion by Highlighter.version.collectAsState()
    var showSheet by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var layout by remember { mutableStateOf<TextLayoutResult?>(null) }
    val focus = remember { FocusRequester() }
    val measurer = rememberTextMeasurer()
    val density = LocalDensity.current
    val bodyStyle = TextStyle(color = Ink, fontSize = 17.sp, lineHeight = 25.sp, fontFamily = Inter)
    val metrics = remember(density) {
        fun w(t: String, st: TextStyle) = with(density) { measurer.measure(t, st).size.width.toFloat().toSp().value }
        Metrics(one = w("1.", bodyStyle.copy(fontWeight = FontWeight.Medium, fontFeatureSettings = "tnum")), space = w(" ", bodyStyle), bullet = w("•", bodyStyle.copy(fontWeight = FontWeight.Bold)),
            media = with(density) { 172.dp.toSp().value })
    }
    val deco = remember { Deco() }
    val uri = LocalUriHandler.current
    val shown = Markup.shownAt(value.text, value.selection.min, value.selection.max)   // [Title](url) links / media lines shown whole
    val md = remember(index, hlVersion, metrics, shown) { LiveMarkdown({ index.resolve(it) != null }, metrics, { code, lang -> Highlighter.get(ctx, code, lang) }, deco, shown) }
    fun openUrl(u: String) { runCatching { uri.openUri(u) } }
    // images / videos: thumbnails redraw when loaded; a tapped one opens full screen
    val mediaVersion by JotMedia.version.collectAsState()
    var viewing by remember { mutableStateOf<Logic.Media?>(null) }
    var inline by remember(id) { mutableStateOf<Logic.Media?>(null) }   // the one video playing on its thumbnail
    fun tapped(m: Logic.Media) { if (m.kind == "video") inline = m else viewing = m }
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { inline = null }       // app in the background: stop + clean up
    var uploading by remember { mutableStateOf(false) }
    var mediaErr by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    LaunchedEffect(id) { JotMedia.retryFailed() }
    LaunchedEffect(mediaErr) { if (mediaErr.isNotEmpty()) { delay(6000); mediaErr = "" } }
    /** seal + upload the image, then put it on its own line at the caret (nothing is inserted if that fails) */
    fun addImage(u: Uri) {
        if (uploading) return
        uploading = true; mediaErr = ""
        scope.launch {
            val r = withContext(Dispatchers.IO) { runCatching { JotMedia.upload(ctx, u) } }
            uploading = false
            r.onSuccess { mid -> value = Markup.insertMedia(value.ed(), mid).tfv(); focus.requestFocus() }
             .onFailure { e -> mediaErr = "Couldn't add the image: " + (e.message ?: e.toString()) }
        }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { u -> u?.let(::addImage) }
    // BasicTextField(TextFieldValue) can't receive pasted images in this Compose version (contentReceiver only works
    // with the TextFieldState one), so an image on the clipboard offers a "Paste image" chip instead
    val clip = remember { ctx.getSystemService(ClipboardManager::class.java) }
    var clipImage by remember { mutableStateOf(false) }
    DisposableEffect(clip) {
        fun check() { clipImage = clip?.primaryClipDescription?.let { d -> (0 until d.mimeTypeCount).any { d.getMimeType(it).startsWith("image/") } } == true }
        check()
        val l = ClipboardManager.OnPrimaryClipChangedListener { check() }
        clip?.addPrimaryClipChangedListener(l)
        onDispose { clip?.removePrimaryClipChangedListener(l) }
    }

    LaunchedEffect(id) {
        if (initial != null && Jot.repo.content(id) == null) session.save(initial)
        Prefs.opened(ctx, id)
        focus.requestFocus()
    }
    // save shortly after typing stops
    LaunchedEffect(id) { snapshotFlow { value.text }.collectLatest { delay(350); session.save(it) } }
    // changed on another device while not being typed in: show it
    LaunchedEffect(version) {
        val remote = Jot.repo.content(id)?.body
        if (remote != null && value.text == session.lastSaved && remote != session.lastSaved) {
            session.lastSaved = remote
            value = TextFieldValue(remote, TextRange(value.selection.start.coerceAtMost(remote.length)))
        }
    }
    fun leave() { session.commit(value.text); onBack() }
    fun go(name: String) {
        session.commit(value.text)
        val target = index.resolve(name)
        if (target != null) onOpen(target) else onNew(name.trim())
    }
    BackHandler { leave() }

    val pinned = Jot.repo.content(id)?.pinned == true
    val reading = Jot.repo.content(id)?.cat == NoteContent.READING
    val lq = linkQuery(value)
    val suggestions = remember(lq, index) {
        lq?.let { (_, q) ->
            val nq = Logic.titleKey(q)
            index.notes.values.filter { it.id != id && (nq.isEmpty() || it.key.contains(nq)) }
                .sortedWith(compareByDescending<IndexedNote> { it.key.startsWith(nq) }.thenByDescending { it.updated }).take(8).map { it.title }
        } ?: emptyList()
    }
    fun accept(title: String) {
        val (start, _) = linkQuery(value) ?: return
        val at = value.selection.start
        val end = if (value.text.startsWith("]]", at)) at + 2 else at
        val ins = "[[$title]]"
        value = TextFieldValue(value.text.substring(0, start) + ins + value.text.substring(end), TextRange(start + ins.length))
    }
    fun apply(f: (Ed) -> Ed) { value = f(value.ed()).tfv(); focus.requestFocus() }

    Box(Modifier.fillMaxSize()) {
    Column(Modifier.fillMaxSize().background(Page).systemBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            GlassIcon({ leave() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", Modifier.size(20.dp)) }
            Text(Logic.title(value.text).ifBlank { "New note" }, Modifier.weight(1f), color = if (value.text.isBlank()) Muted else Ink,
                fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
            val back = index.backlinks(id).size
            GlassIcon({ session.save(value.text); showSheet = true }) { Text("↩$back", fontSize = 13.sp, color = Ink) }
            GlassIcon({ session.save(value.text); Jot.repo.setPinned(id, !pinned); Jot.syncSoon() }, enabled = Jot.repo.content(id) != null) {
                Icon(if (pinned) Icons.Filled.Star else Icons.Outlined.Star, "Pin", Modifier.size(20.dp), tint = if (pinned) Warn else Color.White)
            }
            GlassIcon({ session.save(value.text); Jot.repo.setCat(id, if (reading) null else NoteContent.READING); Jot.syncSoon() },
                enabled = Jot.repo.content(id) != null) { BooksGlyph(if (reading) Blue else Color.White, reading) }
            GlassIcon({ confirmDelete = true }, enabled = Jot.repo.content(id) != null) { Icon(Icons.Filled.Delete, "Delete", Modifier.size(20.dp)) }
        }
        BasicTextField(
            value = value,
            onValueChange = { nv -> value = editorChange(value, nv, ::openUrl) { tapped(it) } },
            modifier = Modifier.weight(1f).fillMaxWidth().fadeEdges().verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 14.dp).focusRequester(focus),
            textStyle = bodyStyle,
            cursorBrush = SolidColor(LinkC),
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false),
            visualTransformation = md,
            onTextLayout = { layout = it },
            decorationBox = { inner ->
                Box(Modifier
                    .pointerInput(Unit) {
                        // a tap on a thumbnail opens it; consuming the up keeps the caret where it was
                        awaitEachGesture {
                            val down = awaitFirstDown(requireUnconsumed = false)
                            val hit = deco.hits.firstOrNull { it.first.contains(down.position) } ?: return@awaitEachGesture
                            val up = waitForUpOrCancellation() ?: return@awaitEachGesture
                            if ((up.position - down.position).getDistance() < viewConfiguration.touchSlop) { up.consume(); tapped(hit.second) }
                        }
                    }
                    .drawBehind { mediaVersion; drawDeco(deco, layout, measurer) { JotMedia.thumb(ctx, it) } }) {
                    inner()
                    // the playing video sits on its thumbnail's rect (recomputed from the layout, so it follows typing,
                    // insets and scrolling); it stops when its line is gone or revealed (caret on it)
                    inline?.let { v ->
                        mediaVersion
                        val l = layout
                        val r = l?.let { lay -> deco.media.firstOrNull { it.second.id == v.id }?.let { (o, _) -> with(density) { thumbRect(lay, o, JotMedia.thumb(ctx, v.id)) } } }
                        if (r == null) SideEffect { inline = null }
                        else key(v.id) {
                            InlineVideo(v, Modifier.offset { IntOffset(r.left.roundToInt(), r.top.roundToInt()) }
                                .size(with(density) { r.width.toDp() }, with(density) { r.height.toDp() })) { inline = null }
                        }
                    }
                }
            },
        )
        // above the keyboard: [[ suggestions, or the format bar
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            if (lq != null) {
                if (suggestions.isEmpty()) Kicker("Type a note name, then ]]")
                suggestions.forEach { t -> Chip("↗ $t", LinkC) { accept(t) } }
            } else {
                linkAt(value)?.let { name -> Chip("Open $name", LinkC) { go(name) } }
                urlAt(value)?.let { u -> Chip("Open ↗ " + u.substringAfter("://").substringBefore('/'), LinkC) { openUrl(u) } }
                Markup.fenceAt(value.text, value.selection.start)?.let { (tag, _) ->
                    val shown = CodeTheme.names[tag] ?: deco.codes.firstOrNull()?.second ?: "Auto"
                    MenuChip("$shown ▾", listOf("Auto-detect" to "") + CodeTheme.names.entries.sortedBy { it.value.lowercase() }.map { it.value to it.key }) { lang ->
                        apply { Markup.setLanguage(it, lang) }
                    }
                }
                MenuChip("H ▾", listOf("Heading 1" to "1", "Heading 2" to "2", "Heading 3" to "3")) { n -> apply { Markup.heading(it, n.toInt()) } }
                MenuChip("Aa ▾", listOf("Bold" to "**", "Italic" to "*", "Strikethrough" to "~~", "Underline" to "<u>")) { mk ->
                    apply { if (mk == "<u>") Markup.wrap(it, "<u>", "</u>") else Markup.wrap(it, mk, mk) }
                }
                Chip("</>", Ink) { apply { Markup.codeLine(it) } }
                Chip("{ }", Ink) { apply { Markup.codeBlock(it) } }
                Chip("❝", Ink) { apply { Markup.lineMarker(it, "quote") } }
                MenuChip("☰ ▾", listOf("Ordered List" to "ol", "Bullet List" to "ul", "Task List" to "task")) { k -> apply { Markup.lineMarker(it, k) } }
                Chip("⇥", Ink) { apply { Markup.indent(it, false) } }
                Chip("⇤", Ink) { apply { Markup.indent(it, true) } }
                Chip(if (uploading) "Adding…" else "Image", Ink) {
                    if (!uploading) picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                }
                if (clipImage && !uploading) Chip("Paste image", Ink) { clip?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.uri?.let(::addImage) ?: run { mediaErr = "No image on the clipboard" } }
            }
        }
        if (mediaErr.isNotEmpty()) Text(mediaErr, Modifier.padding(horizontal = 20.dp).padding(bottom = 8.dp), color = Down, fontSize = 13.sp)
    }
    // a tapped image / video opens over the note, below the top bar (not a separate full-screen window)
    viewing?.let { m -> MediaViewer(m, Modifier.systemBarsPadding().padding(top = 56.dp)) { viewing = null } }
    }

    if (showSheet) {
        ModalBottomSheet(onDismissRequest = { showSheet = false }, containerColor = Color(0xFF111111)) {
            Connections(index, id, value.text, onOpen = { showSheet = false; go(it) }, onTag = { })
        }
    }
    if (confirmDelete) {
        AlertDialog(onDismissRequest = { confirmDelete = false }, containerColor = Color(0xFF1A1A1A),
            title = { Text("Delete this note?") }, text = { Text("It's removed from all your devices.", color = Muted) },
            confirmButton = { TextButton({ confirmDelete = false; Jot.repo.remove(id); Jot.syncSoon(); onBack() }) { Text("Delete", color = Down) } },
            dismissButton = { TextButton({ confirmDelete = false }) { Text("Cancel", color = Ink) } })
    }
}

/** a format-bar chip that opens a menu; items are (label, value) */
@Composable
fun MenuChip(text: String, items: List<Pair<String, String>>, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        Chip(text, Ink) { open = true }
        DropdownMenu(open, { open = false }, containerColor = Color(0xFF1C1C1E)) {
            items.forEach { (label, v) -> DropdownMenuItem({ Text(label, color = Ink) }, { open = false; onPick(v) }) }
        }
    }
}

@Composable
fun Chip(text: String, color: Color, onClick: () -> Unit) {
    Text(text, Modifier.clip(CircleShape).background(Color(0x1FFFFFFF)).clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 8.dp),
        color = color, fontSize = 14.sp, maxLines = 1)
}

/** Links, backlinks, mentions, related notes and tags of one note. Tapping a name opens (or creates) it. */
@Composable
fun Connections(index: NotesIndex, id: String, text: String, onOpen: (String) -> Unit, onTag: (String) -> Unit) {
    val out = Logic.links(text).map { k -> (index.resolve(k)?.let { index.notes[it]?.title } ?: k) to (index.resolve(k) != null) }
    val back = index.backlinks(id).mapNotNull { index.notes[it] }
    val men = index.mentions(id).mapNotNull { index.notes[it] }
    val rel = index.related(id).mapNotNull { index.notes[it.id] }
    val tags = Logic.tags(text)
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 30.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        @Composable fun head(t: String) = Text(t.uppercase(), color = Color(0x73FFFFFF), fontSize = 11.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 12.dp))
        @Composable fun row(title: String, sub: String?, onClick: () -> Unit, faded: Boolean = false) {
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color(0x0FFFFFFF)).clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = 10.dp)) {
                Text(title, color = if (faded) Muted else Ink, fontSize = 15.sp, maxLines = 1)
                if (!sub.isNullOrBlank()) Text(sub, color = Muted, fontSize = 13.sp, maxLines = 1)
            }
        }
        if (out.isNotEmpty()) { head("Links"); out.forEach { (t, ok) -> row(if (ok) t else "+ $t", if (ok) null else "Not created yet: tap to create", { onOpen(t) }, !ok) } }
        head("Backlinks")
        if (back.isEmpty()) Kicker("No notes link here yet. Type [[ in another note.")
        back.forEach { n -> row(n.title, snippet(n.body), { onOpen(n.title) }) }
        if (men.isNotEmpty()) { head("Mentioned in"); men.forEach { n -> row(n.title, snippet(n.body), { onOpen(n.title) }) } }
        head("Related")
        if (rel.isEmpty()) Kicker("Nothing similar yet.")
        rel.forEach { n -> row(n.title, snippet(n.body), { onOpen(n.title) }) }
        if (tags.isNotEmpty()) {
            head("Tags")
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) { tags.forEach { t -> Chip("#$t", TagC) { onTag(t) } } }
        }
    }
}

/** first line after the title that mentions a query word, else the first line after the title */
fun snippet(body: String, query: List<String> = emptyList()): String {
    val lines = body.split("\n").map { it.trim() }.filter { it.isNotEmpty() }.drop(1)
    if (query.isNotEmpty()) lines.firstOrNull { l -> val w = Logic.words(l); query.any { q -> w.any { it.startsWith(q) } } }?.let { return it.take(140) }
    return (lines.firstOrNull() ?: "").take(140)
}
