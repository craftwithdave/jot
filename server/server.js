// Notes sync server: stores end-to-end encrypted notes for the Mac and Android Notes apps. Plain Node, no dependencies.
//
// Run it behind an HTTPS reverse proxy and keep it private (VPN / IP allow-list); see server/compose.yml.
// The server never sees plaintext: every note is sealed on the device with the data key (AES-256-GCM),
// and the data key is stored here only wrapped with a key derived from the passphrase (same scheme as Drop).
//
//   GET    /api/salt                 public KDF params {salt, iter} (404 until set up)
//   POST   /api/init                 first-time setup {salt, iter, auth, wrap}
//   GET    /api/keys                 (auth) wrapped data key
//   GET    /api/changes?since=<seq>  (auth) {seq, notes: [{id, rev, seq, t, del, blob}]} changed after <seq>
//   PUT    /api/notes/:id            (auth) {baseRev, blob} or {baseRev, del: true}; 409 {note} when baseRev is stale
//   GET    /api/events               (auth) Server-Sent Events: {seq} whenever something changed
//   PUT    /api/media/:id?part=full|thumb  (auth) raw sealed bytes (crypto.mjs sealMedia); write-once, 409 if it exists
//   GET    /api/media/:id?part=full|thumb  (auth) the sealed bytes
//   DELETE /api/media/:id                  (auth) both parts
//   GET    /api/media                (auth) {media: [{id, size, t}]} (for clean-up of media no note links any more)
//
// Media (images / videos in notes, `![alt](jot-media:<id>)`) are sealed on the device like notes; the server only
// stores the bytes in data/media/<id>.<part>.
// rev counts edits of one note (0 = never existed); seq is a global counter so devices pull only what's new.
// Deleted notes stay as tombstones (no blob) so every device learns about the delete.
"use strict";
const http = require("http");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const DATA = process.env.DATA_DIR || path.join(__dirname, "data");
const PUB = path.join(__dirname, "public");
const NOTES = path.join(DATA, "notes");
const KEYS = path.join(DATA, "keys.json");
const PORT = +process.env.PORT || 8080;
const HOST = process.env.HOST || "127.0.0.1";
const MAX_NOTE = 1024 * 1024;                            // ciphertext per note (base64)
const MAX_NOTES = 50000;
const MAX_JSON = MAX_NOTE + 4096;
const MEDIA = path.join(DATA, "media");
const MAX_PART = { full: 100 * 1024 * 1024, thumb: 2 * 1024 * 1024 };
const MAX_MEDIA_TOTAL = 20 * 1024 ** 3;

fs.mkdirSync(NOTES, { recursive: true });
fs.mkdirSync(MEDIA, { recursive: true });
for (const f of fs.readdirSync(MEDIA)) if (f.endsWith(".tmp")) fs.rmSync(path.join(MEDIA, f), { force: true });
const mediaBytes = () => fs.readdirSync(MEDIA).reduce((n, f) => n + (fs.statSync(path.join(MEDIA, f), { throwIfNoEntry: false })?.size || 0), 0);
let mediaTotal = mediaBytes();

// stream a sealed upload to disk (never held in memory: the container has 128 MB)
function putMedia(req, res, id, part) {
  const f = path.join(MEDIA, `${id}.${part}`), tmp = f + "." + crypto.randomBytes(4).toString("hex") + ".tmp";
  if (fs.existsSync(f)) { req.resume(); return send(res, 409, { error: "exists" }); }
  const len = +req.headers["content-length"] || 0;
  if (len > MAX_PART[part]) { req.resume(); return send(res, 413, { error: "too big" }); }
  if (mediaTotal + len > MAX_MEDIA_TOTAL) { req.resume(); return send(res, 507, { error: "media storage full" }); }
  const out = fs.createWriteStream(tmp, { flags: "wx" });
  let n = 0, failed = false;
  const fail = (code, error) => { if (failed) return; failed = true; out.destroy(); fs.rmSync(tmp, { force: true }); if (!res.headersSent) send(res, code, { error }); };
  req.on("data", (c) => { n += c.length; if (n > MAX_PART[part]) { fail(413, "too big"); req.destroy(); } });
  req.on("error", () => fail(400, "upload broken"));
  out.on("error", () => fail(500, "disk"));
  out.on("finish", () => {
    if (failed) return;
    if (n < 29) return fail(400, "bad media");            // iv + tag at least
    fs.renameSync(tmp, f); mediaTotal += n;
    send(res, 200, { ok: true, size: n });
  });
  req.pipe(out);
}

// ---- keys ----
const readKeys = () => { try { return JSON.parse(fs.readFileSync(KEYS, "utf8")); } catch { return null; } };
function writeKeys(k) { fs.writeFileSync(KEYS + ".tmp", JSON.stringify(k)); fs.renameSync(KEYS + ".tmp", KEYS); }
const sha = (b64) => crypto.createHash("sha256").update(Buffer.from(b64, "base64")).digest("hex");

