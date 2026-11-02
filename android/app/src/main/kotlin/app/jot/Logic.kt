package app.jot

import java.text.Normalizer
import java.util.Locale
import kotlin.math.ln
import kotlin.math.sqrt

/**
 * Jot logic: titles, [[links]], #tags, search, related notes, mentions. A port of spec/logic.mjs
 * (the rules are written there); LogicTest checks it against spec/fixtures.json, like the Mac app's JotCore.swift.
 */
object Logic {
    val STOP = ("a an and are as at be but by for from has have i if in into is it its me my no not of on or our so " +
        "that the their them then there these they this to was we were what when which who will with you your " +
        "ada adalah akan aku dan dari di dengan ini itu ke kita mereka pada saya tidak untuk yang").split(" ").toSet()

    private fun isMark(cp: Int) = when (Character.getType(cp).toByte()) {
        Character.NON_SPACING_MARK, Character.COMBINING_SPACING_MARK, Character.ENCLOSING_MARK -> true
        else -> false
    }
    private fun isWordChar(cp: Int) = Character.isLetter(cp) || when (Character.getType(cp).toByte()) {
        Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
        else -> false
    }
    private fun isSpace(c: Char) = c.isWhitespace()

    fun normalize(s: String): String {
        val sb = StringBuilder()
        Normalizer.normalize(s, Normalizer.Form.NFKD).codePoints().forEach { if (!isMark(it)) sb.appendCodePoint(it) }
        return sb.toString().lowercase(Locale.ROOT)
    }
    fun words(s: String): List<String> {
        val out = ArrayList<String>(); val cur = StringBuilder()
        normalize(s).codePoints().forEach { cp ->
            if (isWordChar(cp)) cur.appendCodePoint(cp) else if (cur.isNotEmpty()) { out += cur.toString(); cur.setLength(0) }
        }
        if (cur.isNotEmpty()) out += cur.toString()
        return out
    }
    fun tokens(s: String) = words(s).filter { it.length >= 2 && it !in STOP }

    fun title(body: String): String {
        for (line in body.split("\n")) {
            var t = line.trim(::isSpace)
            if (t.startsWith("#")) t = t.trimStart('#').trim(::isSpace)
            if (t.isNotEmpty()) {
                val n = t.codePointCount(0, t.length)
                return if (n <= 120) t else t.substring(0, t.offsetByCodePoints(0, 120))
            }
        }
        return "Untitled"
    }
    fun titleKey(t: String): String = normalize(t).split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")

    val LINK = Regex("\\[\\[([^\\[\\]\\n]+?)\\]\\]")
    val TAG = Regex("(^|[^\\p{L}\\p{N}_&#])#([\\p{L}\\p{N}_/-]*\\p{L}[\\p{L}\\p{N}_/-]*)")

    fun links(body: String): List<String> {
        val out = ArrayList<String>()
        for (m in LINK.findAll(body)) {
            val k = titleKey(m.groupValues[1].split("|")[0].split("#")[0])
            if (k.isNotEmpty() && k !in out) out += k
        }
        return out
    }
    fun renameLinks(body: String, oldKey: String, newTitle: String): String = LINK.replace(body) { m ->
        val inner = m.groupValues[1]
        val bar = inner.indexOf('|'); val target = if (bar >= 0) inner.substring(0, bar) else inner
        val hash = target.indexOf('#'); val name = if (hash >= 0) target.substring(0, hash) else target
        if (titleKey(name) != oldKey) m.value
        else "[[" + newTitle + (if (hash >= 0) target.substring(hash) else "") + (if (bar >= 0) inner.substring(bar) else "") + "]]"
    }
    fun tags(body: String): List<String> {
        val out = ArrayList<String>()
        for (m in TAG.findAll(body)) { val t = normalize(m.groupValues[2]); if (t !in out) out += t }
        return out
    }
    fun conflictCopy(body: String): String {
        val lines = body.split("\n").toMutableList()
        val i = lines.indexOfFirst { it.trim(::isSpace).isNotEmpty() }
        if (i < 0) return "(conflict)\n$body"
        lines[i] = lines[i].trimEnd(::isSpace) + " (conflict)"
        return lines.joinToString("\n")
    }

