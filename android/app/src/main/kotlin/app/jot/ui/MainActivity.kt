package app.jot.ui

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Delete
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import app.jot.*
import kotlinx.coroutines.flow.MutableStateFlow
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/** Where the app is. Editor(id, initial): initial = text for a brand-new note (shared text, a [[link]] that didn't exist yet). */
sealed class Nav {
    object List : Nav()
    data class Editor(val id: String, val initial: String? = null) : Nav()
    data class Graph(val from: String?) : Nav()
    object Settings : Nav()
}

class MainActivity : ComponentActivity() {
    companion object {
        const val NEW = "app.jot.NEW"
        /** a new note to open, from the Share menu / quick tile / app shortcut */
        val incoming = MutableStateFlow<String?>(null)
    }
    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        enableEdgeToEdge()
        if (b == null) take(intent)
        setContent { MaterialTheme(colorScheme = meridianColors, typography = meridianType()) { CompositionLocalProvider(LocalContentColor provides Ink) { Root() } } }
    }
    override fun onNewIntent(i: Intent) { super.onNewIntent(i); take(i) }
    override fun onResume() { super.onResume(); App.visible = true; Jot.start(); Thread { Updater.check() }.start() }
    override fun onPause() { App.visible = false; Jot.stop(); super.onPause() }

    private fun take(i: Intent?) {
        when (i?.action) {
            NEW -> incoming.value = ""
            Intent.ACTION_SEND -> {
                val text = listOf(i.getStringExtra(Intent.EXTRA_SUBJECT), i.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString())
                    .mapNotNull { it?.trim()?.takeIf(String::isNotEmpty) }.distinct().joinToString("\n")
                if (text.isNotEmpty()) incoming.value = text
            }
        }
        setIntent(Intent(this, MainActivity::class.java))
    }
}

@Composable
private fun Root() {
    val unlocked by Jot.unlocked.collectAsState()
    var stack by remember { mutableStateOf(listOf<Nav>(Nav.List)) }
    val incoming by MainActivity.incoming.collectAsState()
    fun push(n: Nav) { stack = stack + n }
    fun pop() { if (stack.size > 1) stack = stack.dropLast(1) }
    LaunchedEffect(incoming, unlocked) {
        val t = incoming ?: return@LaunchedEffect
        if (!unlocked) return@LaunchedEffect
        MainActivity.incoming.value = null
        stack = listOf(Nav.List, Nav.Editor(Crypto.newId(), if (t.isEmpty()) null else t))
    }
    if (!unlocked) { UnlockScreen(); return }
    BackHandler(stack.size > 1 && stack.last() !is Nav.Editor) { pop() }     // the editor saves first, then pops
    AnimatedContent(stack.last(), transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "nav") { nav ->
        when (nav) {
            is Nav.List -> ListScreen(onOpen = { push(Nav.Editor(it)) }, onNew = { push(Nav.Editor(Crypto.newId())) },
                onGraph = { push(Nav.Graph(null)) }, onSettings = { push(Nav.Settings) })
            is Nav.Editor -> EditorScreen(nav.id, nav.initial,
                onOpen = { id -> stack = stack + Nav.Editor(id) },
                onNew = { title -> stack = stack + Nav.Editor(Crypto.newId(), "$title\n") },
                onBack = { pop() })
            is Nav.Graph -> GraphScreen(nav.from, onOpen = { push(Nav.Editor(it)) }, onBack = { pop() })
            is Nav.Settings -> SettingsScreen(onBack = { pop() })
        }
    }
}

// ---- list + search ----