// ---- notes: data/notes/<id>.json = {id, rev, seq, t, del, blob} ----
const ID = /^[A-Za-z0-9_-]{16,64}$/;
const B64 = /^[A-Za-z0-9+/=]*$/;
const notes = new Map();
let seq = 0;
for (const f of fs.readdirSync(NOTES)) {
  if (!f.endsWith(".json")) { fs.rmSync(path.join(NOTES, f), { force: true }); continue; }
  try { const n = JSON.parse(fs.readFileSync(path.join(NOTES, f), "utf8")); if (f === n.id + ".json") { notes.set(n.id, n); seq = Math.max(seq, n.seq); } }
  catch { console.error("broken note file", f); }
}
function saveNote(n) { const f = path.join(NOTES, n.id + ".json"); fs.writeFileSync(f + ".tmp", JSON.stringify(n)); fs.renameSync(f + ".tmp", f); }

// ---- live events ----
const clients = new Set();
function broadcast(ev) { const line = `data: ${JSON.stringify(ev)}\n\n`; for (const res of clients) res.write(line); }
setInterval(() => { for (const res of clients) res.write(": ping\n\n"); }, 25000).unref();

// ---- http ----
const CSP = "default-src 'none'; frame-ancestors 'none'; base-uri 'none'";
const HDR = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Content-Security-Policy": CSP };
function send(res, code, body, type = "application/json") {
  res.writeHead(code, { ...HDR, "Content-Type": type });
  res.end(typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body));
}
function json(req) {
  return new Promise((ok, fail) => {
    let n = 0; const parts = [];
    req.on("data", (c) => { n += c.length; if (n > MAX_JSON) { fail(new Error("too big")); req.destroy(); } else parts.push(c); });
    req.on("end", () => { try { ok(JSON.parse(Buffer.concat(parts).toString("utf8") || "{}")); } catch (e) { fail(e); } });
    req.on("error", fail);
  });
}
// slow down passphrase guessing: 30 failed logins per 10 minutes in total (everyone arrives via tailnet)
let fails = [];
function authed(req) {
  const k = readKeys();
  const m = /^Bearer ([A-Za-z0-9+/=]{40,100})$/.exec(req.headers.authorization || "");
  if (!k || !m) return false;
  const ok = crypto.timingSafeEqual(Buffer.from(sha(m[1]), "hex"), Buffer.from(k.authHash, "hex"));
  if (!ok) fails.push(Date.now());
  return ok;
}
function locked() { const t = Date.now() - 10 * 60 * 1000; fails = fails.filter((x) => x > t); return fails.length >= 30; }
const b64ok = (s, min, max) => typeof s === "string" && s.length >= min && s.length <= max && B64.test(s);

const TYPES = { ".json": "application/json", ".png": "image/png", ".sh": "text/plain; charset=utf-8", ".swift": "text/plain; charset=utf-8",
  ".txt": "text/plain; charset=utf-8", ".plist": "text/plain; charset=utf-8", ".apk": "application/vnd.android.package-archive", ".patch": "application/octet-stream" };
function serveFile(req, res, rel) {
  const p = path.normalize(path.join(PUB, rel));
  if (!p.startsWith(PUB + path.sep)) return send(res, 404, { error: "not found" });
  // phones far behind get the gzipped APK (about a third of the size)
  const gz = rel.endsWith(".apk") && /\bgzip\b/.test(req.headers["accept-encoding"] || "") && fs.existsSync(p + ".gz");
  fs.stat(gz ? p + ".gz" : p, (e, st) => {
    if (e || !st.isFile()) return send(res, 404, { error: "not found" });
    res.writeHead(200, { ...HDR, "Cache-Control": "no-cache", "Content-Type": TYPES[path.extname(p)] || "application/octet-stream",
      "Content-Length": st.size, ...(gz ? { "Content-Encoding": "gzip" } : {}) });
    if (req.method === "HEAD") return res.end();
    fs.createReadStream(gz ? p + ".gz" : p).pipe(res);
  });
}

