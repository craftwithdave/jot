package app.jot

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.ConnectivityManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.work.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One-tap updates from the user's own VPS (BuildConfig.ORIGIN, tailnet only; never Google Play).
 * build.sh publishes /app.json {versionCode, versionName, size, sha256, notes, patches} next to /app.apk.
 * If there is a patch from the installed version, only that small patch is downloaded and applied to the
 * installed APK (Patch.kt); otherwise, or if anything about the patch goes wrong, the full APK is downloaded.
 * Either way the result is checked against that SHA-256, and Android itself only accepts an APK signed
 * with the same key as the installed app.
 *
 * Automatic updates: UpdateWorker checks every few hours and installs silently (UPDATE_PACKAGES_WITHOUT_USER_ACTION)
 * when the app isn't on screen; a notification says what changed.
 */
object Updater {
    const val CHANNEL = "updates"
    private const val NOTIF_ID = 2
    private val busy = AtomicBoolean(false)

    /** A patch from the installed version: /patches/<from>-<to>.patch, applies only to an APK with SHA-256 [fromSha]. */
    data class PatchInfo(val url: String, val size: Long, val fromSha: String)
    data class Info(val code: Int, val name: String, val size: Long, val sha256: String, val notes: String, val patch: PatchInfo? = null) {
        /** What the user actually downloads. */
        val downloadSize get() = patch?.size ?: size
    }

    sealed class State {
        object None : State()
        data class Available(val info: Info) : State()
        data class Downloading(val info: Info, val pct: Int) : State()
        data class Installing(val info: Info) : State()
        data class Failed(val info: Info, val error: String) : State()
    }

    val state = MutableStateFlow<State>(State.None)

