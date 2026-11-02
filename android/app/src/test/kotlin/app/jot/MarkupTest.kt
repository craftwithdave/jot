package app.jot

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Live-preview editing rules (Markup.kt), mirroring the Mac editor; hl-fixtures.json comes from mac//test/hl. */
class MarkupTest {
    @Test fun listMarkers() {
        val cases = listOf(
            Triple("1", null, "2"), Triple("9", "8", "10"), Triple("A", null, "B"), Triple("a", null, "b"),
            Triple("i", null, "ii"), Triple("ii", "i", "iii"), Triple("iii", "ii", "iv"), Triple("iv", "iii", "v"),
            Triple("v", "iv", "vi"), Triple("h", "g", "i"), Triple("i", "h", "j"), Triple("c", "b", "d"),
            Triple("v", "u", "w"), Triple("I", null, "II"), Triple("H", "G", "I"), Triple("I", "H", "J"))
        for ((t, prev, want) in cases) assertEquals("next($t, $prev)", want, ListMarker.next(t, prev))
        assertEquals("i", ListMarker.token(1, ListMarker.childKind(ListMarker.Kind.NUMBER)))
        assertEquals("a", ListMarker.token(1, ListMarker.childKind(ListMarker.Kind.UPPER)))
        assertEquals("xiv", ListMarker.token(14, ListMarker.Kind.ROMAN))
    }

    @Test fun hiddenSymbolsAndOffsets() {
        val s = "# Title\nsome **bold** and `code`\n> quote\n- [ ] task\n---\n```py\nx = 1\n```"
        val sh = Markup.Shown(s)
        assertEquals("Title\nsome bold and code\n quote\n task\n\n\nx = 1\n", sh.display)
        // every display offset maps back and forth
        for (d in 0..sh.display.length) assertEquals("d=$d", d, sh.toDisplay(sh.toText(d)))
        // display 0 = after the hidden "# "
        assertEquals(2, sh.toText(0))
        // code inside a block keeps its symbols
        assertEquals("**a**", Markup.Shown("```\n**a**\n```").display.trim())
    }

    @Test fun markdownLinks() {
        // a Reading List line: checkbox + link, then an indented summary
        val s = "- [ ] [How agents plan](https://example.com/x) · blog · Oct 17\n  Summary text"
        val sh = Markup.Shown(s)
        assertEquals(" How agents plan · blog · Oct 17\n  Summary text", sh.display)
        for (d in 0..sh.display.length) assertEquals("d=$d", d, sh.toDisplay(sh.toText(d)))
        val link = Markup.mdLinks(s).single()
        assertEquals("https://example.com/x", link.groupValues[2])
        assertEquals(listOf(s.indexOf("\n") + 1), Markup.continuations(s))
        // the caret touches the link from just after "[" to just after ")"; then it shows whole
        val a = link.range.first; val b = link.range.last + 1
        assertEquals(emptyList<IntRange>(), Markup.touched(s, a, a))
        assertEquals(listOf(link.range), Markup.touched(s, a + 1, a + 1))
        assertEquals(listOf(link.range), Markup.touched(s, b, b))
        assertEquals(emptyList<IntRange>(), Markup.touched(s, b + 1, b + 1))
        assertEquals(listOf(link.range), Markup.touched(s, 0, s.length))
        assertEquals(" [How agents plan](https://example.com/x) · blog · Oct 17\n  Summary text", Markup.Shown(s, Markup.hidden(s, listOf(link.range))).display)
        // [[links]], checkboxes, bare urls and code are left alone
        assertEquals("[[Note]] and x", Markup.Shown("[[Note]] and [x](http://a.b)").display)
        assertEquals(0, Markup.mdLinks("[[a]](http://x.y) - [ ] (http://x.y) [a [b]](http://x.y)").size)
        assertEquals("[x](http://a.b)", Markup.Shown("`[x](http://a.b)`").display)
        assertEquals("[x](http://a.b)", Markup.Shown("```\n[x](http://a.b)\n```").display.trim())
        assertEquals("see https://a.b", Markup.Shown("see https://a.b").display)
        // Delete in front of a hidden "[" removes the first visible letter of the title (caret ends past "[", like after "**")
        assertEquals(Ed("x [b](http://x.y)", 3), Markup.smartDelete(Ed("x [ab](http://x.y)", 2), true))
        // Backspace right after it: the caret touches the link, so ")" is visible and goes
        assertEquals(Ed("[ab](http://x.y", 15), Markup.smartDelete(Ed("[ab](http://x.y)", 16), false))
        // plain indented lines that don't follow a list item stay as they are
        assertEquals(emptyList<Int>(), Markup.continuations("plain\n  not\n> q\n  no"))
        assertEquals(listOf(5, 9), Markup.continuations("1. a\n  b\n\tc\nd"))
    }