http.createServer(async (req, res) => {
  const u = new URL(req.url, "http://x"), p = u.pathname;
  try {
    if (p === "/api/salt" && req.method === "GET") {
      const k = readKeys();
      return k ? send(res, 200, { salt: k.salt, iter: k.iter, v: k.v }) : send(res, 404, { error: "not set up" });
    }
    if (p === "/api/init" && req.method === "POST") {
      if (readKeys()) return send(res, 409, { error: "already set up" });
      const b = await json(req);
      if (!b64ok(b.salt, 16, 64) || !Number.isInteger(b.iter) || b.iter < 100000 || !b64ok(b.auth, 40, 100) || !b64ok(b.wrap, 40, 200))
        return send(res, 400, { error: "bad setup" });
      writeKeys({ v: 1, salt: b.salt, iter: b.iter, authHash: sha(b.auth), wrap: b.wrap });
      return send(res, 200, { ok: true });
    }
    if (p.startsWith("/api/")) {
      if (locked()) return send(res, 429, { error: "too many wrong passphrases, wait 10 minutes" });
      if (!authed(req)) return send(res, 401, { error: "wrong passphrase" });
      if (p === "/api/keys" && req.method === "GET") return send(res, 200, { wrap: readKeys().wrap });
      if (p === "/api/events" && req.method === "GET") {
        res.writeHead(200, { ...HDR, "Content-Type": "text/event-stream", "X-Accel-Buffering": "no" });
        res.write(`data: ${JSON.stringify({ seq })}\n\n`);
        clients.add(res);
        req.on("close", () => clients.delete(res));
        return;
      }
      if (p === "/api/changes" && req.method === "GET") {
        const since = Math.max(0, parseInt(u.searchParams.get("since") || "0", 10) || 0);
        const out = [...notes.values()].filter((n) => n.seq > since).sort((a, b) => a.seq - b.seq);
        return send(res, 200, { seq, notes: out });
      }
      if (p === "/api/media" && req.method === "GET") {
        const by = new Map();
        for (const f of fs.readdirSync(MEDIA)) {
          const mm = /^([A-Za-z0-9_-]{16,64})\.(full|thumb)$/.exec(f);
          if (!mm) continue;
          const st = fs.statSync(path.join(MEDIA, f), { throwIfNoEntry: false });
          if (!st) continue;
          const e = by.get(mm[1]) || { id: mm[1], size: 0, t: 0 };
          e.size += st.size; e.t = Math.max(e.t, st.mtimeMs | 0); by.set(mm[1], e);
        }
        return send(res, 200, { media: [...by.values()] });
      }
      const mm = /^\/api\/media\/([A-Za-z0-9_-]{16,64})$/.exec(p);
      if (mm) {
        const part = u.searchParams.get("part") || "full";
        if (!(part in MAX_PART)) return send(res, 400, { error: "bad part" });
        if (req.method === "PUT") return putMedia(req, res, mm[1], part);
        if (req.method === "DELETE") {
          for (const x of Object.keys(MAX_PART)) {
            const f = path.join(MEDIA, `${mm[1]}.${x}`), st = fs.statSync(f, { throwIfNoEntry: false });
            if (st) { fs.rmSync(f, { force: true }); mediaTotal -= st.size; }
          }
          return send(res, 200, { ok: true });
        }
        if (req.method === "GET") {
          const f = path.join(MEDIA, `${mm[1]}.${part}`), st = fs.statSync(f, { throwIfNoEntry: false });
          if (!st) return send(res, 404, { error: "not found" });
          // write-once, so devices may keep (still sealed) copies
          res.writeHead(200, { ...HDR, "Cache-Control": "private, max-age=31536000, immutable", "Content-Type": "application/octet-stream", "Content-Length": st.size });
          return fs.createReadStream(f).pipe(res);
        }
        return send(res, 405, { error: "method" });
      }
      const m = /^\/api\/notes\/([A-Za-z0-9_-]{16,64})$/.exec(p);
      if (m && req.method === "PUT") {
        const b = await json(req), id = m[1], cur = notes.get(id);
        if (!Number.isInteger(b.baseRev) || b.baseRev < 0) return send(res, 400, { error: "bad baseRev" });
        if (b.del !== true && !b64ok(b.blob, 28, MAX_NOTE)) return send(res, 400, { error: "bad note" });
        if ((cur ? cur.rev : 0) !== b.baseRev) return send(res, 409, { error: "changed on another device", note: cur || null });
        if (!cur && notes.size >= MAX_NOTES) return send(res, 507, { error: "too many notes" });
        const n = { id, rev: b.baseRev + 1, seq: ++seq, t: Date.now(), del: b.del === true, ...(b.del === true ? {} : { blob: b.blob }) };
        notes.set(id, n); saveNote(n);
        broadcast({ seq });
        return send(res, 200, { ok: true, rev: n.rev, seq: n.seq });
      }
      return send(res, 404, { error: "not found" });
    }
    if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, { error: "method" });
    if (p === "/") return send(res, 200, "Notes sync server. Use the Notes app on your Mac or phone.\n", "text/plain; charset=utf-8");
    return serveFile(req, res, decodeURIComponent(p.slice(1)));
  } catch (e) {
    if (!res.headersSent) send(res, 400, { error: "bad request" });
  }
}).listen(PORT, HOST, () => console.log(`notes-sync on ${HOST}:${PORT}, ${notes.size} notes, seq ${seq}`));