    /** an image / video in a note: `![alt](jot-media:<id>)` on a line of its own (leading spaces allowed); alt is
     *  "image", "video" or "video 0:42" (duration shown on the thumbnail) */
    data class Media(val id: String, val kind: String, val duration: String)
    val MEDIA = Regex("^[ \\t]*!\\[([^\\]\\n]*)\\]\\(jot-media:([A-Za-z0-9_-]{16,64})\\)[ \\t]*$", RegexOption.MULTILINE)
    fun media(body: String): List<Media> = MEDIA.findAll(body).map { m ->
        val parts = m.groupValues[1].trim().split(Regex("\\s+"))
        val kind = parts[0]; val dur = parts.getOrNull(1) ?: ""
        Media(m.groupValues[2], if (kind == "video") "video" else "image", if (kind == "video") dur else "")
    }.toList()
}

data class Scored(val id: String, val score: Double)

class IndexedNote(val id: String, val body: String, val created: Long, val updated: Long, val pinned: Boolean, val cat: String?, val title: String, val key: String,
                  val tf: Map<String, Int>, val len: Int, val links: List<String>, val tags: List<String>, val words: List<String>)

class NotesIndex(list: List<Pair<String, NoteContent>>) {
    val notes = LinkedHashMap<String, IndexedNote>()
    val order = ArrayList<String>()
    private val byKey = HashMap<String, String>()
    private val df = HashMap<String, Int>()
    private val terms: List<String>
    private val avg: Double
    val out = HashMap<String, List<String>>()
    val back = HashMap<String, MutableList<String>>()
    val count get() = notes.size

    companion object { const val K1 = 1.2; const val B = 0.75; const val TITLE_TF = 3; const val RELATED_MIN = 0.08; const val RELATED_MAX = 5 }

    init {
        var total = 0
        for ((id, c) in list.sortedWith(compareBy<Pair<String, NoteContent>>({ it.second.created }, { it.first }))) {
            val t = Logic.title(c.body)
            val tf = HashMap<String, Int>()
            for (w in Logic.tokens(t)) tf[w] = (tf[w] ?: 0) + TITLE_TF
            for (w in Logic.tokens(c.body)) tf[w] = (tf[w] ?: 0) + 1
            val len = tf.values.sum()
            total += len
            for (w in tf.keys) df[w] = (df[w] ?: 0) + 1
            val key = Logic.titleKey(t)
            byKey.putIfAbsent(key, id)
            notes[id] = IndexedNote(id, c.body, c.created, c.updated, c.pinned, c.cat, t, key, tf, len, Logic.links(c.body), Logic.tags(c.body), Logic.words(c.body))
            order += id
        }
        avg = if (notes.isEmpty()) 1.0 else total.toDouble() / notes.size
        terms = df.keys.sorted()
        for (id in order) {
            val to = ArrayList<String>()
            for (k in notes[id]!!.links) { val t = byKey[k]; if (t != null && t != id && t !in to) to += t }
            out[id] = to
            for (t in to) back.getOrPut(t) { ArrayList() } += id
        }
    }

    fun resolve(name: String): String? = byKey[Logic.titleKey(name)]
    fun backlinks(id: String): List<String> = (back[id] ?: emptyList()).sorted()
    fun edges(): List<Pair<String, String>> = order.flatMap { from -> (out[from] ?: emptyList()).map { from to it } }

    fun prefixed(p: String): List<String> {
        var lo = 0; var hi = terms.size
        while (lo < hi) { val mid = (lo + hi) ushr 1; if (terms[mid] < p) lo = mid + 1 else hi = mid }
        val res = ArrayList<String>()
        var i = lo
        while (i < terms.size && terms[i].startsWith(p)) { res += terms[i]; i++ }
        return res
    }