@Composable
private fun ListScreen(onOpen: (String) -> Unit, onNew: () -> Unit, onGraph: () -> Unit, onSettings: () -> Unit) {
    val ctx = LocalContext.current
    val index by Jot.index.collectAsState()
    val sync by Jot.sync.collectAsState()
    val opened by Prefs.lastOpened.collectAsState()
    var query by rememberSaveable { mutableStateOf("") }
    var confirm by remember { mutableStateOf<String?>(null) }
    fun at(n: IndexedNote) = opened[n.id] ?: n.updated
    // search titles + text; without a search: pinned, Reading List & Ideas, the rest; each most recently opened first
    fun section(n: IndexedNote) = if (n.pinned) 0 else if (n.cat == NoteContent.READING) 1 else 2
    val rows = remember(index, query, opened) {
        if (query.isBlank()) index.notes.values.sortedWith(compareBy<IndexedNote> { section(it) }.thenByDescending { at(it) })
        else index.search(query).mapNotNull { index.notes[it.id] }
    }
    val last = opened.maxByOrNull { it.value }?.key                 // the note you were last in
    // section titles where the section changes; only without a search, and not when everything is a plain note
    val titleAt = if (query.isBlank() && rows.any { section(it) < 2 }) rows.indices.filter { it == 0 || section(rows[it]) != section(rows[it - 1]) }.toSet()
                  else emptySet()
    Box(Modifier.fillMaxSize().background(Page)) {
        Column(Modifier.fillMaxSize().systemBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 12.dp, top = 10.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Jot", fontSize = 30.sp, letterSpacing = (-0.04).em, color = Ink)
                Dot(when (sync) { is SyncState.Live -> Up; is SyncState.Offline -> Muted; else -> Warn }, glow = sync is SyncState.Live)
                Spacer(Modifier.weight(1f))
                GlassIcon(onGraph) { GraphGlyph() }
                GlassIcon(onSettings) { Icon(Icons.Filled.Settings, "Settings", Modifier.size(20.dp)) }
            }
            Row(Modifier.padding(horizontal = 16.dp, vertical = 6.dp).fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color(0x14FFFFFF))
                .padding(horizontal = 14.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Search, null, Modifier.size(20.dp), tint = Muted)
                Spacer(Modifier.width(10.dp))
                Box(Modifier.weight(1f)) {
                    if (query.isEmpty()) Text("Search notes", color = Muted, fontSize = 16.sp)
                    BasicTextField(query, { query = it }, Modifier.fillMaxWidth(), singleLine = true, textStyle = TextStyle(color = Ink, fontSize = 16.sp, fontFamily = Inter),
                        cursorBrush = SolidColor(LinkC), keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                        keyboardActions = KeyboardActions(onSearch = { rows.firstOrNull()?.let { onOpen(it.id) } }))
                }
                if (query.isNotEmpty()) Icon(Icons.Filled.Close, "Clear", Modifier.size(20.dp).clickable { query = "" }, tint = Muted)
            }
            UpdateCard()
            LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(start = 12.dp, end = 12.dp, top = 6.dp, bottom = 100.dp)) {
                itemsIndexed(rows, key = { _, n -> n.id }) { i, n ->
                    if (i in titleAt) Text(SECTIONS[section(n)].uppercase(), color = Color(0x73FFFFFF), fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
                        letterSpacing = 0.06.em, modifier = Modifier.padding(start = 12.dp, top = if (i == 0) 4.dp else 14.dp, bottom = 2.dp))
                    val reading = n.cat == NoteContent.READING
                    NoteRow(n.title, at(n), n.pinned, reading, current = n.id == last, confirming = confirm == n.id,
                        onClick = { if (confirm != n.id) onOpen(n.id) },
                        onPin = { Jot.repo.setPinned(n.id, !n.pinned); Jot.syncSoon() },
                        onReading = { Jot.repo.setCat(n.id, if (reading) null else NoteContent.READING); Jot.syncSoon() },
                        onDelete = { confirm = n.id },
                        onConfirm = { confirm = null; Jot.repo.remove(n.id); Jot.syncSoon(); Prefs.opened(ctx, n.id, remove = true) },
                        onCancel = { confirm = null })
                }
                if (rows.isEmpty()) item {
                    Text(if (query.isBlank()) "No notes yet. Tap + to write one.\n\nLink notes by typing [[ and a note's name; Jot shows what links where, and which notes are related."
                         else "No matching notes.", color = Muted, fontSize = 15.sp, lineHeight = 22.sp, modifier = Modifier.padding(20.dp))
                }
            }
        }
        Box(Modifier.align(Alignment.BottomEnd).navigationBarsPadding().padding(22.dp).size(60.dp).clip(CircleShape).background(Color.White).clickable(onClick = onNew),
            contentAlignment = Alignment.Center) { Icon(Icons.Filled.Add, "New note", Modifier.size(28.dp), tint = Color.Black) }
    }
}

private val SECTIONS = listOf("Pinned", "Reading List & Ideas", "Notes")

/** a note in the list: blue dot = the note you were last in, title with when it was last opened beneath, pin / delete;
 *  delete asks right in the row */
