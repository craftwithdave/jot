// End-to-end test of server.js with two reference clients. Run: node test/server.test.mjs
// Starts its own server on a random port with a throwaway data dir.
import { spawn } from "child_process";
import fs from "fs"; import os from "os"; import path from "path"; import assert from "assert/strict";
import { Client } from "../../spec/client.mjs";
import * as C from "../../spec/crypto.mjs";

const dir = fs.mkdtempSync(path.join(os.tmpdir(), "notes-test-"));
const port = 20000 + Math.floor(Math.random() * 20000), base = `http://127.0.0.1:${port}`;
const srv = spawn(process.execPath, [new URL("../server.js", import.meta.url).pathname], { env: { ...process.env, DATA_DIR: dir, PORT: port }, stdio: "inherit" });
await new Promise((r) => setTimeout(r, 400));
const step = (s) => console.log("✓", s);
try {
  const A = new Client(base, "mac"), B = new Client(base, "phone");
  A.iter = B.iter = 100000;
  await A.unlock("hunter2 hunter2"); step("account created");
  await assert.rejects(B.unlock("wrong pass"), /wrong passphrase/); step("wrong passphrase refused");
  await B.unlock("hunter2 hunter2"); step("second device unlocked");

  A.edit("note-aaaaaaaaaaaaaaaaaa", "Secret shopping list\nbanana PLAINTEXT_MARKER", 1000);
  await A.sync(); await B.sync();
  assert.equal(B.live()[0].body, "Secret shopping list\nbanana PLAINTEXT_MARKER"); step("note reaches the other device");

  // SSE event on change
  const ac = new AbortController();
  const got = new Promise(async (ok) => {
    const r = await fetch(base + "/api/events", { headers: { Authorization: "Bearer " + B.auth }, signal: ac.signal });
    const rd = r.body.getReader(); let n = 0;
    for (;;) { const { value } = await rd.read(); n += (new TextDecoder().decode(value).match(/data:/g) || []).length; if (n >= 2) return ok(); }
  });
  await new Promise((r) => setTimeout(r, 100));
  A.edit("note-aaaaaaaaaaaaaaaaaa", "Secret shopping list\nbanana, milk", 2000); await A.sync();
  await got; ac.abort(); step("live event sent");
  await B.sync(); assert.equal(B.live()[0].body, "Secret shopping list\nbanana, milk"); step("edit synced");

  // media: sealed upload, write-once, list, read back, delete
  {
    const mid = "media-aaaaaaaaaaaaaaaaa", plain = new Uint8Array(200000).map((_, i) => i & 255);
    const sealed = await C.sealMedia(A.key, mid, "full", plain);
    const put = (part, body) => fetch(`${base}/api/media/${mid}?part=${part}`, { method: "PUT", headers: { Authorization: "Bearer " + A.auth }, body });
    assert.equal((await put("full", sealed)).status, 200);
    assert.equal((await put("full", sealed)).status, 409); step("media upload is write-once");
    const list = await B.call("GET", "/api/media"); assert.equal(list.j.media[0].id, mid); assert.equal(list.j.media[0].size, sealed.length);
    const got = new Uint8Array(await (await fetch(`${base}/api/media/${mid}?part=full`, { headers: { Authorization: "Bearer " + B.auth } })).arrayBuffer());
    assert.deepEqual(await C.openMedia(B.key, mid, "full", got), plain);
    await assert.rejects(C.openMedia(B.key, mid, "thumb", got)); step("media read back on the other device (bound to id + part)");
    assert.equal((await fetch(`${base}/api/media/${mid}?part=full`)).status, 401);
    assert.equal((await B.call("DELETE", `/api/media/${mid}`)).status, 200);
    assert.equal((await fetch(`${base}/api/media/${mid}?part=full`, { headers: { Authorization: "Bearer " + B.auth } })).status, 404); step("media delete");
  }

  // offline double edit -> conflict copy, nothing lost
  A.edit("note-aaaaaaaaaaaaaaaaaa", "Secret shopping list\nfrom mac", 3000);
  B.edit("note-aaaaaaaaaaaaaaaaaa", "Secret shopping list\nfrom phone (later)", 4000);
  await A.sync(); await B.sync(); await A.sync();
  const bodies = (c) => c.live().map((n) => n.body).sort();
  assert.deepEqual(bodies(A), bodies(B));
  assert.deepEqual(bodies(A), ["Secret shopping list (conflict)\nfrom mac", "Secret shopping list\nfrom phone (later)"].sort()); step("conflict keeps both versions");

  // delete vs edit: edit wins
  const copy = A.live().find((n) => n.body.includes("(conflict)")).id;
  A.remove(copy); B.edit(copy, "kept by phone", 5000);
  await A.sync(); await B.sync(); await A.sync();
  assert.ok(A.live().some((n) => n.body === "kept by phone")); assert.deepEqual(bodies(A), bodies(B)); step("edit beats delete");
  // plain delete propagates
  B.remove(copy); await B.sync(); await A.sync();
  assert.equal(A.live().length, 1); assert.deepEqual(bodies(A), bodies(B)); step("delete propagates");

  // new device starts from zero and gets everything; restart keeps data
  srv.kill(); await new Promise((r) => setTimeout(r, 200));
  const srv2 = spawn(process.execPath, [new URL("../server.js", import.meta.url).pathname], { env: { ...process.env, DATA_DIR: dir, PORT: port }, stdio: "inherit" });
  await new Promise((r) => setTimeout(r, 400));
  try {
    const D = new Client(base, "new"); await D.unlock("hunter2 hunter2"); await D.sync();
    assert.deepEqual(bodies(D), bodies(A)); step("data survives a restart; fresh device gets all notes");
    // stale baseRev refused
    const r = await D.call("PUT", "/api/notes/note-aaaaaaaaaaaaaaaaaa", { baseRev: 1, blob: "A".repeat(40) });
    assert.equal(r.status, 409); assert.ok(r.j.note.rev > 1); step("stale write gets 409 + current copy");
    const bad = await D.call("PUT", "/api/notes/x", { baseRev: 0, blob: "A".repeat(40) }); assert.equal(bad.status, 404);
    const big = await D.call("PUT", "/api/notes/note-bbbbbbbbbbbbbbbbbb", { baseRev: 0, blob: "A".repeat(1024 * 1024 + 10) }); assert.ok(big.status >= 400); step("bad ids / oversize refused");
    const noauth = await fetch(base + "/api/changes"); assert.equal(noauth.status, 401); step("no auth -> 401");
    // no plaintext on disk
    const all = fs.readdirSync(path.join(dir, "notes")).map((f) => fs.readFileSync(path.join(dir, "notes", f), "utf8")).join("") + fs.readFileSync(path.join(dir, "keys.json"), "utf8");
    for (const s of ["Secret", "banana", "PLAINTEXT_MARKER", "phone", "hunter2"]) assert.ok(!all.includes(s), "plaintext on disk: " + s);
    step("no plaintext on disk");
    // brute force lock
    for (let i = 0; i < 31; i++) await fetch(base + "/api/keys", { headers: { Authorization: "Bearer " + "x".repeat(44) } });
    assert.equal((await D.call("GET", "/api/keys")).status, 429); step("brute-force lock after 30 wrong tries");
  } finally { srv2.kill(); }
  console.log("all passed");
} finally { srv.kill(); fs.rmSync(dir, { recursive: true, force: true }); }
