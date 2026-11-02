package app.jot

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** A note's decrypted content (same JSON on every device). The title is the first line of [body]. */
data class NoteContent(val body: String, val created: Long, val updated: Long, val pinned: Boolean = false, val dev: String? = null,
                       val cat: String? = null) {   // cat "reading" = Reading List & Ideas; null = normal note
    fun toJson(): JSONObject = JSONObject().put("body", body).put("created", created).put("updated", updated)
        .also { if (pinned) it.put("pinned", true); if (dev != null) it.put("dev", dev); if (cat != null) it.put("cat", cat) }
    companion object {
        const val READING = "reading"
        fun from(j: JSONObject) = NoteContent(j.getString("body"), j.getLong("created"), j.getLong("updated"), j.optBoolean("pinned", false),
            if (j.has("dev")) j.getString("dev") else null, if (j.has("cat")) j.getString("cat") else null)
    }
}

/** One note as this device knows it. rev = server revision it is based on (0 = never uploaded), dirty = not uploaded yet. */
data class NoteRecord(val id: String, val rev: Int, val dirty: Boolean, val del: Boolean, val content: NoteContent?, val edits: Int = 0) {
    fun toJson(): JSONObject = JSONObject().put("id", id).put("rev", rev).put("dirty", dirty).put("del", del).put("edits", edits)
        .also { if (content != null) it.put("content", content.toJson()) }
    companion object {
        fun from(j: JSONObject) = NoteRecord(j.getString("id"), j.getInt("rev"), j.getBoolean("dirty"), j.getBoolean("del"),
            j.optJSONObject("content")?.let { NoteContent.from(it) }, j.optInt("edits", 0))
    }
}

/** The server, as the repo needs it (a fake one in the unit tests). Returns (HTTP status, JSON body); throws only on network errors. */
interface Server {
    fun call(method: String, path: String, auth: String?, json: JSONObject? = null): Pair<Int, JSONObject>
}

class HttpError(val code: Int, msg: String) : Exception(msg)

/**
 * All notes on this phone, kept in one file sealed with the data key, plus the sync with the server.
 * Same steps as spec/client.mjs and the Mac app's NotesRepo (JotCore.swift).
 */
class Repo(private val server: Server, private val file: File, private val dev: String) {
    @Volatile var key: ByteArray? = null; private set
    @Volatile var auth: String? = null; private set
    private val records = HashMap<String, NoteRecord>()
    @Volatile var lastSeq = 0; private set
    /** bumped on every change, so the UI knows to refresh */
    val version = MutableStateFlow(0)
    private val syncLock = Mutex()
    var iterations = 600_000

    // ---- keys ----
    /** first device creates the account; later ones unlock. Returns (data key, auth) to keep in [Secrets]. */
    fun unlock(pass: String): Pair<ByteArray, String> {
        val (code, s) = server.call("GET", "/api/salt", null)
        if (code == 404) {
            val salt = Crypto.b64(Crypto.random(16))
            val d = Crypto.fromPassphrase(pass, salt, iterations)
            val dk = Crypto.random(32)
            ok(server.call("POST", "/api/init", null, JSONObject().put("salt", salt).put("iter", iterations).put("auth", d.auth).put("wrap", Crypto.wrapKey(d.kek, dk))))
            open(dk, d.auth)
            return dk to d.auth
        }
        if (code != 200) throw HttpError(code, s.optString("error", "server not reachable"))
        val d = Crypto.fromPassphrase(pass, s.getString("salt"), s.getInt("iter"))
        val wrap = ok(server.call("GET", "/api/keys", d.auth)).getString("wrap")
        val dk = Crypto.unwrapKey(d.kek, wrap)
        open(dk, d.auth)
        return dk to d.auth
    }
    private fun ok(r: Pair<Int, JSONObject>): JSONObject {
        if (r.first != 200) throw HttpError(r.first, r.second.optString("error", "HTTP ${r.first}"))
        return r.second
    }
    /** unlock from saved keys and load the local file */
    @Synchronized fun open(dk: ByteArray, auth: String) {
        key = dk; this.auth = auth
        records.clear(); lastSeq = 0
        if (file.exists()) {
            val st = JSONObject(String(Crypto.open(dk, file.readBytes(), "jot-local-v1")))
            lastSeq = st.getInt("lastSeq")
            val rs = st.getJSONObject("records")
            for (k in rs.keys()) records[k] = NoteRecord.from(rs.getJSONObject(k))
        }
        version.value++
    }
    @Synchronized fun lock() { key = null; auth = null; records.clear(); lastSeq = 0; file.delete(); version.value++ }
    @Synchronized private fun save() {
        val k = key ?: return
        val rs = JSONObject(); for ((id, r) in records) rs.put(id, r.toJson())
        val tmp = File(file.path + ".tmp")
        tmp.writeBytes(Crypto.seal(k, JSONObject().put("lastSeq", lastSeq).put("records", rs).toString().toByteArray(), "jot-local-v1"))
        tmp.renameTo(file)
    }
    private fun changed() { save(); version.value++ }