    fun search(query: String, limit: Int = 50): List<Scored> {
        val q = Logic.words(query)
        val qt = q.filterIndexed { i, w -> i == q.size - 1 || (w.length >= 2 && w !in Logic.STOP) }
        if (qt.isEmpty()) return emptyList()
        val sets = qt.map { prefixed(it) }
        if (sets.any { it.isEmpty() }) return emptyList()
        val n = notes.size.toDouble()
        data class R(val id: String, val score: Double, val updated: Long)
        val res = ArrayList<R>()
        for (id in order) {
            val note = notes[id]!!
            var score = 0.0; var ok = true
            for (set in sets) {
                var best = -1.0
                for (t in set) {
                    val tfi = note.tf[t] ?: continue
                    val tf = tfi.toDouble(); val d = df[t]!!.toDouble()
                    val idf = ln(1 + (n - d + 0.5) / (d + 0.5))
                    val s = idf * tf * (K1 + 1) / (tf + K1 * (1 - B + B * note.len / avg))
                    if (s > best) best = s
                }
                if (best < 0) { ok = false; break }
                score += best
            }
            if (ok) res += R(id, score, note.updated)
        }
        res.sortWith(compareByDescending<R> { it.score }.thenByDescending { it.updated }.thenBy { it.id })
        return res.take(limit).map { Scored(it.id, it.score) }
    }

    private val vecs = HashMap<String, Pair<Map<String, Double>, Double>>()
    private fun vector(note: IndexedNote): Pair<Map<String, Double>, Double> = vecs.getOrPut(note.id) {
        val v = HashMap<String, Double>(); var norm = 0.0
        val n = notes.size.toDouble()
        for ((t, tf) in note.tf) { val w = (1 + ln(tf.toDouble())) * ln(n / df[t]!!); if (w > 0) { v[t] = w; norm += w * w } }
        v to sqrt(norm)
    }
    fun related(id: String): List<Scored> {
        val me = notes[id] ?: return emptyList()
        if (notes.size < 2) return emptyList()
        val (av, an) = vector(me)
        if (an == 0.0) return emptyList()
        val linked = (out[id] ?: emptyList()).toSet() + (back[id] ?: emptyList())
        val res = ArrayList<Scored>()
        for (oid in order) {
            if (oid == id || oid in linked) continue
            val (bv, bn) = vector(notes[oid]!!)
            if (bn == 0.0) continue
            var dot = 0.0
            for ((t, w) in av) { val x = bv[t]; if (x != null) dot += w * x }
            val s = dot / (an * bn)
            if (s >= RELATED_MIN) res += Scored(oid, s)
        }
        res.sortWith(compareByDescending<Scored> { it.score }.thenBy { it.id })
        return res.take(RELATED_MAX)
    }
    data class AutoEdge(val a: String, val b: String, val kind: String, val score: Double)
    /** edges nobody typed (spec autoEdges): mentions, then related pairs; one per pair, linked pairs left out, a < b */
    fun autoEdges(): List<AutoEdge> {
        fun key(x: String, y: String) = if (x < y) "$x $y" else "$y $x"
        val linked = edges().map { key(it.first, it.second) }.toHashSet()
        val res = LinkedHashMap<String, AutoEdge>()
        fun add(x: String, y: String, kind: String, score: Double) {
            val k = key(x, y)
            if (k !in linked && k !in res) res[k] = AutoEdge(minOf(x, y), maxOf(x, y), kind, score)
        }
        for (id in order) for (m in mentions(id)) add(id, m, "mention", 0.0)
        for (id in order) for (r in related(id)) add(id, r.id, "related", r.score)
        return res.values.sortedWith(compareBy<AutoEdge>({ it.a }, { it.b }))
    }
    fun mentions(id: String): List<String> {
        val me = notes[id] ?: return emptyList()
        val tw = Logic.words(me.title)
        if (tw.joinToString("").length < 3) return emptyList()
        val res = ArrayList<String>()
        for (oid in order) {
            if (oid == id || (out[oid] ?: emptyList()).contains(id)) continue
            val w = notes[oid]!!.words
            for (i in 0..(w.size - tw.size)) { if (w.subList(i, i + tw.size) == tw) { res += oid; break } }
        }
        return res.sorted()
    }
}
