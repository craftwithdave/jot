package app.jot.ui

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.ClipOp
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.PathOperation
import kotlinx.coroutines.launch
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.boundsInParent
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import app.jot.R

/* Meridian dashboard look: always dark, Inter, dark cards, liquid glass. */

val Page = Color(0xFF000000)
val Page2 = Color(0xFF0A0A0A)
val Ink = Color(0xFFF5F5F5)
val Muted = Color(0x8CFFFFFF)          // white 55%
val Faint = Color(0x1AFFFFFF)          // white 10%
val CardTop = Color(0xFF141414)
val CardBottom = Color(0xFF0D0D0D)
val CardBorder = Color(0x17FFFFFF)     // white 9%
val Up = Color(0xFF30D158)
val Down = Color(0xFFFF6961)
val Warn = Color(0xFFFFD60A)
val Accent = Color(0xFF5E5CE6)
val CarC = Color(0xFFFF9F0A)
val OtherC = Color(0x61FFFFFF)         // white 38%: not car / ignored

val Inter = FontFamily(
    Font(R.font.inter_regular, FontWeight.Normal),
    Font(R.font.inter_medium, FontWeight.Medium),
    Font(R.font.inter_semibold, FontWeight.SemiBold),
)

val meridianColors = darkColorScheme(
    primary = Color.White, onPrimary = Color.Black, secondary = CarC, background = Page, onBackground = Ink,
    surface = CardTop, onSurface = Ink, surfaceVariant = Color(0xFF1C1C1C), onSurfaceVariant = Muted,
    surfaceContainerHigh = CardTop, surfaceContainer = CardTop, outline = Color(0x33FFFFFF), outlineVariant = Faint,
    error = Down, primaryContainer = Color(0xFF1C1C1C), onPrimaryContainer = Ink,
)

fun meridianType(): Typography {
    val t = Typography()
    fun TextStyle.inter() = copy(fontFamily = Inter, fontWeight = if (fontWeight == FontWeight.Normal || fontWeight == null) FontWeight.Medium else fontWeight, letterSpacing = (-0.01).em)
    return Typography(t.displayLarge.inter(), t.displayMedium.inter(), t.displaySmall.inter(), t.headlineLarge.inter(), t.headlineMedium.inter(),
        t.headlineSmall.inter(), t.titleLarge.inter(), t.titleMedium.inter(), t.titleSmall.inter(), t.bodyLarge.inter(), t.bodyMedium.inter(),
        t.bodySmall.inter(), t.labelLarge.inter(), t.labelMedium.inter(), t.labelSmall.inter())
}

// ---- surfaces ----

/** Liquid glass (pills, buttons): white sheen, lit rim, top highlight, drop shadow. Over the map it gets a
 *  dark base, because Compose can't blur the map's GL surface behind it. */
fun Modifier.glass(shape: Shape = CircleShape, base: Color = Color(0xB31A1A1A), shadow: Dp = 10.dp) = this
    .shadow(shadow, shape, ambientColor = Color.Black, spotColor = Color.Black)
    .clip(shape)
    .background(base)
    .background(Brush.verticalGradient(listOf(Color(0x29FFFFFF), Color(0x0FFFFFFF))))
    .border(1.dp, Color(0x33FFFFFF), shape)
    .drawWithContent {
        drawContent()
        // specular highlight along the top edge
        drawLine(Brush.horizontalGradient(listOf(Color.Transparent, Color(0x66FFFFFF), Color.Transparent)),
            Offset(size.width * 0.12f, 1.2f), Offset(size.width * 0.88f, 1.2f), strokeWidth = 1.2f)
    }

/** Frosted dark pane floating over the map (the day card, the timeline sheet). */
fun Modifier.panel(shape: Shape = RoundedCornerShape(24.dp)) = this
    .shadow(24.dp, shape, ambientColor = Color.Black, spotColor = Color.Black)
    .clip(shape)
    .background(Brush.verticalGradient(listOf(Color(0xF0161616), Color(0xEB0B0B0B))))
    .border(1.dp, Color(0x1FFFFFFF), shape)

