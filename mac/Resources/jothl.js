// Jot code-block highlighting, run by the Mac app in JavaScriptCore after highlight.min.js (no network).
// jotHighlight(code, lang) -> JSON {value: html, language}; lang = the fence's language or "" to detect.
// Strong-signal checks first fix highlight.js's known mix-ups (C vs C++, Java vs TypeScript, GraphQL / R vs SCSS).
var JOT_SUBSET = "bash c cpp csharp css diff go graphql ini java javascript json kotlin less lua makefile markdown objectivec perl php python r ruby rust scss shell sql swift typescript xml yaml".split(" ");
var JOT_ALIASES = { sh: "bash", zsh: "bash", js: "javascript", ts: "typescript", py: "python", rb: "ruby", rs: "rust",
  kt: "kotlin", yml: "yaml", html: "xml", objc: "objectivec", "c++": "cpp", cs: "csharp", "c#": "csharp", md: "markdown",
  make: "makefile", golang: "go", console: "shell", gql: "graphql", toml: "ini" };
function jotGuess(code) {
  if (/^\s*(query|mutation|subscription|fragment)\b[^{\n]*\{/m.test(code) || /^\s*(type|input|enum|interface|schema)\s+\w+[^{\n]*\{[^}]*\w+\s*:\s*\[?\w+!?/m.test(code) && !/;\s*$/m.test(code)) return "graphql";
  if (/\bimport\s+java\.|System\.(out|err)\.print|public\s+static\s+void\s+main\s*\(\s*String/.test(code)) return "java";
  if (/^\s*library\(\w+\)/m.test(code) || (/\w\s*<-\s*\S/.test(code) && /\b(c|data\.frame|function|mean|sum|paste|read\.csv)\(/.test(code))) return "r";
  return null;
}
function jotIsPlainC(code) {
  return !/::|\btemplate\s*<|\bclass\s+\w+|\bnamespace\b|\bstd::|\bcout\b|\bnew\s+\w|\bpublic:|\bprivate:|\bnullptr\b|\bauto\s+\w+\s*=|#include\s*<(iostream|vector|string|map|memory|algorithm)>/.test(code)
    && /#include\s*<\w+\.h>|\b(printf|malloc|free|scanf|sizeof)\b/.test(code);
}
function jotHighlight(code, lang) {
  lang = (lang || "").toLowerCase();
  lang = JOT_ALIASES[lang] || lang;
  var r;
  if (lang && hljs.getLanguage(lang)) r = hljs.highlight(code, { language: lang, ignoreIllegals: true });
  else {
    var g = jotGuess(code);
    if (g) r = hljs.highlight(code, { language: g, ignoreIllegals: true });
    else {
      r = hljs.highlightAuto(code, JOT_SUBSET);
      if (r.language === "cpp" && jotIsPlainC(code)) r = hljs.highlight(code, { language: "c", ignoreIllegals: true });
    }
  }
  return JSON.stringify({ value: r.value, language: r.language || "" });
}
