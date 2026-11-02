package app.jot

/**
 * Live-preview editing rules, ported from the Mac editor (mac//Sources/JotEditor.swift, JotCore.swift) so both
 * apps behave alike. Plain Kotlin (no Compose) so it is unit-tested (MarkupTest).
 *  - which Markdown symbols are hidden (# ** * ~~ <u></u> ` ``` "> " "- [ ]" "---", and "[" "](url)" of a
 *    [Title](https://…) link unless the caret touches it) and the display ↔ text offsets
 *  - where the caret may rest, and Backspace / Delete that never leave half a symbol behind
 *  - format actions (format bar), list continuation and nesting with 1/2/3 → i/ii/iii and A/B/C → a/b/c numbering
 *  - highlight.js output → colour spans (HLParse)
 *  - images / videos (`![alt](jot-media:<id>)` lines, Logic.MEDIA): the line's text is always hidden (a thumbnail is
 *    drawn there) and the caret never stays on it (offMedia); Backspace at the start of the next line removes the whole line
 */

/** text + selection (start..end, start == end for a caret) */
data class Ed(val text: String, val start: Int, val end: Int = start) {
    val collapsed get() = start == end
    val min get() = minOf(start, end)
    val max get() = maxOf(start, end)
}

// ---- ordered-list markers ----

object ListMarker {
    enum class Kind { NUMBER, UPPER, LOWER, ROMAN, UPPER_ROMAN }
    private val ROMAN = listOf(1000 to "m", 900 to "cm", 500 to "d", 400 to "cd", 100 to "c", 90 to "xc",
        50 to "l", 40 to "xl", 10 to "x", 9 to "ix", 5 to "v", 4 to "iv", 1 to "i")

    fun toRoman(n0: Int): String {
        var n = maxOf(1, n0); val out = StringBuilder()
        for ((v, s) in ROMAN) while (n >= v) { out.append(s); n -= v }
        return out.toString()
    }
    fun fromRoman(s0: String): Int? {
        val s = s0.lowercase()
        if (s.isEmpty() || !s.all { it in "ivxlcdm" }) return null
        var rest = s; var n = 0
        for ((v, d) in ROMAN) while (rest.startsWith(d)) { n += v; rest = rest.substring(d.length) }
        return if (rest.isEmpty() && toRoman(n) == s) n else null
    }
    /** what a marker token is; prev = the token of the item above at the same depth ("i"/"v" are letters when they
     *  continue a letter list, roman when they start one ("i") or continue a roman one) */
    fun kind(t: String, prev: String?): Kind? {
        if (t.isNotEmpty() && t.all { it.isDigit() }) return Kind.NUMBER
        val upper = t == t.uppercase()
        val isRoman = fromRoman(t) != null
        if (t.length == 1 && t[0].isLetter() && t[0].code < 128) {
            if (prev != null) {
                val pk = kind(prev, null)
                if (pk != null) {
                    if ((pk == Kind.ROMAN || pk == Kind.UPPER_ROMAN) && isRoman &&
                        (prev.length > 1 || fromRoman(prev)?.plus(1) == fromRoman(t))) return if (upper) Kind.UPPER_ROMAN else Kind.ROMAN
                    if (prev.length == 1) return if (upper) Kind.UPPER else Kind.LOWER
                }
            }
            return if (isRoman && (t == "i" || t == "I")) (if (upper) Kind.UPPER_ROMAN else Kind.ROMAN) else (if (upper) Kind.UPPER else Kind.LOWER)
        }
        return if (isRoman) (if (upper) Kind.UPPER_ROMAN else Kind.ROMAN) else null
    }
    fun value(t: String, k: Kind): Int = when (k) {
        Kind.NUMBER -> t.toIntOrNull() ?: 1
        Kind.UPPER, Kind.LOWER -> t.lowercase()[0] - 'a' + 1
        Kind.ROMAN, Kind.UPPER_ROMAN -> fromRoman(t) ?: 1
    }
    fun token(n: Int, k: Kind): String = when (k) {
        Kind.NUMBER -> n.toString()
        Kind.LOWER -> ('a' + (n.coerceIn(1, 26) - 1)).toString()
        Kind.UPPER -> ('A' + (n.coerceIn(1, 26) - 1)).toString()
        Kind.ROMAN -> toRoman(n)
        Kind.UPPER_ROMAN -> toRoman(n).uppercase()
    }
    fun next(t: String, prev: String?): String { val k = kind(t, prev) ?: return t; return token(value(t, k) + 1, k) }
    /** the style a child list uses under a parent of kind k */
    fun childKind(k: Kind) = when (k) { Kind.NUMBER, Kind.LOWER -> Kind.ROMAN; else -> Kind.LOWER }
}

