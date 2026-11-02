package app.jot

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/** fixtures.json comes from spec/fixtures.mjs (the reference logic.mjs); build.sh copies it in. */
class LogicTest {
    private val fx = JSONObject(javaClass.getResource("/fixtures.json")!!.readText())
    private fun strs(a: JSONArray) = (0 until a.length()).map { a.getString(it) }
    private fun scored(got: List<Scored>, want: JSONArray, what: String) {
        assertEquals("$what count: $got", want.length(), got.size)
        for (i in got.indices) {
            val w = want.getJSONObject(i)
            assertEquals("$what id $i", w.getString("id"), got[i].id)
            assertTrue("$what score $i ${got[i].score} vs ${w.getDouble("score")}", abs(got[i].score - w.getDouble("score")) < 1e-6)
        }
    }
    private val notes = fx.getJSONArray("notes").let { a -> (0 until a.length()).map { a.getJSONObject(it) } }
        .map { it.getString("id") to NoteContent(it.getString("body"), it.getLong("created"), it.getLong("updated")) }
    private val ix = NotesIndex(notes)

    @Test fun perNote() {
        val a = fx.getJSONArray("perNote")
        for (i in 0 until a.length()) {
            val p = a.getJSONObject(i); val id = p.getString("id"); val body = ix.notes[id]!!.body
            assertEquals("title $id", p.getString("title"), Logic.title(body))
            assertEquals("titleKey $id", p.getString("titleKey"), Logic.titleKey(Logic.title(body)))
            assertEquals("links $id", strs(p.getJSONArray("links")), Logic.links(body))
            assertEquals("tags $id", strs(p.getJSONArray("tags")), Logic.tags(body))
            assertEquals("backlinks $id", strs(p.getJSONArray("backlinks")), ix.backlinks(id))
            scored(ix.related(id), p.getJSONArray("related"), "related $id")
            assertEquals("mentions $id", strs(p.getJSONArray("mentions")), ix.mentions(id))
        }
    }
    @Test fun tokens() {
        val a = fx.getJSONArray("tokens")
        for (i in 0 until a.length()) {
            val t = a.getJSONObject(i); val s = t.getString("s")
            assertEquals("words $s", strs(t.getJSONArray("words")), Logic.words(s))
            assertEquals("tokens $s", strs(t.getJSONArray("tokens")), Logic.tokens(s))
        }
    }
    @Test fun search() {
        val a = fx.getJSONArray("search")
        for (i in 0 until a.length()) { val q = a.getJSONObject(i); scored(ix.search(q.getString("q")), q.getJSONArray("results"), "search '${q.getString("q")}'") }
    }
    @Test fun graphResolveRename() {
        val e = fx.getJSONArray("edges")
        assertEquals((0 until e.length()).map { e.getJSONArray(it).let { p -> p.getString(0) to p.getString(1) } }, ix.edges())
        val ae = fx.getJSONArray("autoEdges"); val got = ix.autoEdges()
        assertEquals("autoEdges $got", ae.length(), got.size)
        for (i in 0 until ae.length()) { val w = ae.getJSONObject(i); val g = got[i]
            assertEquals(w.getString("a"), g.a); assertEquals(w.getString("b"), g.b); assertEquals(w.getString("kind"), g.kind)
            assertEquals("autoEdges score $i", w.getDouble("score"), g.score, 1e-6) }
        val r = fx.getJSONArray("resolve")
        for (i in 0 until r.length()) { val p = r.getJSONArray(i); assertEquals(if (p.isNull(1)) null else p.getString(1), ix.resolve(p.getString(0))) }
        val rn = fx.getJSONArray("rename")
        for (i in 0 until rn.length()) { val p = rn.getJSONObject(i)
            assertEquals(p.getString("out"), Logic.renameLinks(p.getString("body"), p.getString("oldKey"), p.getString("newTitle"))) }
        assertEquals("  \nTitle (conflict)\nx", Logic.conflictCopy("  \nTitle  \nx"))
    }
    @Test fun content() {   // pinned / cat read, and written back unchanged
        val a = fx.getJSONArray("content")
        for (i in 0 until a.length()) {
            val f = a.getJSONObject(i); val c = NoteContent.from(JSONObject(f.getString("json")))
            assertEquals(f.getBoolean("pinned"), c.pinned)
            assertEquals(if (f.isNull("cat")) null else f.getString("cat"), c.cat)
            assertEquals(c, NoteContent.from(c.toJson()))
        }
    }
    @Test fun media() {
        val a = fx.getJSONArray("media")
        for (i in 0 until a.length()) {
            val c = a.getJSONObject(i); val want = c.getJSONArray("media")
            val got = Logic.media(c.getString("body"))
            assertEquals(c.getString("body"), (0 until want.length()).map { want.getJSONObject(it).let { m -> Logic.Media(m.getString("id"), m.getString("kind"), m.getString("duration")) } }, got)
        }
    }
}