    // ---- local edits ----
    @Synchronized fun live(): List<Pair<String, NoteContent>> = records.values.mapNotNull { r -> if (r.del) null else r.content?.let { r.id to it } }
    @Synchronized fun content(id: String): NoteContent? = records[id]?.let { if (it.del) null else it.content }
    @Synchronized fun record(id: String): NoteRecord? = records[id]
    @Synchronized fun hasDirty() = records.values.any { it.dirty }

    @Synchronized fun edit(id: String, body: String, now: Long = System.currentTimeMillis()) {
        val cur = records[id]
        if (cur != null && !cur.del && cur.content?.body == body) return
        val c = (cur?.content ?: NoteContent(body, now, now)).copy(body = body, updated = now, dev = dev)
        records[id] = NoteRecord(id, cur?.rev ?: 0, true, false, c, (cur?.edits ?: 0) + 1)
        changed()
    }
    @Synchronized fun setPinned(id: String, on: Boolean) {
        val r = records[id] ?: return
        val c = r.content ?: return
        if (r.del) return
        records[id] = r.copy(dirty = true, content = c.copy(pinned = on), edits = r.edits + 1)
        changed()
    }
    @Synchronized fun setCat(id: String, cat: String?) {
        val r = records[id] ?: return
        val c = r.content ?: return
        if (r.del || c.cat == cat) return
        records[id] = r.copy(dirty = true, content = c.copy(cat = cat), edits = r.edits + 1)
        changed()
    }
    @Synchronized fun remove(id: String) {
        val r = records[id] ?: return
        if (r.rev == 0) records.remove(id) else records[id] = r.copy(dirty = true, del = true, content = null, edits = r.edits + 1)
        changed()
    }

    // ---- sync (blocking network: call off the main thread) ----
    suspend fun sync() = syncLock.withLock { syncOnce() }

    private fun syncOnce() {
        val k = key ?: return
        val ch = ok(server.call("GET", "/api/changes?since=$lastSeq", auth))
        val notes = ch.getJSONArray("notes")
        synchronized(this) {
            var touched = false
            for (i in 0 until notes.length()) {
                val n = notes.getJSONObject(i)
                val id = n.getString("id")
                if (records[id]?.dirty == true) continue
                val del = n.optBoolean("del", false)
                records[id] = NoteRecord(id, n.getInt("rev"), false, del, if (del) null else Crypto.openNote(k, id, n.getString("blob")))
                touched = true
            }
            val s = ch.getInt("seq")
            if (s != lastSeq) { lastSeq = s; touched = true }
            if (touched) changed()
        }
        repeat(5) {
            val dirty = synchronized(this) { records.values.filter { it.dirty } }
            if (dirty.isEmpty()) return
            for (r in dirty) push(r, k)
        }
    }

    private fun push(r: NoteRecord, k: ByteArray) {
        val body = JSONObject().put("baseRev", r.rev)
        if (r.del) body.put("del", true) else body.put("blob", Crypto.sealNote(k, r.id, r.content ?: return))
        val (code, j) = server.call("PUT", "/api/notes/${r.id}", auth, body)
        synchronized(this) {
            if (code == 200) {
                val now = records[r.id] ?: return
                records[r.id] = now.copy(rev = j.getInt("rev"), dirty = if (now.edits == r.edits) false else now.dirty)
                changed(); return
            }
            if (code != 409) throw HttpError(code, j.optString("error", "upload failed"))
            val s = j.optJSONObject("note")
            if (s == null) { records[r.id] = (records[r.id] ?: r).copy(rev = 0); changed(); return }   // server lost it: upload as new
            val srev = s.getInt("rev"); val sdel = s.optBoolean("del", false)
            val theirs = if (sdel) null else Crypto.openNote(k, r.id, s.getString("blob"))
            val take = { records[r.id] = NoteRecord(r.id, srev, false, sdel, theirs) }
            val mine = r.content
            when {
                sdel && r.del -> take()
                sdel -> records[r.id] = (records[r.id] ?: r).copy(rev = srev)
                r.del || mine == null || theirs == null -> take()
                theirs.body == mine.body -> take()
                else -> {
                    val oursWins = mine.updated > theirs.updated
                    val loser = if (oursWins) theirs else mine
                    if (oursWins) records[r.id] = (records[r.id] ?: r).copy(rev = srev) else take()
                    val cid = Crypto.newId()
                    records[cid] = NoteRecord(cid, 0, true, false, loser.copy(body = Logic.conflictCopy(loser.body)), 1)
                }
            }
            changed()
        }
    }
}