@Composable
private fun NoteRow(title: String, opened: Long, pinned: Boolean, reading: Boolean, current: Boolean, confirming: Boolean,
                    onClick: () -> Unit, onPin: () -> Unit, onReading: () -> Unit, onDelete: () -> Unit, onConfirm: () -> Unit, onCancel: () -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(if (confirming) Down.copy(alpha = 0.12f) else Color.Transparent)
        .clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        if (confirming) {
            Column(Modifier.weight(1f)) {
                Text("Delete “${title.ifBlank { "Untitled" }}”?", color = Ink, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("Removed from all your devices", color = Color(0x73FFFFFF), fontSize = 13.sp, modifier = Modifier.padding(top = 4.dp))
            }
            Text("Cancel", Modifier.clip(RoundedCornerShape(10.dp)).background(Color(0x1FFFFFFF)).clickable(onClick = onCancel).padding(horizontal = 12.dp, vertical = 8.dp), color = Ink, fontSize = 14.sp)
            Spacer(Modifier.width(8.dp))
            Text("Delete", Modifier.clip(RoundedCornerShape(10.dp)).background(Down).clickable(onClick = onConfirm).padding(horizontal = 12.dp, vertical = 8.dp), color = Color.White, fontSize = 14.sp)
            return@Row
        }
        Box(Modifier.size(7.dp).clip(CircleShape).background(if (current) Blue else Color.Transparent))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title.ifBlank { "Untitled" }, color = Ink, fontSize = 17.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                fontWeight = if (current) FontWeight.SemiBold else FontWeight.Normal)
            Text(when_(opened), color = Color(0x73FFFFFF), fontSize = 13.sp, modifier = Modifier.padding(top = 5.dp))
        }
        Box(Modifier.clip(CircleShape).clickable(onClick = onReading).padding(9.dp)) { BooksGlyph(if (reading) Blue else Color(0x59FFFFFF), reading, 18.dp) }
        Icon(Icons.Filled.Star, if (pinned) "Unpin" else "Pin", Modifier.clip(CircleShape).clickable(onClick = onPin).padding(9.dp).size(18.dp),
            tint = if (pinned) Blue else Color(0x59FFFFFF))
        Icon(Icons.Filled.Delete, "Delete", Modifier.clip(CircleShape).clickable(onClick = onDelete).padding(9.dp).size(18.dp), tint = Color(0x59FFFFFF))
    }
}

private fun when_(ms: Long): String {
    val now = Calendar.getInstance(); val c = Calendar.getInstance().apply { timeInMillis = ms }
    val f = when {
        now.get(Calendar.YEAR) == c.get(Calendar.YEAR) && now.get(Calendar.DAY_OF_YEAR) == c.get(Calendar.DAY_OF_YEAR) -> "HH:mm"
        now.get(Calendar.YEAR) == c.get(Calendar.YEAR) && now.get(Calendar.DAY_OF_YEAR) - 1 == c.get(Calendar.DAY_OF_YEAR) -> return "Yesterday"
        now.get(Calendar.YEAR) == c.get(Calendar.YEAR) -> "d MMM"
        else -> "d MMM yyyy"
    }
    return SimpleDateFormat(f, Locale.getDefault()).format(Date(ms))
}

/** three linked dots */
@Composable
private fun GraphGlyph() {
    androidx.compose.foundation.Canvas(Modifier.size(20.dp)) {
        val a = androidx.compose.ui.geometry.Offset(size.width * 0.2f, size.height * 0.75f)
        val b = androidx.compose.ui.geometry.Offset(size.width * 0.5f, size.height * 0.22f)
        val c = androidx.compose.ui.geometry.Offset(size.width * 0.82f, size.height * 0.7f)
        drawLine(Color.White, a, b, 2.5f); drawLine(Color.White, b, c, 2.5f); drawLine(Color.White, a, c, 2.5f)
        listOf(a, b, c).forEach { drawCircle(Color.White, size.width * 0.13f, it) }
    }
}

// ---- unlock ----

@Composable
private fun UnlockScreen() {
    var pass by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var err by remember { mutableStateOf("") }
    val ctx = LocalContext.current
    fun go() {
        if (pass.isEmpty() || busy) return
        busy = true; err = ""
        Thread {
            val e = try { Jot.unlock(pass); null }
                    catch (x: HttpError) { if (x.code == 401) "Wrong passphrase" else x.message }
                    catch (x: Exception) { "Can't reach ${java.net.URL(BuildConfig.ORIGIN).host}." }
            android.os.Handler(ctx.mainLooper).post { busy = false; if (e == null) pass = "" else err = e }
        }.start()
    }
    Column(Modifier.fillMaxSize().background(Page).systemBarsPadding().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Jot", fontSize = 30.sp, letterSpacing = (-0.04).em, color = Ink, modifier = Modifier.padding(start = 4.dp, top = 10.dp, bottom = 8.dp))
        HeroCard {
            Title("Unlock")
            Text("Your notes are encrypted on this phone before they go to your server, so only your devices can read them. " +
                 "Enter your Jot passphrase; the first device you unlock creates it. It can't be recovered, so keep it somewhere safe.",
                color = Muted, fontSize = 14.sp, lineHeight = 20.sp)
            OutlinedTextField(pass, { pass = it }, Modifier.fillMaxWidth(), label = { Text("Passphrase") }, singleLine = true,
                visualTransformation = PasswordVisualTransformation(), shape = FieldShape, colors = fieldColors(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { go() }))
            GlassButton(if (busy) "Unlocking…" else "Unlock", ::go, Modifier.fillMaxWidth(), kind = Pill.Primary, enabled = !busy && pass.isNotEmpty())
            if (err.isNotEmpty()) Text(err, color = Down, fontSize = 13.sp)
        }
    }
}