    /** Network errors (Tailscale off, …) quietly mean "no update". */
    fun check() {
        val c = URL(BuildConfig.ORIGIN + "/android/app.json").openConnection() as HttpURLConnection
        try {
            c.connectTimeout = 10_000; c.readTimeout = 15_000; c.useCaches = false
            if (c.responseCode != 200) return
            val j = JSONObject(c.inputStream.bufferedReader().use { it.readText() })
            val code = j.getInt("versionCode")
            val patch = j.optJSONArray("patches")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) } }
                ?.firstOrNull { it.optInt("from") == BuildConfig.VERSION_CODE }
                ?.let { PatchInfo("/android/patches/${BuildConfig.VERSION_CODE}-$code.patch", it.getLong("size"), it.getString("fromSha")) }
            val info = Info(code, j.getString("versionName"), j.getLong("size"), j.getString("sha256"), j.optString("notes"), patch)
            val cur = state.value
            if (info.code > BuildConfig.VERSION_CODE) {
                if (cur is State.None || (cur is State.Available && cur.info != info) || (cur is State.Failed)) state.value = State.Available(info)
            } else if (cur is State.Available) state.value = State.None
        } catch (e: Exception) { /* offline */ } finally { c.disconnect() }
    }

    /**
     * Blocking: download (patch if possible), verify, hand to PackageInstaller. Progress goes to [state].
     * [background]: started by UpdateWorker. Then the full APK is only fetched on an unmetered network,
     * and nothing is installed unless [safe] still holds right before the install (app not on screen).
     */
    fun install(ctx: Context, info: Info, background: Boolean = false, safe: () -> Boolean = { true }) {
        if (!busy.compareAndSet(false, true)) return
        try {
            val file = File(ctx.cacheDir, "update.apk")
            val viaPatch = info.patch?.let { runCatching { fromPatch(ctx, info, it, file) }.getOrDefault(false) } ?: false
            if (!viaPatch) {
                if (background && ctx.getSystemService(ConnectivityManager::class.java).isActiveNetworkMetered) {
                    state.value = State.Available(info); return   // 40 MB on mobile data: wait for Wi-Fi (or a tap)
                }
                val md = MessageDigest.getInstance("SHA-256")
                download(info, "/android/jot.apk", info.size, file, md, 0, 100)
                if (!hex(md).equals(info.sha256, ignoreCase = true)) { file.delete(); throw Exception("Download was damaged or changed (checksum mismatch)") }
            }
            if (background && !safe()) { state.value = State.Available(info); return }   // try again next time

            state.value = State.Installing(info)
            Prefs.pendingUpdate(ctx, "${info.code}|${info.name}|${info.notes}")
            val pi = ctx.packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                setAppPackageName(ctx.packageName)
                setSize(file.length())
                if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
            val id = pi.createSession(params)
            pi.openSession(id).use { s ->
                s.openWrite("jot.apk", 0, file.length()).use { out -> file.inputStream().use { it.copyTo(out) }; s.fsync(out) }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                val cb = PendingIntent.getBroadcast(ctx, id, Intent(ctx, UpdateReceiver::class.java).setPackage(ctx.packageName)
                    .putExtra("bg", background), flags)
                s.commit(cb.intentSender)
            }
        } catch (e: Exception) {
            state.value = State.Failed(info, e.message ?: e.toString())
        } finally { busy.set(false) }
    }

    /** Check every 6 hours (when there's a network) and install by itself. Off via Settings → App. */
    fun schedule(ctx: Context) {
        val wm = WorkManager.getInstance(ctx)
        if (!Prefs.autoUpdate(ctx)) { wm.cancelUniqueWork("update-periodic"); return }
        wm.enqueueUniquePeriodicWork("update-periodic", ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<UpdateWorker>(6, TimeUnit.HOURS)
                .setConstraints(Constraints(requiredNetworkType = NetworkType.CONNECTED)).build())
    }

    /** Safe to restart the app now: nobody is looking at it. */
    fun quiet() = !App.visible

    /** UpdateWorker: look for a new version and install it if it's a good moment. */
    fun autoUpdate(ctx: Context) {
        if (!Prefs.autoUpdate(ctx) || !quiet()) return
        check()
        val info = when (val s = state.value) { is State.Available -> s.info; is State.Failed -> s.info; else -> return }
        install(ctx, info, background = true, safe = ::quiet)
    }

    /** After an update (MY_PACKAGE_REPLACED): say what changed, once. */
    fun reportInstalled(ctx: Context) {
        val p = Prefs.pendingUpdate(ctx)?.split("|", limit = 3) ?: return
        Prefs.pendingUpdate(ctx, null)
        if (p[0].toIntOrNull() != BuildConfig.VERSION_CODE) return
        notify(ctx, "Jot updated to ${p[1]}", p.getOrNull(2)?.takeIf { it.isNotBlank() } ?: "Installed automatically", null)
    }

    fun notify(ctx: Context, title: String, text: String, tap: PendingIntent?) {
        val open = tap ?: PendingIntent.getActivity(ctx, 0, Intent(ctx, app.jot.ui.MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        ctx.getSystemService(NotificationManager::class.java).notify(NOTIF_ID,
            NotificationCompat.Builder(ctx, CHANNEL).setSmallIcon(R.drawable.ic_tile).setContentTitle(title).setContentText(text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(text)).setSilent(true).setAutoCancel(true).setContentIntent(open).build())
    }

    /** Rebuild the new APK from the installed one + the patch. False (never an exception) means "use the full APK". */
    private fun fromPatch(ctx: Context, info: Info, p: PatchInfo, file: File): Boolean {
        val installed = File(ctx.applicationInfo.sourceDir)
        val pf = File(ctx.cacheDir, "update.patch")
        try {
            val md0 = MessageDigest.getInstance("SHA-256")
            installed.inputStream().use { inp -> val b = ByteArray(64 * 1024); while (true) { val n = inp.read(b); if (n < 0) break; md0.update(b, 0, n) } }
            if (!hex(md0).equals(p.fromSha, ignoreCase = true)) return false     // installed APK isn't the one the patch was made from
            download(info, p.url, p.size, pf, null, 0, 80)
            val md = MessageDigest.getInstance("SHA-256")
            java.security.DigestOutputStream(file.outputStream().buffered(), md).use { out ->
                Patch.apply(installed, pf, out) { done, total -> state.value = State.Downloading(info, 80 + (done * 20 / total.coerceAtLeast(1)).toInt()) }
            }
            if (hex(md).equals(info.sha256, ignoreCase = true)) return true
            file.delete(); return false
        } catch (e: Exception) {
            file.delete(); return false
        } finally { pf.delete() }
    }

    /** Download [path] to [file], reporting progress as [from]..[to] percent. */
    private fun download(info: Info, path: String, size: Long, file: File, md: MessageDigest?, from: Int, to: Int) {
        val c = URL(BuildConfig.ORIGIN + path).openConnection() as HttpURLConnection
        c.connectTimeout = 15_000; c.readTimeout = 60_000; c.useCaches = false
        try {
            if (c.responseCode != 200) throw Exception("Download failed (HTTP ${c.responseCode})")
            c.inputStream.use { inp -> file.outputStream().use { out ->
                val buf = ByteArray(64 * 1024); var done = 0L; var last = -1
                while (true) {
                    val n = inp.read(buf); if (n < 0) break
                    out.write(buf, 0, n); md?.update(buf, 0, n); done += n
                    val pct = from + ((done * (to - from)) / size.coerceAtLeast(1)).toInt().coerceAtMost(to - from)
                    if (pct != last) { last = pct; state.value = State.Downloading(info, pct) }
                }
            } }
        } finally { c.disconnect() }
    }

    private fun hex(md: MessageDigest) = md.digest().joinToString("") { "%02x".format(it) }
}

/** UpdateReceiver's counterpart: the periodic background check. */
class UpdateWorker(ctx: Context, params: WorkerParameters) : Worker(ctx, params) {
    override fun doWork(): Result { Updater.autoUpdate(applicationContext); return Result.success() }
}

/** Install result from PackageInstaller: ask the user to confirm if Android wants that, report failures. */
class UpdateReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val info = (Updater.state.value as? Updater.State.Installing)?.info
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                              else intent.getParcelableExtra(Intent.EXTRA_INTENT)
                if (confirm != null && intent.getBooleanExtra("bg", false) && !App.visible) {
                    // Android still wants a tap, and apps can't open screens from the background: leave it in a notification
                    val tap = PendingIntent.getActivity(ctx, 1, confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                    Updater.notify(ctx, "Jot ${info?.name ?: "update"} is ready", "Tap to install", tap)
                    Prefs.pendingUpdate(ctx, null)
                    if (info != null) Updater.state.value = Updater.State.Available(info)
                } else confirm?.let { ctx.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            }
            PackageInstaller.STATUS_SUCCESS -> { /* Android restarts us; BootReceiver (MY_PACKAGE_REPLACED) reports it */ }
            else -> {
                val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "Install failed"
                if (info != null) Updater.state.value =
                    if (status == PackageInstaller.STATUS_FAILURE_ABORTED) Updater.State.Available(info) else Updater.State.Failed(info, msg)
            }
        }
    }
}