    @Test fun media() {
        // the Reading List agent's layout: task + link, indented summary, indented media line
        val id = "AbCdEf0123456789abcd_F"
        val med = "  ![video 0:42](jot-media:$id)"
        val s = "- [ ] [Title](https://x.com/a/status/1) · X · Oct 18\n  Summary text.\n$med\nafter"
        val ml = Markup.mediaLines(s).single()
        assertEquals(med, s.substring(ml.first, ml.last + 1))
        assertEquals(ml.first + 2, Markup.mediaStart(s, ml))
        // hidden like other symbols, except its indent and last character (kept, drawn transparent, so the tall line
        // always has a character); the "_" in the id is not italic
        val sh = Markup.Shown(s)
        assertEquals(" Title · X · Oct 18\n  Summary text.\n  )\nafter", sh.display)
        for (d in 0..sh.display.length) assertEquals("d=$d", d, sh.toDisplay(sh.toText(d)))
        // indented line under a list item: it is a continuation (lines up with the item text)
        assertEquals(listOf(s.indexOf("  Summary"), ml.first), Markup.continuations(s))
        // the line never shows its text, and the caret skips it (down → next line, up → line above)
        assertTrue(!Markup.Shown(s, Markup.hidden(s, Markup.shownAt(s, ml.first, ml.first))).display.contains(med))
        assertEquals(ml.last + 2, Markup.offMedia(s, ml.first, true))
        assertEquals(ml.last + 2, Markup.offMedia(s, ml.last + 1, true))
        assertEquals(ml.first - 1, Markup.offMedia(s, ml.last + 1, false))
        assertEquals(ml.last + 2, Markup.offMedia(s, ml.last + 2, false))
        // links still work on the item line; the media line is not a link
        assertEquals(1, Markup.mdLinks(s).size)
        // Backspace at the start of the next line removes the whole media line; Delete at the end of the line above too
        assertEquals(Ed(s.removeRange(ml.first, ml.last + 2), ml.first), Markup.smartDelete(Ed(s, ml.last + 2), false))
        assertEquals(Ed(s.removeRange(ml.first - 1, ml.last + 1), ml.first - 1), Markup.smartDelete(Ed(s, ml.first - 1), true))
        // with the caret on the line, it edits like text
        assertEquals(Ed(s.removeRange(ml.last, ml.last + 1), ml.last), Markup.smartDelete(Ed(s, ml.last + 1), false))
        // last line without a newline; inside a code block / inline it's not media
        assertEquals("a\n)", Markup.Shown("a\n![image](jot-media:$id)").display)
        val last = "a\n![image](jot-media:$id)\n"
        assertEquals(Ed("a\n", 2), Markup.smartDelete(Ed(last, last.length), false))
        assertEquals(0, Markup.mediaLines("```\n![image](jot-media:$id)\n```").size)
        assertEquals(0, Markup.mediaLines("see ![image](jot-media:$id)").size)
        // inserting: on its own line at the caret, caret on the line below
        assertEquals(Ed("![image](jot-media:$id)\n", 21 + id.length), Markup.insertMedia(Ed("", 0), id))
        assertEquals(Ed("ab\n![image](jot-media:$id)\ncd", 24 + id.length), Markup.insertMedia(Ed("abcd", 2), id))
        assertEquals(Ed("x\n  ![image](jot-media:$id)\n", 25 + id.length), Markup.insertMedia(Ed("x\n  ", 4), id))
        assertEquals(1, Markup.mediaLines(Markup.insertMedia(Ed("x\n  ", 4), id).text).size)
    }

    @Test fun caretNeverRestsOnHiddenFenceOrBeforeMarkers() {
        val s = "a\n```\ncode\n```\nb"
        assertEquals(6, Markup.safeCaret(s, 5))          // end of the opening ``` line → start of the code
        assertEquals(10, Markup.safeCaret(s, 14))        // end of the closing line → end of the code
        assertEquals(2, Markup.safeCaret("- item", 0))
        assertEquals(2, Markup.safeCaret("# H", 0))
    }