/** Meridian card: dark gradient, thin border, 20dp corners. */
fun Modifier.card(shape: Shape = RoundedCornerShape(20.dp)) = this
    .clip(shape)
    .background(Brush.verticalGradient(listOf(CardTop, CardBottom)))
    .border(1.dp, CardBorder, shape)

@Composable
fun DarkCard(modifier: Modifier = Modifier, padding: Dp = 20.dp, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier.fillMaxWidth().card().padding(padding), verticalArrangement = Arrangement.spacedBy(10.dp), content = content)
}

/** Hero card with Meridian's slow orbiting blue/violet glow. */
@Composable
fun HeroCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val t = rememberInfiniteTransition(label = "glow")
    val a by t.animateFloat(0f, (2 * Math.PI).toFloat(), infiniteRepeatable(tween(30_000, easing = LinearEasing)), label = "orbit")
    Box(modifier.fillMaxWidth().card(RoundedCornerShape(24.dp))) {
        Canvas(Modifier.matchParentSize()) {
            fun glow(angle: Float, r: Float, c: Color) {
                val center = Offset(size.width / 2 + kotlin.math.cos(angle) * size.width * 0.36f, size.height / 2 + kotlin.math.sin(angle) * size.height * 0.34f)
                drawCircle(Brush.radialGradient(listOf(c, Color.Transparent), center, r), r, center)
            }
            glow(a, size.width * 0.75f, Color(0x8C58749E))
            glow(a + Math.PI.toFloat(), size.width * 0.55f, Color(0x476E64AA))
        }
        Column(Modifier.padding(horizontal = 24.dp, vertical = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
    }
}

// ---- text ----
@Composable fun Kicker(text: String, modifier: Modifier = Modifier) = Text(text, modifier, color = Muted, fontSize = 13.sp)

@Composable
fun Big(value: String, unit: String, size: Int = 52, color: Color = Ink) {
    Row(verticalAlignment = Alignment.Bottom) {
        Text(value, fontSize = size.sp, letterSpacing = (-0.055).em, lineHeight = size.sp, color = color, fontWeight = FontWeight.Medium,
            style = TextStyle(fontFeatureSettings = "tnum"))
        Spacer(Modifier.width(6.dp))
        Text(unit, fontSize = (size * 0.42).sp, color = Muted, letterSpacing = (-0.02).em, modifier = Modifier.padding(bottom = (size * 0.08).dp))
    }
}

@Composable
fun Title(text: String) = Text(text, fontSize = 26.sp, letterSpacing = (-0.035).em, color = Ink)

@Composable
fun Dot(color: Color, glow: Boolean = false) {
    Box(Modifier.size(if (glow) 17.dp else 9.dp), contentAlignment = Alignment.Center) {
        if (glow) Box(Modifier.size(17.dp).clip(CircleShape).background(color.copy(alpha = 0.22f)))
        Box(Modifier.size(9.dp).clip(CircleShape).background(color))
    }
}

@Composable
fun Badge(text: String, tint: Color) {
    Text(text, Modifier.clip(CircleShape).background(tint.copy(alpha = 0.18f)).border(1.dp, tint.copy(alpha = 0.3f), CircleShape)
        .padding(horizontal = 9.dp, vertical = 2.dp), color = tint, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
}

// ---- buttons ----
enum class Pill { Glass, Primary, Danger }

@Composable
fun GlassButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, kind: Pill = Pill.Glass, enabled: Boolean = true) {
    val src = remember { MutableInteractionSource() }
    val pressed by src.collectIsPressedAsState()
    val s by animateFloatAsState(if (pressed) 0.96f else 1f, label = "press")
    val base = when (kind) {
        Pill.Primary -> Modifier.shadow(8.dp, CircleShape).clip(CircleShape).background(Color.White)
        Pill.Danger -> Modifier.glass(base = Color(0x4DFF453A))
        Pill.Glass -> Modifier.glass()
    }
    Box(modifier.scale(s).graphicsLayer { alpha = if (enabled) 1f else 0.4f }.then(base)
        .clickable(src, null, enabled = enabled, onClick = onClick).heightIn(min = 40.dp).padding(horizontal = 19.dp),
        contentAlignment = Alignment.Center) {
        Text(text, color = when (kind) { Pill.Primary -> Color.Black; Pill.Danger -> Color(0xFFFF8A80); Pill.Glass -> Color.White },
            fontSize = 14.sp, maxLines = 1)
    }
}

@Composable
fun GlassIcon(onClick: () -> Unit, modifier: Modifier = Modifier, size: Dp = 40.dp, enabled: Boolean = true, content: @Composable () -> Unit) {
    val src = remember { MutableInteractionSource() }
    val pressed by src.collectIsPressedAsState()
    val s by animateFloatAsState(if (pressed) 0.92f else 1f, label = "press")
    Box(modifier.size(size).scale(s).graphicsLayer { alpha = if (enabled) 1f else 0.35f }.glass()
        .clickable(src, null, enabled = enabled, onClick = onClick), contentAlignment = Alignment.Center) {
        CompositionLocalProvider(LocalContentColor provides Color.White) { content() }
    }
}

/** Web `easeOutBack` (timeline-sync/public/app.js): overshoots a little, then settles. */
private fun easeOutBack(t: Float): Float { val u = t - 1f; return 1f + 1.6f * u * u * u + 0.6f * u * u }
private val CssEaseOut = CubicBezierEasing(0f, 0f, 0.58f, 1f)

/**
 * CSS `box-shadow: inset 0 <dy> <blur> <color>` on a full pill: the band between the pill and the same pill moved
 * by [dy] px (down = lit top edge, up = shade at the bottom), softened with a vertical fade over [blur] px.
 */
private fun Modifier.pillInset(dy: Float, blur: Float, color: Color) = drawWithContent {
    drawContent()
    val r = size.height / 2
    val outer = Path().apply { addRoundRect(RoundRect(0f, 0f, size.width, size.height, r, r)) }
    val inner = Path().apply { addRoundRect(RoundRect(0f, dy, size.width, size.height + dy, r, r)) }
    val band = Path().apply { op(outer, inner, PathOperation.Difference) }
    val edge = if (dy > 0) 0f else size.height
    val reach = (kotlin.math.abs(dy) + blur).coerceAtMost(size.height)
    drawPath(band, Brush.verticalGradient(listOf(color, color.copy(alpha = 0f)),
        startY = edge, endY = if (dy > 0) edge + reach else edge - reach))
}

/**
 * Exact port of the web viewer's segmented control (timeline-sync/public: app.css `.glass-seg` / `.glass-pill` /
 * `.glass-lens`, app.js `glassPill`): a liquid-glass pill slides under the picked option (520 ms ease-out-back),
 * squishes on the way (480 ms) and magnifies the labels it passes over like a lens.
 * [opaque]: the bar floats over the map; on the web it sits on the black page, so paint that black under it.
 */
@Composable
fun <T> GlassSeg(options: List<Pair<String, T>>, selected: T?, onSelect: (T) -> Unit, modifier: Modifier = Modifier, fill: Boolean = false,
                 height: Dp = 30.dp, fontSize: androidx.compose.ui.unit.TextUnit = 13.sp, opaque: Boolean = false) {
    val d = LocalDensity.current
    val pos = remember { mutableStateMapOf<Int, Pair<Float, Float>>() }   // index -> (x, width) in px, inside the 4 dp padding
    var rowW by remember { mutableFloatStateOf(0f) }
    val idx = options.indexOfFirst { it.second == selected }
    val target = pos[idx]

    var pillX by remember { mutableFloatStateOf(0f) }
    var pillW by remember { mutableFloatStateOf(0f) }
    var lens by remember { mutableFloatStateOf(1f) }
    var placed by remember { mutableStateOf(false) }
    var lastIdx by remember { mutableIntStateOf(-1) }
    val squish = remember { Animatable(0f) }   // 0..1 through the squish keyframes
    // web: opacity 0 until placed, and (here) while nothing is selected, e.g. Settings open; 0.2 s ease
    val pillAlpha by animateFloatAsState(if (placed && idx >= 0) 1f else 0f, tween(200), label = "pill")

    LaunchedEffect(idx, target) {
        val (x, w) = target ?: return@LaunchedEffect
        val from = pillX; val fromW = pillW
        val animate = placed && idx != lastIdx && lastIdx >= 0 && kotlin.math.abs(from - x) > 0.5f
        lastIdx = idx
        if (!animate) { pillX = x; pillW = w; lens = 1f; placed = true; return@LaunchedEffect }   // first placement / resize: snap
        launch { squish.snapTo(0f); squish.animateTo(1f, tween(480, easing = CssEaseOut)) }
        val t0 = withFrameNanos { it }
        while (true) {
            val t = ((withFrameNanos { it } - t0) / 520e6f).coerceAtMost(1f)
            val e = easeOutBack(t)
            val px = from + (x - from) * e
            pillX = px; pillW = fromW + (w - fromW) * e
            val tr = (kotlin.math.abs(px - from) / kotlin.math.abs(x - from)).coerceAtMost(1f)
            lens = 1f + 0.22f * kotlin.math.sin(Math.PI.toFloat() * tr)
            if (t >= 1f) break
        }
        pillX = x; pillW = w; lens = 1f
    }

    @Composable
    fun Labels(m: Modifier, lensCopy: Boolean) = Row(m, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        options.forEachIndexed { i, (label, v) ->
            Box((if (fill) Modifier.weight(1f) else Modifier).height(height).clip(CircleShape)
                .then(if (lensCopy) Modifier else Modifier
                    .onGloballyPositioned { pos[i] = it.boundsInParent().left to it.size.width.toFloat() }
                    .clickable(remember { MutableInteractionSource() }, indication = null) { onSelect(v) })   // no press ripple: the pill is the feedback
                .padding(horizontal = 14.dp), contentAlignment = Alignment.Center) {
                Text(label, color = if (lensCopy) Color.White else if (i == idx) Ink else Muted, fontSize = fontSize,
                    textAlign = TextAlign.Center, maxLines = 1)
            }
        }
    }

    // bar: .glass-seg + its ::before (gradient 7% -> 2.5%, 1px rim 10%, inset 0 1px 0.5px 14%, 0 6px 18px black 35%)
    Box(modifier
        .shadow(9.dp, CircleShape, ambientColor = Color.Black.copy(alpha = 0.35f), spotColor = Color.Black.copy(alpha = 0.35f))
        .clip(CircleShape)
        .then(if (opaque) Modifier.background(Page) else Modifier)
        .background(Brush.verticalGradient(listOf(Color(0x12FFFFFF), Color(0x06FFFFFF))))
        .pillInset(with(d) { 1.dp.toPx() }, with(d) { 0.5.dp.toPx() }, Color(0x24FFFFFF))
        .border(1.dp, Color(0x1AFFFFFF), CircleShape)
        .padding(4.dp)) {
        val p = squish.value
        val sx = if (p < 0.35f) 1f + 0.12f * p / 0.35f else 1.12f - 0.12f * (p - 0.35f) / 0.65f
        val sy = if (p < 0.35f) 1f - 0.14f * p / 0.35f else 0.86f + 0.14f * (p - 0.35f) / 0.65f
        // On the web the pill's backdrop blur wipes out the labels behind it, so only the lens copy is readable.
        // Compose can't blur what's behind, so the labels are simply not drawn under the pill (faded with it).
        Labels((if (fill) Modifier.fillMaxWidth() else Modifier).onGloballyPositioned { rowW = it.size.width.toFloat() }
            .drawWithContent {
                if (pillW <= 0f || pillAlpha <= 0f) { drawContent(); return@drawWithContent }
                val hw = pillW / 2 * sx; val hh = size.height / 2 * sy; val cx = pillX + pillW / 2; val cy = size.height / 2
                val hole = Path().apply { addRoundRect(RoundRect(cx - hw, cy - hh, cx + hw, cy + hh, hh, hh)) }
                clipPath(hole, ClipOp.Difference) { this@drawWithContent.drawContent() }
                if (pillAlpha < 1f) clipPath(hole) {
                    drawContext.canvas.saveLayer(androidx.compose.ui.geometry.Rect(0f, 0f, size.width, size.height),
                        androidx.compose.ui.graphics.Paint().apply { alpha = 1f - pillAlpha })
                    this@drawWithContent.drawContent()
                    drawContext.canvas.restore()
                }
            }, lensCopy = false)
        // pill: .glass-pill (gradient 18% -> 7%, 1px rim 22%, inset 0 1.5px 1px 35%, inset 0 -8px 14px black 25%), above the labels
        if (pillW > 0f) {
            Box(Modifier.offset(x = with(d) { pillX.toDp() }).width(with(d) { pillW.toDp() }).height(height)
                .graphicsLayer { scaleX = sx; scaleY = sy; alpha = pillAlpha }
                .clip(CircleShape)
                .background(Brush.verticalGradient(listOf(Color(0x2EFFFFFF), Color(0x12FFFFFF))))
                .pillInset(with(d) { 1.5.dp.toPx() }, with(d) { 1.dp.toPx() }, Color(0x59FFFFFF))
                .pillInset(with(d) { -8.dp.toPx() }, with(d) { 14.dp.toPx() }, Color(0x40000000))
                .border(1.dp, Color(0x38FFFFFF), CircleShape)) {
                // lens: the labels again in white, lined up with the real ones and magnified about the pill's centre
                if (rowW > 0f) Labels(Modifier.wrapContentWidth(Alignment.Start, unbounded = true).requiredWidth(with(d) { rowW.toDp() })
                    .offset(x = with(d) { -pillX.toDp() })
                    .graphicsLayer {
                        scaleX = lens; scaleY = lens
                        transformOrigin = androidx.compose.ui.graphics.TransformOrigin((pillX + pillW / 2) / rowW, 0.5f)
                    }, lensCopy = true)
            }
        }
    }
}

@Composable
fun fieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = Color(0x66FFFFFF), unfocusedBorderColor = Color(0x1FFFFFFF), focusedLabelColor = Ink, unfocusedLabelColor = Muted,
    cursorColor = Color.White, focusedContainerColor = Color(0x0DFFFFFF), unfocusedContainerColor = Color(0x08FFFFFF))

