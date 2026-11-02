package app.jot

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.ui.graphics.Color
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject
import org.json.JSONTokener

/**
 * Code-block colouring, same as the Mac app: highlight.js (BSD-3) + jothl.js (assets, copied from mac//Resources by
 * build.sh) run in one hidden WebView that never loads anything from the network. Results arrive asynchronously:
 * get() returns the cached result or null and asks for it; [version] bumps when a result lands so the editor restyles.
 * Main thread only.
 */
object Highlighter {
    data class Result(val spans: List<HLParse.Span>, val language: String)
    val version = MutableStateFlow(0)

    private var web: WebView? = null
    private var ready = false
    private val queue = LinkedHashMap<String, Pair<String, String>>()       // key → (code, lang), waiting for the page
    private val asked = HashSet<String>()
    private val cache = object : LinkedHashMap<String, Result>(64, 0.75f, true) {
        override fun removeEldestEntry(e: MutableMap.MutableEntry<String, Result>) = size > 64
    }

    fun get(ctx: Context, code: String, lang: String): Result? {
        if (code.isEmpty() || code.length > 20_000) return null
        val key = lang + "\u0000" + code
        cache[key]?.let { return it }
        if (asked.add(key)) { if (ready) run(key, code, lang) else { queue[key] = code to lang; start(ctx) } }
        return null
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun start(ctx: Context) {
        if (web != null) return
        val app = ctx.applicationContext
        val js = runCatching { listOf("highlight.min.js", "jothl.js").joinToString("\n") { f -> app.assets.open(f).bufferedReader().readText() } }.getOrNull() ?: return
        web = WebView(app).apply {
            settings.javaScriptEnabled = true
            settings.blockNetworkLoads = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            webViewClient = object : WebViewClient() {
                override fun onPageFinished(v: WebView, url: String?) {
                    ready = true
                    queue.forEach { (k, p) -> run(k, p.first, p.second) }
                    queue.clear()
                }
            }
            // the scripts go in as page content; the page has no base URL and can't fetch anything
            loadDataWithBaseURL(null, "<!doctype html><script>" + js.replace("</script", "<\\/script") + "</script>", "text/html", "utf-8", null)
        }
    }

    private fun run(key: String, code: String, lang: String) {
        web?.evaluateJavascript("jotHighlight(${JSONObject.quote(code)}, ${JSONObject.quote(lang)})") { out ->
            val r = runCatching {
                val o = JSONObject(JSONTokener(out).nextValue() as String)
                val (text, spans) = HLParse.parse(o.getString("value"))
                Result(if (text == code) spans else emptyList(), o.optString("language"))
            }.getOrNull() ?: Result(emptyList(), "")
            Handler(Looper.getMainLooper()).post { cache[key] = r; asked.remove(key); version.value++ }
        }
    }
}

/** One Dark colours for highlight.js classes (same map as the Mac's CodeTheme) and language names */
object CodeTheme {
    private fun c(v: Long) = Color(0xFF000000 or v)
    val plain = c(0xabb2bf)
    val italic = setOf("comment", "quote", "doctag")
    private val colors = mapOf(
        "keyword" to c(0xc678dd), "doctag" to c(0xc678dd), "template-tag" to c(0xc678dd), "operator" to c(0x56b6c2),
        "string" to c(0x98c379), "regexp" to c(0x98c379), "meta string" to c(0x98c379), "char" to c(0x98c379), "addition" to c(0x98c379),
        "comment" to c(0x7f848e), "quote" to c(0x7f848e), "meta" to c(0x61afef), "meta keyword" to c(0xc678dd),
        "number" to c(0xd19a66), "literal" to c(0x56b6c2), "attr" to c(0xd19a66), "attribute" to c(0x98c379),
        "variable" to c(0xe06c75), "template-variable" to c(0xe06c75), "params" to c(0xabb2bf), "property" to c(0xe06c75),
        "title" to c(0x61afef), "title function_" to c(0x61afef), "title class_" to c(0xe5c07b), "section" to c(0xe06c75),
        "type" to c(0xe5c07b), "built_in" to c(0xe5c07b), "symbol" to c(0x61afef), "bullet" to c(0x61afef),
        "tag" to c(0xe06c75), "name" to c(0xe06c75), "selector-tag" to c(0xe06c75), "selector-class" to c(0xd19a66),
        "selector-id" to c(0x61afef), "selector-attr" to c(0xd19a66), "selector-pseudo" to c(0xd19a66), "subst" to c(0xe06c75),
        "punctuation" to c(0xabb2bf), "deletion" to c(0xe06c75), "link" to c(0x61afef), "code" to c(0x98c379),
    )
    fun color(cls: String): Color? = colors[cls] ?: colors[cls.substringBefore(' ')]
    val names = linkedMapOf(
        "bash" to "Bash", "c" to "C", "cpp" to "C++", "csharp" to "C#", "css" to "CSS", "diff" to "Diff", "go" to "Go",
        "graphql" to "GraphQL", "ini" to "INI", "java" to "Java", "javascript" to "JavaScript", "json" to "JSON", "kotlin" to "Kotlin",
        "less" to "Less", "lua" to "Lua", "makefile" to "Makefile", "markdown" to "Markdown", "objectivec" to "Objective-C",
        "perl" to "Perl", "php" to "PHP", "python" to "Python", "r" to "R", "ruby" to "Ruby", "rust" to "Rust", "scss" to "SCSS",
        "shell" to "Shell", "sql" to "SQL", "swift" to "Swift", "typescript" to "TypeScript", "xml" to "XML", "yaml" to "YAML",
    )
}
