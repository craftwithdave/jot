package app.jot

import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/** In-memory copy of server/server.js's rules, so two "phones" can sync in a unit test. */
class FakeServer : Server {
    var keys: JSONObject? = null
    val notes = LinkedHashMap<String, JSONObject>()
    var seq = 0
    private fun sha(b64: String) = MessageDigest.getInstance("SHA-256").digest(Crypto.unb64(b64)).joinToString("") { "%02x".format(it) }
    override fun call(method: String, path: String, auth: String?, json: JSONObject?): Pair<Int, JSONObject> {
        val err = { c: Int, m: String -> c to JSONObject().put("error", m) }
        if (path == "/api/salt") return keys?.let { 200 to JSONObject().put("salt", it.getString("salt")).put("iter", it.getInt("iter")) } ?: err(404, "not set up")
        if (path == "/api/init") { keys = JSONObject().put("salt", json!!.getString("salt")).put("iter", json.getInt("iter")).put("authHash", sha(json.getString("auth"))).put("wrap", json.getString("wrap")); return 200 to JSONObject() }
        if (auth == null || keys == null || sha(auth) != keys!!.getString("authHash")) return err(401, "wrong passphrase")
        if (path == "/api/keys") return 200 to JSONObject().put("wrap", keys!!.getString("wrap"))
        if (path.startsWith("/api/changes?since=")) {
            val since = path.substringAfter("=").toInt()
            return 200 to JSONObject().put("seq", seq).put("notes", JSONArray(notes.values.filter { it.getInt("seq") > since }.sortedBy { it.getInt("seq") }))
        }
        val id = path.removePrefix("/api/notes/")
        val cur = notes[id]
        if ((cur?.getInt("rev") ?: 0) != json!!.getInt("baseRev")) return 409 to JSONObject().put("error", "changed").put("note", cur ?: JSONObject.NULL)
        val n = JSONObject().put("id", id).put("rev", json.getInt("baseRev") + 1).put("seq", ++seq).put("del", json.optBoolean("del", false))
        if (!json.optBoolean("del", false)) n.put("blob", json.getString("blob"))
        notes[id] = n
        return 200 to JSONObject().put("rev", n.getInt("rev")).put("seq", n.getInt("seq"))
    }
}

class RepoTest {
    private fun tmp() = File.createTempFile("jot", ".sealed").also { it.delete(); it.deleteOnExit() }
    private fun bodies(r: Repo) = r.live().map { it.second.body }.sorted()

    @Test fun twoPhonesSync() = runBlocking {
        val srv = FakeServer()
        val a = Repo(srv, tmp(), "a").apply { iterations = 100_000 }
        val b = Repo(srv, tmp(), "b").apply { iterations = 100_000 }
        val (dk, auth) = a.unlock("pass ✓")
        b.unlock("pass ✓")
        a.edit("note1aaaaaaaaaaaaaaaaa", "Hello\nfrom a", 1000); a.sync(); b.sync()
        assertEquals(listOf("Hello\nfrom a"), bodies(b))
        // offline double edit: later one keeps the id, the other becomes a conflict copy
        a.edit("note1aaaaaaaaaaaaaaaaa", "Hello\nedit a", 2000)
        b.edit("note1aaaaaaaaaaaaaaaaa", "Hello\nedit b later", 3000)
        a.sync(); b.sync(); a.sync()
        assertEquals(listOf("Hello (conflict)\nedit a", "Hello\nedit b later").sorted(), bodies(a))
        assertEquals(bodies(a), bodies(b))
        // edit beats delete, then a plain delete
        val copy = a.live().first { it.second.body.contains("(conflict)") }.first
        a.remove(copy); b.edit(copy, "kept", 4000); a.sync(); b.sync(); a.sync()
        assertTrue(bodies(a).contains("kept")); assertEquals(bodies(a), bodies(b))
        b.remove(copy); b.sync(); a.sync()
        assertEquals(1, a.live().size); assertEquals(bodies(a), bodies(b))
        // pin syncs; local file reopens; nothing dirty left
        a.setPinned("note1aaaaaaaaaaaaaaaaa", true); a.sync(); b.sync()
        assertTrue(b.content("note1aaaaaaaaaaaaaaaaa")!!.pinned)
        assertFalse(a.hasDirty() || b.hasDirty())
        val f = tmp(); val c = Repo(srv, f, "c"); c.open(dk, auth); c.sync()
        val c2 = Repo(srv, f, "c"); c2.open(dk, auth)
        assertEquals(bodies(a), bodies(c2))
        assertFalse(String(f.readBytes(), Charsets.ISO_8859_1).contains("Hello"))
    }
}
