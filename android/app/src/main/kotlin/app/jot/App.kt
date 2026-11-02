package app.jot

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.work.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import java.io.File
import java.net.HttpURLConnection

class App : Application() {
    companion object {
        /** True while the app's screen is showing: background updates wait, so it never restarts under you. */
        @Volatile var visible = false
    }

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(Updater.CHANNEL, "App updates", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Says when Jot updated itself, or when an update needs a tap"; setShowBadge(false)
            })
        Updater.schedule(this)
        Prefs.loadOpened(this)
        Jot.init(this)
    }
}

/** Non-secret settings. The data key and auth live in [Secrets]. */
object Prefs {
    private fun p(c: Context) = c.getSharedPreferences("settings", Context.MODE_PRIVATE)
    fun autoUpdate(c: Context) = p(c).getBoolean("autoUpdate", true)
    fun autoUpdate(c: Context, v: Boolean) = p(c).edit().putBoolean("autoUpdate", v).apply()
    fun pendingUpdate(c: Context) = p(c).getString("pendingUpdate", null)
    fun pendingUpdate(c: Context, v: String?) = p(c).edit().putString("pendingUpdate", v).commit()
    /** when each note was last opened on this phone (ms; local only, shown in the note list) */
    val lastOpened = MutableStateFlow<Map<String, Long>>(emptyMap())
    fun loadOpened(c: Context) {
        val o = runCatching { org.json.JSONObject(p(c).getString("lastOpened", "{}")!!) }.getOrNull() ?: return
        lastOpened.value = o.keys().asSequence().associateWith { o.getLong(it) }
    }
    fun opened(c: Context, id: String, remove: Boolean = false) {
        val m = lastOpened.value.toMutableMap()
        if (remove) m.remove(id) else m[id] = System.currentTimeMillis()
        lastOpened.value = m
        p(c).edit().putString("lastOpened", org.json.JSONObject(m as Map<*, *>).toString()).apply()
    }
}

/** The unlocked device key: (data key, auth) or null. */
object Keys {
    fun get(c: Context): Pair<ByteArray, String>? {
        val dk = Secrets.get(c, "dk") ?: return null
        val auth = Secrets.get(c, "auth") ?: return null
        return dk to String(auth)
    }
    fun put(c: Context, dk: ByteArray, auth: String) { Secrets.put(c, "dk", dk); Secrets.put(c, "auth", auth.toByteArray()) }
    fun forget(c: Context) = Secrets.wipe(c)
}

sealed class SyncState { object Idle : SyncState(); object Syncing : SyncState(); object Live : SyncState(); data class Offline(val why: String) : SyncState() }

/**
 * The app-wide notes session: the repo, the search index (rebuilt after every change) and live sync while the app is open
 * (Server-Sent Events from /api/events). When the app goes away with unsent edits, SyncWorker uploads them.
 */
object Jot {
    lateinit var repo: Repo; private set
    private lateinit var app: Context
    val index = MutableStateFlow(NotesIndex(emptyList()))
    val unlocked = MutableStateFlow(false)
    val sync = MutableStateFlow<SyncState>(SyncState.Idle)
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var syncJob: Job? = null
    @Volatile private var events: Thread? = null
    @Volatile private var conn: HttpURLConnection? = null

    fun init(ctx: Context) {
        if (::repo.isInitialized) return
        app = ctx.applicationContext
        repo = Repo(Api, File(app.filesDir, "notes.sealed"), Build.MODEL ?: "Android")
        Keys.get(app)?.let { (dk, auth) -> runCatching { repo.open(dk, auth); unlocked.value = true } }
        scope.launch(Dispatchers.Default) {
            repo.version.collectLatest { delay(120); index.value = NotesIndex(repo.live()) }
        }
    }

    /** blocking (network): call off the main thread */
    fun unlock(pass: String) {
        val (dk, auth) = repo.unlock(pass)
        Keys.put(app, dk, auth)
        unlocked.value = true
        start()
    }
    fun lock() {
        stop(); repo.lock(); Keys.forget(app); unlocked.value = false
        WorkManager.getInstance(app).cancelUniqueWork("sync")
    }

    fun syncSoon(delayMs: Long = 1000) {
        if (!unlocked.value) return
        syncJob?.cancel()
        syncJob = scope.launch {
            delay(delayMs)
            if (sync.value != SyncState.Live) sync.value = SyncState.Syncing
            sync.value = try { repo.sync(); SyncState.Live } catch (e: CancellationException) { throw e } catch (e: Exception) { SyncState.Offline(e.message ?: e.toString()) }
            if (sync.value is SyncState.Offline && repo.hasDirty()) SyncWorker.enqueue(app)
        }
    }

    /** app on screen: keep a live connection and pull right away */
    fun start() {
        if (!unlocked.value) return
        syncSoon(0)
        if (events?.isAlive == true) return
        val t = Thread {
            var backoff = 1000L
            while (events === Thread.currentThread() && unlocked.value) {
                val auth = repo.auth ?: break
                try {
                    Api.events(auth, { conn = it }, { backoff = 1000L; syncSoon(0) }) { e ->
                        if (e.optInt("seq", -1) != repo.lastSeq) syncSoon(0)
                    }
                } catch (e: HttpError) { if (e.code == 401) { scope.launch(Dispatchers.Main) { lock() }; break } }
                catch (e: Exception) { /* offline: retry */ }
                if (events !== Thread.currentThread()) break
                try { Thread.sleep(backoff) } catch (e: InterruptedException) { break }
                backoff = minOf(backoff * 2, 15_000L)
            }
        }
        t.isDaemon = true
        events = t
        t.start()
    }
    /** app left: drop the connection; unsent edits go up in the background */
    fun stop() {
        events?.interrupt(); events = null
        val c = conn; conn = null
        Thread { runCatching { c?.disconnect() } }.start()
        if (unlocked.value && repo.hasDirty()) SyncWorker.enqueue(app)
    }
}

/** Uploads unsent edits once there's a network, even if the app was closed. */
class SyncWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        Jot.init(applicationContext)
        if (!Jot.unlocked.value) return Result.success()
        return try { Jot.repo.sync(); Result.success() } catch (e: Exception) { Result.retry() }
    }
    companion object {
        fun enqueue(ctx: Context) {
            WorkManager.getInstance(ctx).enqueueUniqueWork("sync", ExistingWorkPolicy.REPLACE,
                OneTimeWorkRequestBuilder<SyncWorker>().setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED))
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, java.util.concurrent.TimeUnit.SECONDS).build())
        }
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) Updater.reportInstalled(ctx)
    }
}