// ---- settings ----

@Composable
private fun SettingsScreen(onBack: () -> Unit) {
    val ctx = LocalContext.current
    val sync by Jot.sync.collectAsState()
    val index by Jot.index.collectAsState()
    var auto by remember { mutableStateOf(Prefs.autoUpdate(ctx)) }
    var confirmLock by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().background(Page).systemBarsPadding().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            GlassIcon(onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", Modifier.size(20.dp)) }
            Title("Settings")
        }
        UpdateCard()
        HeroCard {
            Kicker("Sync")
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Dot(when (sync) { is SyncState.Live -> Up; is SyncState.Offline -> Down; else -> Warn }, glow = sync is SyncState.Live)
                Text(when (val s = sync) { is SyncState.Live -> "Live"; is SyncState.Offline -> "Offline"; else -> "Syncing…" }, fontSize = 22.sp, letterSpacing = (-0.03).em)
            }
            (sync as? SyncState.Offline)?.let { Text("${it.why}\nEdits are kept and sent later.", color = Muted, fontSize = 13.sp, lineHeight = 18.sp) }
            Text("${index.count} notes, end-to-end encrypted, synced with ${java.net.URL(BuildConfig.ORIGIN).host}.", color = Muted, fontSize = 14.sp)
            GlassButton("Sync now", { Jot.syncSoon(0) })
        }
        DarkCard {
            Kicker("Quick capture")
            Text("Add the Jot tile to Quick Settings for a new note from anywhere. You can also share text or links to Jot from any app, or long-press the app icon → New note.",
                color = Muted, fontSize = 14.sp, lineHeight = 20.sp)
            if (Build.VERSION.SDK_INT >= 33) GlassButton("Add quick tile", { addTile(ctx) }, kind = Pill.Primary)
        }
        DarkCard {
            Kicker("App")
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Update automatically", fontSize = 17.sp, modifier = Modifier.weight(1f))
                Switch(auto, { auto = it; Prefs.autoUpdate(ctx, it); Updater.schedule(ctx) }, colors = meridianSwitchColors())
            }
            Text("Version ${BuildConfig.VERSION_NAME}", color = Muted, fontSize = 13.sp)
            GlassButton("Lock Jot on this phone", { confirmLock = true }, kind = Pill.Danger)
        }
    }
    if (confirmLock) AlertDialog(onDismissRequest = { confirmLock = false }, containerColor = Color(0xFF1A1A1A),
        title = { Text("Lock Jot?") },
        text = { Text("Removes the key and the copy of your notes from this phone. They stay on your server and other devices; unlock again with your passphrase." +
            if (Jot.repo.hasDirty()) "\n\nSome edits haven't synced yet and would be lost." else "", color = Muted) },
        confirmButton = { TextButton({ confirmLock = false; Jot.lock(); onBack() }) { Text("Lock", color = Down) } },
        dismissButton = { TextButton({ confirmLock = false }) { Text("Cancel", color = Ink) } })
}

@Composable
private fun UpdateCard() {
    val ctx = LocalContext.current
    val update by Updater.state.collectAsState()
    (update as? Updater.State.Available)?.let { s ->
        DarkCard(Modifier.padding(horizontal = 4.dp)) {
            Kicker("Update")
            Text("Version ${s.info.name} is ready. ${s.info.notes}", fontSize = 14.sp, lineHeight = 20.sp)
            GlassButton("Update now", { Thread { Updater.install(ctx, s.info) }.start() }, kind = Pill.Primary)
        }
    }
    (update as? Updater.State.Downloading)?.let { Text("Updating… ${it.pct}%", color = Muted, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 20.dp)) }
}

private fun addTile(ctx: Context) {
    if (Build.VERSION.SDK_INT < 33) return
    ctx.getSystemService(StatusBarManager::class.java).requestAddTileService(
        ComponentName(ctx, NewNoteTile::class.java), "New note", Icon.createWithResource(ctx, app.jot.R.drawable.ic_tile), ctx.mainExecutor) { }
}