    @Test fun smartDelete() {
        // emptying bold removes its marks
        assertEquals(Ed("a ", 2), Markup.smartDelete(Ed("a **b**", 6), false))
        // Backspace right after hidden closing marks deletes the last visible letter
        assertEquals(Ed("**ab**", 4), Markup.smartDelete(Ed("**abc**", 7), false))
        // heading emptied: next Backspace drops "# "
        assertEquals(Ed("", 0), Markup.smartDelete(Ed("# ", 2), false))
        assertEquals(Ed("Title", 0), Markup.smartDelete(Ed("# Title", 2), false))
        // list marker goes in one press
        assertEquals(Ed("    x", 4), Markup.smartDelete(Ed("    - [ ] x", 10), false))
        // start of a code block: unwrap / remove
        assertEquals(Ed("code", 0), Markup.smartDelete(Ed("```\ncode\n```", 4), false))
        assertEquals(Ed("", 0), Markup.smartDelete(Ed("```\n\n```", 4), false))
        // right below a code block: go into it instead of joining onto ```
        assertEquals(Ed("```\nc\n```\nb", 5), Markup.smartDelete(Ed("```\nc\n```\nb", 10), false))
        // Delete at the end of a line above a heading joins its text without "#"
        assertEquals(Ed("aH", 1), Markup.smartDelete(Ed("a\n# H", 1), true))
        // Delete above a code block does nothing
        assertEquals(Ed("a\n```\nc\n```", 1), Markup.smartDelete(Ed("a\n```\nc\n```", 1), true))
        // emoji is one press
        assertEquals(Ed("a", 1), Markup.smartDelete(Ed("a😀", 3), false))
    }

    @Test fun lists() {
        assertEquals(Ed("1. a\n2. ", 8), Markup.continueList(Ed("1. a", 4)))
        assertEquals(Ed("A. a\nB. ", 8), Markup.continueList(Ed("A. a", 4)))
        assertEquals(Ed("- [x] a\n- [ ] ", 14), Markup.continueList(Ed("- [x] a", 7)))
        assertEquals(Ed("", 0), Markup.continueList(Ed("- ", 2)))
        // nesting switches the numbering style and back
        val nested = Markup.indent(Ed("1. a\n2. b", 9), false)
        assertEquals("1. a\n    i. b", nested.text)
        assertEquals("1. a\n2. b", Markup.indent(Ed(nested.text, nested.text.length), true).text)
        assertEquals("A. a\n    a. b", Markup.indent(Ed("A. a\nB. b", 9), false).text)
    }

    @Test fun formatToggles() {
        val b = Markup.wrap(Ed("hi", 0, 2), "**", "**")
        assertEquals(Ed("**hi**", 2, 4), b)
        assertEquals(Ed("hi", 0, 2), Markup.wrap(b, "**", "**"))
        assertEquals("## a", Markup.heading(Ed("a", 1), 2).text)
        assertEquals("a", Markup.heading(Ed("## a", 4), 2).text)
        assertEquals("1. a\n2. b", Markup.lineMarker(Ed("a\nb", 0, 3), "ol").text)
        assertEquals("- [ ] a", Markup.lineMarker(Ed("- a", 3), "task").text)
        assertEquals("a", Markup.lineMarker(Ed("> a", 3), "quote").text)
        val cb = Markup.codeBlock(Ed("x", 0))
        assertEquals("```\nx\n```", cb.text)
        assertEquals("x", Markup.codeBlock(Ed(cb.text, 5)).text)
        assertEquals("- `item`", Markup.codeLine(Ed("- item", 3)).text)
        assertEquals("- item", Markup.codeLine(Ed("- `item`", 3)).text)
        assertEquals("```python\nx\n```", Markup.setLanguage(Ed("```\nx\n```", 5), "python").text)
        assertEquals("- [x] a", Markup.toggleTask("- [ ] a", 0))
    }

    @Test fun hlParse() {
        val fx = JSONArray(javaClass.getResource("/hl-fixtures.json")!!.readText())
        for (i in 0 until fx.length()) {
            val o = fx.getJSONObject(i)
            val (text, spans) = HLParse.parse(o.getString("html"))
            assertEquals(o.getString("lang"), o.getString("code"), text)
            assertTrue(o.getString("lang"), spans.isNotEmpty() && spans.all { it.range.last < text.length })
        }
        val (t, s) = HLParse.parse("<span class=\"hljs-title function_\">a&amp;<span class=\"hljs-string\">&quot;b&#x27;</span></span>c")
        assertEquals("a&\"b'c", t)
        assertEquals(listOf("title function_", "string"), s.map { it.cls })
    }
}
