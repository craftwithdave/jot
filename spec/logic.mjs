// Notes logic: reference implementation. The Mac app (NotesCore.swift) and the Android app (Logic.kt) must give the
// same answers; spec/fixtures.mjs writes fixtures.json from this file and both apps' tests check against it.
//
// A note's decrypted content is {body, created, updated, pinned?, cat?, dev?}. Its title is its first non-empty line.
// cat: optional category; "reading" = Reading List & Ideas. Missing = normal note.
//
//   normalize   NFKD, drop combining marks, lowercase          ("Café" -> "cafe")
//   tokens      normalize, split on anything that is not a letter or digit, keep length >= 2, drop STOP words
//   title       first non-empty line, leading "#"s and spaces removed, trimmed, max 120 chars; "Untitled" if none
//   titleKey    normalize(title), whitespace runs -> one space, trimmed  (how [[links]] find notes)
//   links       [[Target]], [[Target|alias]], [[Target#heading]] -> titleKey(Target), unique, in order
//   tags        #word (must contain a letter; letters digits _ - / allowed), not preceded by a letter/digit/_/&/#
//   resolve     titleKey -> note id; same title twice -> the oldest note (created, then id)
//
//   search      every query token is a PREFIX of some term in the note (AND). Query tokens: normalized, split;
//               all but the last must be length >= 2 and not STOP; the last may be 1 char. Score = sum over query
//               tokens of the best BM25 score among the note's terms that start with it (k1 1.2, b 0.75,
//               idf = ln(1 + (N - df + .5) / (df + .5))). Term frequency: title tokens count 3, body tokens 1.
//               Order: score desc, updated desc, id asc.
//   related     cosine similarity of TF-IDF vectors (w = (1 + ln tf) * ln(N / df), same tf as search), leaving out
//               the note itself and notes linked either way; score >= 0.08; top 5; order score desc, id asc.
//   mentions    notes that contain the note's title as consecutive words (raw words: normalize + split, no
//               filtering) but don't link to it. Only for titles whose words have >= 3 letters in total.
//   renameLinks rewrite [[Old]], [[old|alias]], [[Old#h]] (matched by titleKey) to the new title, keeping alias/heading
//   edges       [from, to] for every resolved link between two different notes, unique, from-note order.
//   autoEdges   edges nobody typed, drawn faint in the graph and walked by the Ideas bot: {a, b, kind, score} with a < b
//               (plain string order), one per pair, pairs joined by a link left out. kind "mention" (either note mentions
//               the other, score 0) wins over "related" (the pair is in either note's related list, score = its cosine).
//               Order: a asc, b asc.
export const STOP = new Set(("a an and are as at be but by for from has have i if in into is it its me my no not of on or our so " +
  "that the their them then there these they this to was we were what when which who will with you your " +
  "ada adalah akan aku dan dari di dengan ini itu ke kita mereka pada saya tidak untuk yang").split(" "));
const K1 = 1.2, B = 0.75, TITLE_TF = 3, RELATED_MIN = 0.08, RELATED_MAX = 5;

export const normalize = (s) => s.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();
export const words = (s) => normalize(s).split(/[^\p{L}\p{N}]+/u).filter((w) => w.length > 0);
export const tokens = (s) => words(s).filter((w) => w.length >= 2 && !STOP.has(w));