// ---- the rules ----

object Markup {
    private val M = setOf(RegexOption.MULTILINE)
    val HEADING = Regex("^(#{1,6})[ \\t]+(.*)$", M)
    val HEADING_PREFIX = Regex("^(#{1,6}) +")
    val CHECK = Regex("^([ \\t]*)([-*+] (\\[[ xX]\\]))(.*)$", M)
    val BULLET = Regex("^([ \\t]*)([-*+]) (?!\\[[ xX]\\])", M)
    val NUMBER = Regex("^([ \\t]*)((?:\\d+|[A-Za-z]|[ivxlcdmIVXLCDM]+)[.)]) ", M)
    val RULE = Regex("^[ \\t]*-{3,}[ \\t]*$", M)
    val QUOTE = Regex("^(>) (.*)$", M)
    val FENCE = Regex("^```[^\\n]*\\n[\\s\\S]*?^```[ \\t]*$", M)
    val CODE = Regex("`[^`\\n]+`")
    val BOLD = Regex("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    val ITALIC = Regex("(?<![*\\w])([*_])(?=\\S)([^*_\\n]+?)(?<=\\S)\\1(?![*\\w])")
    val STRIKE = Regex("~~(?=\\S)(.+?)(?<=\\S)~~")
    val UNDERLINE = Regex("<u>(.+?)</u>")
    val MDLINK = Regex("\\[([^\\[\\]\\n]+)\\]\\((https?://[^)\\s]+)\\)")
    private val LIST = Regex("^([ \\t]*)([-*+] \\[[ xX]\\] |[-*+] |(\\d+|[A-Za-z]|[ivxlcdmIVXLCDM]+)([.)]) |> )")

    fun lineStart(s: String, at: Int): Int = if (at <= 0) 0 else s.lastIndexOf('\n', at - 1) + 1
    fun lineEnd(s: String, at: Int): Int = s.indexOf('\n', at.coerceAtMost(s.length)).let { if (it < 0) s.length else it }

    // ---- lists ----

    data class Item(val indent: String, val marker: String, val token: String?, val punct: String, val length: Int)

    fun listItem(line: String): Item? {
        val m = LIST.find(line) ?: return null
        val tok = m.groups[3]?.value
        if (tok != null && tok.length > 1 && !tok.all { it.isDigit() } && ListMarker.fromRoman(tok) == null) return null   // "mix." etc.
        return Item(m.groupValues[1], m.groupValues[2], tok, m.groups[4]?.value ?: "", m.range.last + 1)
    }
    fun depth(indent: String) = indent.count { it == '\t' } + (indent.count { it == ' ' } + 2) / 4

    /** marker token of the nearest item above lineStart at depth d under the same parent (null if none) */
    fun prevToken(s: String, lineStart: Int, d: Int): String? {
        var end = lineStart
        while (end > 0) {
            val ls = lineStart(s, end - 1)
            val it = listItem(s.substring(ls, end - 1)) ?: return null
            end = ls
            val dd = depth(it.indent)
            if (dd == d) return it.token
            if (dd < d) return null
        }
        return null
    }

    /** indented plain lines that continue the list item above (a task's "  summary" line): their line starts */
    fun continuations(s: String): List<Int> {
        val out = ArrayList<Int>(); val code = fences(s).map { it.block }
        var ls = 0; var inItem = false
        while (ls <= s.length) {
            val le = lineEnd(s, ls); val line = s.substring(ls, le)
            val item = listItem(line)
            inItem = when {
                code.any { ls in it } -> false
                item != null -> item.marker != "> "
                inItem && line.isNotBlank() && (line[0] == ' ' || line[0] == '\t') -> { out.add(ls); true }
                else -> false
            }
            ls = le + 1
        }
        return out
    }

    // ---- [Title](https://…) links ----

    /** markdown links outside code spans / blocks (groups: 1 = title, 2 = url) */
    fun mdLinks(s: String): List<MatchResult> {
        val code = CODE.findAll(s).map { it.range }.toList() + fences(s).map { it.block }
        return MDLINK.findAll(s).filter { m -> code.none { it.first <= m.range.last && m.range.first <= it.last } }.toList()
    }
    /** the links a caret / selection (a..b) touches, i.e. reaches from just after "[" to just after ")": these show
     *  their "[" and "](url)" so they can be edited */
    fun touched(s: String, a: Int, b: Int): List<IntRange> = mdLinks(s).map { it.range }.filter { a <= it.last + 1 && b > it.first }

    // ---- images / videos ----

    /** media lines outside code blocks: the whole line (leading spaces up to the line end, no newline) */
    fun mediaLines(s: String): List<IntRange> {
        val code = fences(s).map { it.block }
        return Logic.MEDIA.findAll(s).map { it.range }.filter { r -> code.none { it.first <= r.last && r.first <= it.last } }.toList()
    }
    /** everything a caret / selection shows whole: touched [Title](url) links (media lines never show their text) */
    fun shownAt(s: String, a: Int, b: Int) = touched(s, a, b)
    /** the caret never stays on a media line: forward → start of the next line, backward → end of the line above
     *  (the other way when there is none) */
    fun offMedia(s: String, p: Int, forward: Boolean): Int {
        var q = p
        repeat(8) {                                                         // stacked media lines
            val r = mediaLines(s).firstOrNull { q >= it.first && q <= it.last + 1 } ?: return q
            val next = if (r.last + 1 < s.length) r.last + 2 else -1        // after the newline
            val prev = if (r.first > 0) r.first - 1 else -1                 // end of the line above
            q = if (forward) (if (next >= 0) next else if (prev >= 0) prev else return q) else (if (prev >= 0) prev else if (next >= 0) next else return q)
        }
        return q
    }
    /** where a media line's "![" starts (after its indent) */
    fun mediaStart(s: String, line: IntRange): Int { var i = line.first; while (i <= line.last && (s[i] == ' ' || s[i] == '\t')) i++; return i }

    /** puts `![alt](jot-media:<id>)` on a line of its own at the caret (splitting the line if needed); the caret
     *  ends on the line below it, so the new thumbnail shows right away */
    fun insertMedia(e: Ed, id: String, alt: String = "image"): Ed {
        val s = e.text
        val ls = lineStart(s, e.min)
        val ins = (if (s.substring(ls, e.min).isBlank()) "" else "\n") + "![$alt](jot-media:$id)\n"
        return Ed(s.substring(0, e.min) + ins + s.substring(e.max), e.min + ins.length)
    }

    // ---- hidden symbols ----

    /** fence blocks: (whole block, opening line incl. newline, closing ``` range) */
    data class Fence(val block: IntRange, val first: IntRange, val close: IntRange)
    fun fences(s: String): List<Fence> = FENCE.findAll(s).map { m ->
        val closeAt = s.lastIndexOf("```", m.range.last)
        val firstEnd = s.indexOf('\n', m.range.first)
        Fence(m.range.first until closeAt + 3, m.range.first..firstEnd, closeAt until closeAt + 3)
    }.toList()

    /** which characters are formatting symbols that are not shown (true = hidden); `shown` = links shown whole */
    fun hidden(s: String, shown: List<IntRange> = emptyList()): BooleanArray {
        val h = BooleanArray(s.length)
        fun hide(a: Int, b: Int) { for (i in a.coerceAtLeast(0) until b.coerceAtMost(s.length)) h[i] = true }
        val media = mediaLines(s)
        for (m in HEADING.findAll(s)) hide(m.range.first, m.groups[2]!!.range.first.let { if (m.groupValues[2].isEmpty()) m.range.last + 1 else it })
        for (m in CHECK.findAll(s)) { val r = m.groups[2]!!.range; hide(r.first, r.last + 1) }
        for (m in QUOTE.findAll(s)) hide(m.range.first, m.range.first + 1)
        for (m in RULE.findAll(s)) hide(m.range.first, m.range.last + 1)
        fun marks(r: IntRange, open: Int, close: Int) {                  // ("_" in a media id is not italic)
            if (media.any { it.first <= r.last && r.first <= it.last }) return
            hide(r.first, r.first + open); hide(r.last + 1 - close, r.last + 1)
        }
        for (m in BOLD.findAll(s)) marks(m.range, 2, 2)
        for (m in ITALIC.findAll(s)) marks(m.range, 1, 1)
        for (m in UNDERLINE.findAll(s)) marks(m.range, 3, 4)
        for (m in STRIKE.findAll(s)) marks(m.range, 2, 2)
        for (m in CODE.findAll(s)) marks(m.range, 1, 1)
        for (m in mdLinks(s)) if (m.range !in shown) { val t = m.groups[1]!!.range; hide(m.range.first, t.first); hide(t.last + 1, m.range.last + 1) }
        // the thumbnail stands in for a media line; its last character stays (drawn transparent) to carry the line
        for (r in media) if (r !in shown) hide(mediaStart(s, r), r.last)
        for (f in fences(s)) {                            // code shows as typed; only the ``` lines are hidden
            for (i in f.block) if (i < s.length) h[i] = false
            hide(f.first.first, f.first.last)             // keeps the opening line's newline
            hide(lineStart(s, f.close.first), f.close.last + 1)
        }
        return h
    }

    /** display text (hidden symbols removed) with offsets both ways; a display offset maps to just before its
     *  visible character, i.e. after any hidden run, so the caret never stops inside symbols */
    class Shown(val text: String, val hidden: BooleanArray = hidden(text)) {
        private val before = IntArray(text.length + 1)     // visible chars before i
        private val at: IntArray                             // text index of the d-th visible char
        val display: String
        init {
            val sb = StringBuilder(); val idx = ArrayList<Int>(text.length)
            for (i in text.indices) { before[i] = sb.length; if (!hidden[i]) { sb.append(text[i]); idx.add(i) } }
            before[text.length] = sb.length
            display = sb.toString(); at = idx.toIntArray()
        }
        fun toDisplay(o: Int) = before[o.coerceIn(0, text.length)]
        fun toText(d: Int) = if (d >= at.size) text.length else at[d.coerceAtLeast(0)]
        fun range(r: IntRange): IntRange? { val a = toDisplay(r.first); val b = toDisplay(r.last + 1); return if (b > a) a until b else null }
    }

    /** the hidden ``` line around p (start until end, without newline) if p is on one; second = opening line */
    fun fenceLineAt(s: String, p: Int): Pair<IntRange, Boolean>? {
        for (f in fences(s)) {
            if (p in f.first.first..f.first.last) return (f.first.first until f.first.last) to true
            val cls = lineStart(s, f.close.first)
            if (p in cls..f.close.last + 1) return (cls..f.close.last) to false
        }
        return null
    }

    /** where a tap may leave the caret: not on a hidden ``` line (→ into the code), not in front of a line's
     *  marker (→ after "# ", "- ", "1. ", "> ", "- [ ] ") */
    fun safeCaret(s: String, p: Int): Int {
        fenceLineAt(s, p)?.let { (r, opening) -> return if (opening) minOf(s.length, r.last + 2) else maxOf(0, r.first - 1) }
        val ls = lineStart(s, p)
        if (p == ls) {
            val line = s.substring(ls, lineEnd(s, ls))
            listItem(line)?.let { if (it.indent.isEmpty()) return ls + it.length }
            HEADING_PREFIX.find(line)?.let { return ls + it.range.last + 1 }
        }
        return p
    }

    // ---- deleting ----

    /** Backspace (forward = false) / Delete with the caret at old.start, acting only on what is visible */
    fun smartDelete(old: Ed, forward: Boolean): Ed {
        val s = old.text
        if (!old.collapsed) return cleanEmptyMarks(Ed(s.removeRange(old.min, old.max), old.min))
        val c = old.start
        val h = hidden(s, shownAt(s, old.min, old.max))
        // a media line (showing its thumbnail) goes as a whole: Backspace at the start of the line below it,
        // Delete at the end of the line above it
        for (r in mediaLines(s)) {
            if (!forward && c == r.last + 2 && s[r.last + 1] == '\n') return Ed(s.removeRange(r.first, r.last + 2), r.first)
            if (forward && c == r.first - 1 && c >= 0) return Ed(s.removeRange(c, r.last + 1), c)
        }
        if (!forward) {
            // a. start of a code block's first line: remove the block (empty) or just its ``` lines
            for (f in fences(s)) if (c == f.first.last + 1) {
                var inner = s.substring(f.first.last + 1, f.close.first).removeSuffix("\n")
                if (inner.isBlank()) inner = ""
                return Ed(s.replaceRange(f.block.first, f.block.last + 1, inner), f.block.first)
            }
            // b. caret inside / right after a line's marker: drop the marker, keep the indent
            val ls = lineStart(s, c); val line = s.substring(ls, lineEnd(s, ls))
            var a = -1; var b = -1
            val it = listItem(line)
            if (it != null) { a = ls + it.indent.length; b = ls + it.length }
            else HEADING_PREFIX.find(line)?.let { a = ls; b = ls + it.range.last + 1 }
            if (a >= 0 && c > a && c <= b) return Ed(s.removeRange(a, b), a)
            // c. the nearest visible character to the left
            var i = c - 1
            while (i >= 0 && h[i]) i--
            if (i < 0) return old
            if (s[i] == '\n' && i > 0) fenceLineAt(s, i - 1)?.let { (r, opening) ->
                if (!opening && r.last + 1 == i) return Ed(s, maxOf(0, r.first - 1))     // right after a code block: go into it
            }
            var len = 1
            if (i > 0 && s[i].isLowSurrogate() && s[i - 1].isHighSurrogate()) { i--; len = 2 }
            return cleanEmptyMarks(Ed(s.removeRange(i, i + len), i))
        } else {
            var i = c
            while (i < s.length && h[i]) i++
            if (i >= s.length) return old
            if (s[i] == '\n') {
                val next = i + 1
                if (next < s.length && fenceLineAt(s, next)?.second == true) return old     // leave the code block alone
                if (next < s.length) {
                    val line = s.substring(next, lineEnd(s, next))
                    val cut = listItem(line)?.length ?: HEADING_PREFIX.find(line)?.let { it.range.last + 1 } ?: 0
                    if (cut > 0) return Ed(s.removeRange(i, next + cut), i)      // join the text without its marker
                }
            }
            var len = 1
            if (s[i].isHighSurrogate() && i + 1 < s.length && s[i + 1].isLowSurrogate()) len = 2
            return cleanEmptyMarks(Ed(s.removeRange(i, i + len), i))
        }
    }

    private val PAIRS = listOf("**" to "**", "__" to "__", "~~" to "~~", "<u>" to "</u>", "`" to "`", "*" to "*", "_" to "_")
    /** removes formatting marks left with nothing between them around the caret ("**|**" → "|"), repeatedly */
    fun cleanEmptyMarks(e: Ed): Ed {
        if (!e.collapsed) return e
        var s = e.text; var c = e.start
        loop@ while (true) {
            for ((o, cl) in PAIRS) {
                if (c >= o.length && s.startsWith(o, c - o.length) && s.startsWith(cl, c)) {
                    s = s.removeRange(c - o.length, c + cl.length); c -= o.length; continue@loop
                }
            }
            break
        }
        return Ed(s, c)
    }

    // ---- typing: Return continues a list ----

    /** Return on a list line starts the next item (or ends the list on an empty item); null = not a list line */
    fun continueList(old: Ed): Ed? {
        if (!old.collapsed) return null
        val s = old.text; val at = old.start
        val ls = lineStart(s, at)
        val it = listItem(s.substring(ls, at)) ?: return null
        if (it.length == at - ls) return Ed(s.removeRange(ls, at), ls)     // empty item: remove the marker
        var next = it.marker
        if (it.token != null) next = ListMarker.next(it.token, prevToken(s, ls, depth(it.indent))) + it.punct + " "
        next = next.replace("[x]", "[ ]").replace("[X]", "[ ]")
        val ins = "\n" + it.indent + next
        return Ed(s.substring(0, at) + ins + s.substring(at), at + ins.length)
    }

    /** Tab / outdent on a list line: nests it (numbers switch style: 1 2 3 → i ii iii, A B C → a b c) */
    fun indent(e: Ed, out: Boolean): Ed {
        val s = e.text
        val ls = lineStart(s, e.start); val le = lineEnd(s, ls)
        val it = listItem(s.substring(ls, le)) ?: return e
        var ind = it.indent
        if (out) {
            ind = when { ind.endsWith("    ") -> ind.dropLast(4); ind.endsWith("\t") -> ind.dropLast(1); ind.endsWith("  ") -> ind.dropLast(2); else -> return e }
        } else ind += "    "
        var marker = it.marker
        if (it.token != null) {
            val d = depth(it.indent); val nd = depth(ind)
            val kind = ListMarker.kind(it.token, prevToken(s, ls, d)) ?: ListMarker.Kind.NUMBER
            val sib = prevToken(s, ls, nd)
            marker = (if (sib != null) ListMarker.next(sib, null)
                      else ListMarker.token(1, if (out) (if (nd == 0) ListMarker.Kind.NUMBER else ListMarker.Kind.LOWER) else ListMarker.childKind(kind))) + it.punct + " "
        }
        val new = ind + marker
        val t = s.replaceRange(ls, ls + it.length, new)
        val delta = new.length - it.length
        return Ed(t, maxOf(ls + new.length, e.start + delta), maxOf(ls + new.length, e.end + delta))
    }

    // ---- format bar ----

    /** wraps the selection in open/close marks, or removes them if it is already wrapped */
    fun wrap(e: Ed, open: String, close: String): Ed {
        val s = e.text; val a = e.min; val b = e.max
        val inner = s.substring(a, b)
        if (inner.length >= open.length + close.length && inner.startsWith(open) && inner.endsWith(close)) {
            val plain = inner.substring(open.length, inner.length - close.length)
            return Ed(s.replaceRange(a, b, plain), a, a + plain.length)
        }
        if (a >= open.length && s.startsWith(open, a - open.length) && s.startsWith(close, b))
            return Ed(s.substring(0, a - open.length) + inner + s.substring(b + close.length), a - open.length, b - open.length)
        return Ed(s.substring(0, a) + open + inner + close + s.substring(b), a + open.length, b + open.length)
    }

    /** replaces the selected lines with f(lines); a lone caret keeps its distance from its line's end */
    private fun editLines(e: Ed, f: (List<String>) -> List<String>): Ed {
        val s = e.text
        val a = lineStart(s, e.min); val b = lineEnd(s, e.max)
        val lines = s.substring(a, b).split("\n")
        val out = f(lines).joinToString("\n")
        val t = s.substring(0, a) + out + s.substring(b)
        return if (e.collapsed && lines.size == 1) Ed(t, (a + out.length - (b - e.max)).coerceIn(a, a + out.length))
               else Ed(t, a, a + out.length)
    }

    /** "# " … "### " on the selected lines; choosing a line's current level removes it */
    fun heading(e: Ed, n: Int) = editLines(e) { lines ->
        lines.map { line ->
            val m = HEADING_PREFIX.find(line)
            val level = m?.groupValues?.get(1)?.length ?: 0
            val body = if (m != null) line.substring(m.range.last + 1) else line
            if (level == n) body else "#".repeat(n) + " " + body
        }
    }

    /** quote / ol / ul / task markers on the selected lines; if every line already has it, it is removed */
    fun lineMarker(e: Ed, kind: String) = editLines(e) { lines ->
        data class P(val indent: String, val marker: String, val body: String)
        val parsed = lines.map { line ->
            val it = listItem(line)
            if (it == null) { val ind = line.takeWhile { it == ' ' || it == '\t' }; P(ind, "", line.substring(ind.length)) }
            else P(it.indent, it.marker, line.substring(it.length))
        }
        fun isKind(m: String) = when (kind) {
            "quote" -> m == "> "
            "task" -> m.contains("[")
            "ul" -> !m.contains("[") && (m == "- " || m == "* " || m == "+ ")
            else -> m.firstOrNull()?.let { it.isLetterOrDigit() } ?: false
        }
        val content = parsed.filter { it.body.isNotEmpty() || it.marker.isNotEmpty() }
        val remove = content.isNotEmpty() && content.all { isKind(it.marker) }
        var n = 0
        parsed.map { p ->
            when {
                p.body.isEmpty() && p.marker.isEmpty() && parsed.size > 1 -> p.indent
                remove -> p.indent + p.body
                else -> { n++; p.indent + (when (kind) { "quote" -> "> "; "task" -> "- [ ] "; "ul" -> "- "; else -> "$n. " }) + p.body }
            }
        }
    }

    /** toggles a ``` block: inside one → its ``` lines are removed; otherwise the selected lines get wrapped */
    fun codeBlock(e: Ed): Ed {
        val s = e.text
        for (f in fences(s)) if (e.min >= f.block.first && e.max <= f.block.last + 1) {
            val inner = s.substring(f.first.last + 1, f.close.first).removeSuffix("\n")
            return Ed(s.replaceRange(f.block.first, f.block.last + 1, inner), f.block.first, f.block.first + inner.length)
        }
        val a = lineStart(s, e.min); val b = lineEnd(s, e.max)
        val text = s.substring(a, b)
        return if (text.isBlank()) Ed(s.replaceRange(a, b, "```\n\n```"), a + 4)
               else Ed(s.replaceRange(a, b, "```\n$text\n```"), a + 4, a + 4 + text.length)
    }

    /** Code with nothing selected: the caret's line (after any marker) becomes inline code, or stops being code */
    fun codeLine(e: Ed): Ed {
        if (!e.collapsed) return wrap(e, "`", "`")
        val s = e.text
        val ls = lineStart(s, e.start); val le = lineEnd(s, ls)
        val line = s.substring(ls, le)
        val start = listItem(line)?.length ?: HEADING_PREFIX.find(line)?.let { it.range.last + 1 } ?: 0
        val content = line.substring(start)
        val lead = content.takeWhile { it == ' ' || it == '\t' }.length
        val body = content.substring(lead)
        val a = ls + start + lead
        return if (body.length >= 2 && body.startsWith("`") && body.endsWith("`")) {
            val plain = body.substring(1, body.length - 1)
            Ed(s.replaceRange(a, a + body.length, plain), a + plain.length)
        } else Ed(s.replaceRange(a, a + body.length, "`$body`"), a + body.length + 1)
    }

    /** the fence language of the code block around p, and the range of its opening ``` line (no newline) */
    fun fenceAt(s: String, p: Int): Pair<String, IntRange>? {
        for (f in fences(s)) if (p >= f.block.first && p <= f.block.last + 1) {
            val line = f.first.first until f.first.last
            return s.substring(line).drop(3).trim().lowercase() to line
        }
        return null
    }
    fun setLanguage(e: Ed, lang: String): Ed {
        val (_, line) = fenceAt(e.text, e.start) ?: return e
        val new = "```$lang"
        val delta = new.length - (line.last + 1 - line.first)
        fun shift(p: Int) = if (p > line.first) p + delta else p
        return Ed(e.text.replaceRange(line.first, line.last + 1, new), shift(e.start), shift(e.end))
    }

    /** "- [ ]" ↔ "- [x]" on the line containing p; null if it is not a task line */
    fun toggleTask(s: String, p: Int): String? {
        val ls = lineStart(s, p); val le = lineEnd(s, ls)
        val m = CHECK.find(s.substring(ls, le)) ?: return null
        val box = m.groups[3]!!.range
        return s.replaceRange(ls + box.first, ls + box.last + 1, if (m.groupValues[3] == "[ ]") "[x]" else "[ ]")
    }
}

// ---- code highlighting output ----

/** highlight.js HTML → plain text + (range, class) spans; classes lose "hljs-"; outermost spans first */
object HLParse {
    data class Span(val range: IntRange, val cls: String, val depth: Int)
    private val ENT = mapOf("amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "#x27" to "'", "#39" to "'", "apos" to "'")

    fun parse(html: String): Pair<String, List<Span>> {
        val text = StringBuilder()
        val stack = ArrayList<Pair<Int, String>>()
        val spans = ArrayList<Span>()
        var i = 0
        while (i < html.length) {
            val c = html[i]
            if (c == '<') {
                val close = html.indexOf('>', i); if (close < 0) break
                val tag = html.substring(i + 1, close)
                if (tag.startsWith("/")) {
                    stack.removeLastOrNull()?.let { (start, cls) -> if (text.length > start) spans.add(Span(start until text.length, cls, stack.size)) }
                } else if (tag.startsWith("span")) {
                    val q = tag.indexOf("class=\"")
                    val cls = if (q < 0) "" else tag.substring(q + 7).substringBefore('"').split(' ')
                        .joinToString(" ") { it.removePrefix("hljs-") }
                    stack.add(text.length to cls)
                }
                i = close + 1
            } else if (c == '&') {
                val semi = html.indexOf(';', i)
                val ent = if (semi in i + 1..i + 8) ENT[html.substring(i + 1, semi)] else null
                if (ent != null) { text.append(ent); i = semi + 1 } else { text.append(c); i++ }
            } else { text.append(c); i++ }
        }
        return text.toString() to spans.sortedBy { it.depth }
    }
}
