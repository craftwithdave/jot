// Notes sync engine: reference implementation (Node). NotesCore.swift (Mac) and Sync.kt (Android) follow the same steps.
//
// Local record: {id, rev, dirty, del, content}  (content = {body, created, updated, pinned?, cat?, dev} or null when deleted)
//   rev   = server revision this local copy is based on (0 = never uploaded)
//   dirty = changed here and not uploaded yet
//
// sync():
//   1. pull  GET /api/changes?since=lastSeq; every note that isn't dirty here takes the server version.
//            Dirty ones are left alone (step 2 sorts them out). lastSeq = response seq.
//   2. push  PUT each dirty note with baseRev = rev. 200 -> rev = new rev, clean. 409 -> resolve with the server copy:
//            both deleted            -> take server rev, clean
//            server deleted, ours edited -> ours wins (re-upload on top of the tombstone)
//            ours deleted, server edited -> server wins (an edit beats a delete; nothing is lost)
//            both edited, same body  -> take server rev, clean
//            both edited             -> the later `updated` keeps the id; the other becomes a NEW note whose title
//                                       line ends in " (conflict)". Nothing is ever thrown away.
import * as C from "./crypto.mjs";

export function conflictCopy(body) {
  const lines = body.split("\n");
  const i = lines.findIndex((l) => l.trim());
  if (i < 0) return "(conflict)\n" + body;
  lines[i] = lines[i].replace(/\s+$/, "") + " (conflict)";
  return lines.join("\n");
}

export class Client {
  constructor(base, dev) { this.base = base; this.dev = dev; this.store = new Map(); this.lastSeq = 0; }
  async call(method, path, body) {
    const r = await fetch(this.base + path, { method, headers: { "Content-Type": "application/json", ...(this.auth ? { Authorization: "Bearer " + this.auth } : {}) },
      body: body ? JSON.stringify(body) : undefined });
    const j = await r.json().catch(() => ({}));
    return { status: r.status, j };
  }
  // first device: make the account; later devices: unlock
  async unlock(pass) {
    let s = await this.call("GET", "/api/salt");
    if (s.status === 404) {
      const salt = C.b64(C.randomBytes(16)), iter = this.iter || 600000;
      const d = await C.fromPassphrase(pass, salt, iter);
      const { wrap, key } = await C.newDataKey(d.kek);
      const r = await this.call("POST", "/api/init", { salt, iter, auth: d.auth, wrap });
      if (r.status !== 200) throw new Error("init " + r.status);
      this.auth = d.auth; this.key = key; return;
    }
    const d = await C.fromPassphrase(pass, s.j.salt, s.j.iter);
    this.auth = d.auth;
    const k = await this.call("GET", "/api/keys");
    if (k.status !== 200) { this.auth = null; throw new Error(k.j.error || "unlock " + k.status); }
    this.key = await C.unwrapDataKey(d.kek, k.j.wrap);
  }

  edit(id, body, now = Date.now()) {
    const cur = this.store.get(id);
    this.store.set(id, { id, rev: cur ? cur.rev : 0, dirty: true, del: false,
      content: { body, created: cur?.content?.created ?? now, updated: now, dev: this.dev } });
  }
  remove(id) { const cur = this.store.get(id); if (cur) this.store.set(id, { ...cur, dirty: true, del: true, content: null }); }
  live() { return [...this.store.values()].filter((r) => !r.del).map((r) => ({ id: r.id, ...r.content })); }

  async sync() {
    const ch = await this.call("GET", "/api/changes?since=" + this.lastSeq);
    if (ch.status !== 200) throw new Error("changes " + ch.status);
    for (const n of ch.j.notes) {
      const local = this.store.get(n.id);
      if (local && local.dirty) continue;
      this.store.set(n.id, { id: n.id, rev: n.rev, dirty: false, del: n.del, content: n.del ? null : await C.openNote(this.key, n.id, n.blob) });
    }
    this.lastSeq = ch.j.seq;
    for (let round = 0; round < 5; round++) {
      const dirty = [...this.store.values()].filter((r) => r.dirty);
      if (!dirty.length) return;
      for (const r of dirty) await this.push(r);
    }
  }
  async push(r) {
    const body = r.del ? { baseRev: r.rev, del: true } : { baseRev: r.rev, blob: await C.sealNote(this.key, r.id, r.content) };
    const res = await this.call("PUT", "/api/notes/" + r.id, body);
    if (res.status === 200) {
      const now = this.store.get(r.id);
      if (now === r) this.store.set(r.id, { ...r, rev: res.j.rev, dirty: false });
      else this.store.set(r.id, { ...now, rev: res.j.rev });     // edited again while uploading: stays dirty
      return;
    }
    if (res.status !== 409) throw new Error("push " + res.status + " " + JSON.stringify(res.j));
    const s = res.j.note;
    if (!s) { this.store.set(r.id, { ...r, rev: 0 }); return; }  // server lost it (reset): upload as new
    const theirs = s.del ? null : await C.openNote(this.key, s.id, s.blob);
    const take = () => this.store.set(r.id, { id: r.id, rev: s.rev, dirty: false, del: s.del, content: theirs });
    if (s.del && r.del) return take();
    if (s.del) return this.store.set(r.id, { ...r, rev: s.rev });
    if (r.del) return take();
    if (theirs.body === r.content.body) return take();
    const copyId = C.newId(), oursWins = r.content.updated > theirs.updated;
    const loser = oursWins ? theirs : r.content;
    if (oursWins) this.store.set(r.id, { ...r, rev: s.rev }); else take();
    this.store.set(copyId, { id: copyId, rev: 0, dirty: true, del: false, content: { ...loser, body: conflictCopy(loser.body) } });
  }
}