export function title(body) {
  for (const line of body.split("\n")) {
    const t = line.replace(/^\s*#+\s*/, "").trim();
    if (t) return [...t].slice(0, 120).join("");
  }
  return "Untitled";
}
export const titleKey = (t) => normalize(t).replace(/\s+/g, " ").trim();

export function links(body) {
  const out = [];
  for (const m of body.matchAll(/\[\[([^\[\]\n]+?)\]\]/g)) {
    const k = titleKey(m[1].split("|")[0].split("#")[0]);
    if (k && !out.includes(k)) out.push(k);
  }
  return out;
}
export function renameLinks(body, oldKey, newTitle) {
  return body.replace(/\[\[([^\[\]\n]+?)\]\]/g, (m, inner) => {
    const bar = inner.indexOf("|"), target = bar >= 0 ? inner.slice(0, bar) : inner;
    const hash = target.indexOf("#"), name = hash >= 0 ? target.slice(0, hash) : target;
    if (titleKey(name) !== oldKey) return m;
    return "[[" + newTitle + (hash >= 0 ? target.slice(hash) : "") + (bar >= 0 ? inner.slice(bar) : "") + "]]";
  });
}
export function tags(body) {
  const out = [];
  for (const m of body.matchAll(/(^|[^\p{L}\p{N}_&#])#([\p{L}\p{N}_\/-]*\p{L}[\p{L}\p{N}_\/-]*)/gu)) {
    const t = normalize(m[2]);
    if (!out.includes(t)) out.push(t);
  }
  return out;
}

export class NotesIndex {
  // notes: [{id, body, created, updated}] (deleted notes left out)
  constructor(notes) {
    this.notes = new Map();
    this.byKey = new Map();
    this.df = new Map();
    let total = 0;
    const sorted = [...notes].sort((a, b) => a.created - b.created || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    for (const n of sorted) {
      const t = title(n.body), tf = new Map();
      for (const w of tokens(t)) tf.set(w, (tf.get(w) || 0) + TITLE_TF);
      for (const w of tokens(n.body)) tf.set(w, (tf.get(w) || 0) + 1);
      let len = 0; for (const v of tf.values()) len += v;
      total += len;
      for (const w of tf.keys()) this.df.set(w, (this.df.get(w) || 0) + 1);
      const key = titleKey(t);
      if (!this.byKey.has(key)) this.byKey.set(key, n.id);
      this.notes.set(n.id, { ...n, title: t, key, tf, len, links: links(n.body), tags: tags(n.body), words: words(n.body) });
    }
    this.N = this.notes.size;
    this.avg = this.N ? total / this.N : 1;
    this.terms = [...this.df.keys()].sort();
    // resolved outgoing links and incoming backlinks
    this.out = new Map(); this.back = new Map();
    for (const n of this.notes.values()) {
      const to = [];
      for (const k of n.links) { const id = this.byKey.get(k); if (id && id !== n.id && !to.includes(id)) to.push(id); }
      this.out.set(n.id, to);
      for (const id of to) { if (!this.back.has(id)) this.back.set(id, []); this.back.get(id).push(n.id); }
    }
  }
  resolve(key) { return this.byKey.get(titleKey(key)) || null; }
  backlinks(id) { return [...(this.back.get(id) || [])].sort(); }
  edges() { const e = []; for (const [from, to] of this.out) for (const t of to) e.push([from, t]); return e; }

  // all index terms starting with p (binary search in the sorted term list)
  prefixed(p) {
    let lo = 0, hi = this.terms.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (this.terms[mid] < p) lo = mid + 1; else hi = mid; }
    const out = [];
    for (let i = lo; i < this.terms.length && this.terms[i].startsWith(p); i++) out.push(this.terms[i]);
    return out;
  }
  search(query, limit = 50) {
    const q = words(query);
    const qt = q.filter((w, i) => i === q.length - 1 ? true : w.length >= 2 && !STOP.has(w));
    if (!qt.length) return [];
    const termSets = qt.map((w) => this.prefixed(w));
    if (termSets.some((s) => !s.length)) return [];
    const res = [];
    for (const n of this.notes.values()) {
      let score = 0, ok = true;
      for (const set of termSets) {
        let best = -1;
        for (const t of set) {
          const tf = n.tf.get(t);
          if (!tf) continue;
          const df = this.df.get(t), idf = Math.log(1 + (this.N - df + 0.5) / (df + 0.5));
          const s = idf * tf * (K1 + 1) / (tf + K1 * (1 - B + B * n.len / this.avg));
          if (s > best) best = s;
        }
        if (best < 0) { ok = false; break; }
        score += best;
      }
      if (ok) res.push({ id: n.id, score, updated: n.updated });
    }
    res.sort((a, b) => b.score - a.score || b.updated - a.updated || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    return res.slice(0, limit).map(({ id, score }) => ({ id, score }));
  }

  vector(n) {
    if (n.vec) return n.vec;
    const v = new Map(); let norm = 0;
    for (const [t, tf] of n.tf) { const w = (1 + Math.log(tf)) * Math.log(this.N / this.df.get(t)); if (w > 0) { v.set(t, w); norm += w * w; } }
    return (n.vec = { v, norm: Math.sqrt(norm) });
  }
  related(id) {
    const me = this.notes.get(id);
    if (!me || this.N < 2) return [];
    const a = this.vector(me);
    if (!a.norm) return [];
    const linked = new Set([...(this.out.get(id) || []), ...(this.back.get(id) || [])]);
    const res = [];
    for (const n of this.notes.values()) {
      if (n.id === id || linked.has(n.id)) continue;
      const b = this.vector(n);
      if (!b.norm) continue;
      let dot = 0;
      for (const [t, w] of a.v) { const x = b.v.get(t); if (x) dot += w * x; }
      const score = dot / (a.norm * b.norm);
      if (score >= RELATED_MIN) res.push({ id: n.id, score });
    }
    res.sort((x, y) => y.score - x.score || (x.id < y.id ? -1 : x.id > y.id ? 1 : 0));
    return res.slice(0, RELATED_MAX);
  }
  autoEdges() {
    const pair = (x, y) => (x < y ? x + " " + y : y + " " + x);
    const linked = new Set(this.edges().map(([x, y]) => pair(x, y))), res = new Map();
    const add = (x, y, kind, score) => {
      const k = pair(x, y);
      if (!linked.has(k) && !res.has(k)) res.set(k, { a: x < y ? x : y, b: x < y ? y : x, kind, score });
    };
    for (const id of this.notes.keys()) for (const m of this.mentions(id)) add(id, m, "mention", 0);
    for (const id of this.notes.keys()) for (const r of this.related(id)) add(id, r.id, "related", r.score);
    return [...res.values()].sort((x, y) => (x.a < y.a ? -1 : x.a > y.a ? 1 : x.b < y.b ? -1 : x.b > y.b ? 1 : 0));
  }
  mentions(id) {
    const me = this.notes.get(id);
    if (!me) return [];
    const tw = words(me.title);
    if (tw.join("").length < 3) return [];
    const res = [];
    for (const n of this.notes.values()) {
      if (n.id === id || (this.out.get(n.id) || []).includes(id)) continue;
      const w = n.words;
      outer: for (let i = 0; i + tw.length <= w.length; i++) {
        for (let j = 0; j < tw.length; j++) if (w[i + j] !== tw[j]) continue outer;
        res.push(n.id); break;
      }
    }
    return res.sort();
  }
}

// media in a note: ![alt](jot-media:<id>) on a line of its own (leading spaces allowed). alt is "image", "video",
// or "video 0:42" (duration shown on the thumbnail). Apps draw the thumbnail there; tapping opens it full size.
export const MEDIA_RE = /^[ \t]*!\[([^\]\n]*)\]\(jot-media:([A-Za-z0-9_-]{16,64})\)[ \t]*$/gm;
export function media(body) {
  return [...body.matchAll(MEDIA_RE)].map((m) => {
    const [kind, dur] = m[1].trim().split(/\s+/);
    return { id: m[2], kind: kind === "video" ? "video" : "image", duration: kind === "video" && dur ? dur : "" };
  });
}