val FieldShape = RoundedCornerShape(16.dp)

@Composable
fun meridianSwitchColors() = SwitchDefaults.colors(checkedTrackColor = Up, checkedThumbColor = Color.White, uncheckedTrackColor = Color(0x29FFFFFF),
    uncheckedThumbColor = Color(0xFFBDBDBD), uncheckedBorderColor = Color.Transparent)

/** two books and a leaning one: Reading List & Ideas; filled when the note is in it */
@Composable
fun BooksGlyph(color: Color, filled: Boolean, size: Dp = 20.dp) {
    Canvas(Modifier.size(size)) {
        val w = size.toPx(); val st = if (filled) androidx.compose.ui.graphics.drawscope.Fill
            else androidx.compose.ui.graphics.drawscope.Stroke(w * 0.08f)
        val r = androidx.compose.ui.geometry.CornerRadius(w * 0.05f)
        drawRoundRect(color, Offset(w * 0.14f, w * 0.18f), androidx.compose.ui.geometry.Size(w * 0.18f, w * 0.66f), r, style = st)
        drawRoundRect(color, Offset(w * 0.38f, w * 0.12f), androidx.compose.ui.geometry.Size(w * 0.18f, w * 0.72f), r, style = st)
        rotate(-18f, Offset(w * 0.78f, w * 0.84f)) {
            drawRoundRect(color, Offset(w * 0.64f, w * 0.2f), androidx.compose.ui.geometry.Size(w * 0.17f, w * 0.64f), r, style = st)
        }
    }
}
