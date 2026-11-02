// Writes fixtures.json (logic) and vectors.json (crypto) from the reference code. Run: node spec/fixtures.mjs
// The Swift (NotesCore) and Kotlin (Logic/Crypto) tests must reproduce every value in them.
import * as C from "./crypto.mjs";
import * as L from "./logic.mjs";
import fs from "fs";

const notes = [
  { id: "n1aaaaaaaaaaaaaaaaaaaa", created: 1, updated: 10, body: "# Car maintenance\nOil change every 10,000 km. See [[Bengkel Pak Budi]] and [[Budget 2026|budget]].\n#car #todo" },
  { id: "n2aaaaaaaaaaaaaaaaaaaa", created: 2, updated: 20, body: "Bengkel Pak Budi\nGood mechanic near the office. Cheap oil change, honest about brake pads.\n#car" },
  { id: "n3aaaaaaaaaaaaaaaaaaaa", created: 3, updated: 30, body: "Budget 2026\n- rent\n- car maintenance\n- wedding savings\nLinks: [[Wedding#venue]] [[Nonexistent note]]" },
  { id: "n4aaaaaaaaaaaaaaaaaaaa", created: 4, updated: 40, body: "  ## Wedding  \nVenue booked. Catering: café Rosé. Music playlist TBD.\nPhotographer recommended by Pak Budi.\n#wedding #todo/urgent" },
  { id: "n5aaaaaaaaaaaaaaaaaaaa", created: 5, updated: 50, body: "Café ideas\nCafé Rosé has great croissants. Kopi susu at the office café.\nEmail: a#b and C#sharp and #123 are not tags." },
  { id: "n6aaaaaaaaaaaaaaaaaaaa", created: 6, updated: 60, body: "Meridian bot notes\nSolana DLMM pools, stop loss -10, trailing stop. Check the bengkel invoice too." },
  { id: "n7aaaaaaaaaaaaaaaaaaaa", created: 7, updated: 70, body: "\n\n" },
  { id: "n8aaaaaaaaaaaaaaaaaaaa", created: 8, updated: 80, body: "wedding\nDuplicate title: links to [[wedding]] must resolve to the older note. Oil." },
];
const ix = new L.NotesIndex(notes);
const r6 = (x) => Math.round(x * 1e6) / 1e6;
const queries = ["oil", "oil change", "cafe", "CAFÉ ros", "pak budi", "wed", "the car", "b", "zzz", "", "maint car", "solana stop"];
const fx = {
  notes,
  perNote: notes.map((n) => ({ id: n.id, title: L.title(n.body), titleKey: L.titleKey(L.title(n.body)), links: L.links(n.body), tags: L.tags(n.body),
    backlinks: ix.backlinks(n.id), related: ix.related(n.id).map((r) => ({ id: r.id, score: r6(r.score) })), mentions: ix.mentions(n.id) })),
  tokens: ["Hello, World! It's café-time 2026", "Ünïcödé naïve façade — ok", "a b cc the yang dan kopi"].map((s) => ({ s, words: L.words(s), tokens: L.tokens(s) })),
  search: queries.map((q) => ({ q, results: ix.search(q).map((r) => ({ id: r.id, score: r6(r.score) })) })),
  edges: ix.edges(),
  autoEdges: ix.autoEdges().map((e) => ({ ...e, score: r6(e.score) })),
  rename: [["See [[Wedding]], [[wedding|the day]], [[ WEDDING #venue|v]] and [[Weddings]].", "wedding", "Wedding 2027"],
           ["[[Café ideas]] [[cafe IDEAS]]", "cafe ideas", "Coffee"], ["no links", "x", "y"]]
    .map(([body, oldKey, newTitle]) => ({ body, oldKey, newTitle, out: L.renameLinks(body, oldKey, newTitle) })),
  media: ["- [ ] [Post](https://x.com/a/status/1) · X\n  Summary\n  ![video 0:42](jot-media:AAAAAAAAAAAAAAAAAAAAAA)\n  ![image](jot-media:BBBBBBBBBBBBBBBBBBBBBB)",
          "inline ![image](jot-media:AAAAAAAAAAAAAAAAAAAAAA) is not media", "![](jot-media:short)", "![photo](jot-media:CCCCCCCCCCCCCCCCCCCCCC)  "]
    .map((body) => ({ body, media: L.media(body) })),
  // note content JSON: apps must read pinned/cat and write them back unchanged (cat "reading" = Reading List & Ideas)
  content: [{ json: '{"body":"AI agents\\n- idea","created":1,"updated":2,"cat":"reading","dev":"agent"}', pinned: false, cat: "reading" },
    { json: '{"body":"x","created":1,"updated":2,"pinned":true}', pinned: true, cat: null },
    { json: '{"body":"y","created":1,"updated":2,"pinned":true,"cat":"reading"}', pinned: true, cat: "reading" }],
  resolve: [["WEDDING", ix.resolve("WEDDING")], ["bengkel  pak budi", ix.resolve("bengkel  pak budi")], ["nope", ix.resolve("nope")]],
};
fs.writeFileSync(new URL("fixtures.json", import.meta.url), JSON.stringify(fx, null, 1) + "\n");

// crypto vectors (fixed test vectors)
const subtle = globalThis.crypto.subtle;
const hex = (u8) => Buffer.from(u8).toString("hex");
const pass = "correct horse battery", salt = C.b64(new Uint8Array(16).map((_, i) => i + 1)), iter = 1000;
const d = await C.fromPassphrase(pass, salt, iter);
const dk = new Uint8Array(32).map((_, i) => 200 - i);
const kek = await subtle.importKey("raw", d.kek, "AES-GCM", false, ["encrypt"]);
const iv = new Uint8Array(12).fill(7);
const ct = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv, additionalData: new TextEncoder().encode("notes-dk-v1") }, kek, dk));
const wrap = C.b64(new Uint8Array([...iv, ...ct]));
const key = await C.unwrapDataKey(d.kek, wrap);
const id = "AAAAAAAAAAAAAAAAAAAAAA";
const noteObj = { body: "Héllo 👋\n[[link]] #tag", created: 1760000000000, updated: 1760000001000, dev: "mac" };
fs.writeFileSync(new URL("vectors.json", import.meta.url), JSON.stringify({
  pass, salt, iter, kek: hex(d.kek), auth: d.auth, dk: hex(dk), wrap, id, blob: await C.sealNote(key, id, noteObj), noteJson: JSON.stringify(noteObj),
  // media: open mediaSealed with (id, "thumb") to get mediaPlain; random iv, so devices check by opening, not re-sealing
  mediaPlain: hex(new Uint8Array(300).map((_, i) => (i * 7) & 255)), mediaSealed: C.b64(await C.sealMedia(key, id, "thumb", new Uint8Array(300).map((_, i) => (i * 7) & 255))),
}, null, 2) + "\n");
console.log("ok");
