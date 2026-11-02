// Notes end-to-end encryption: reference implementation (Node). Same scheme as Drop
// with its own label, so keys from one app can never open the other one's data.
//
//   passphrase --PBKDF2-SHA256(salt, iter, 64 bytes)--> kek = [0,32)  auth = [32,64)
//   data key DK (32 random bytes) is stored on the server only as  wrap = AES-GCM(kek, DK, aad "notes-dk-v1")
//   note:           blob = base64( AES-GCM(DK, utf8(JSON), aad = note id) )
// The server only receives `auth` (and stores its SHA-256), never the passphrase, kek or DK.
const subtle = globalThis.crypto.subtle;
const enc = new TextEncoder(), dec = new TextDecoder();

export const b64 = (u8) => { let s = ""; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000)); return btoa(s); };
export const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
export const randomBytes = (n) => globalThis.crypto.getRandomValues(new Uint8Array(n));
export const newId = () => b64(randomBytes(16)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

export async function fromPassphrase(pass, saltB64, iter) {
  const base = await subtle.importKey("raw", enc.encode(pass.normalize("NFKC")), "PBKDF2", false, ["deriveBits"]);
  const bits = new Uint8Array(await subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: unb64(saltB64), iterations: iter }, base, 512));
  return { kek: bits.slice(0, 32), auth: b64(bits.slice(32)) };
}

const raw = (bytes, usages) => subtle.importKey("raw", bytes, "AES-GCM", false, usages);
async function sealRaw(key, plain, aad) {
  const iv = randomBytes(12);
  const ct = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv, additionalData: enc.encode(aad) }, key, plain));
  const out = new Uint8Array(12 + ct.length); out.set(iv); out.set(ct, 12);
  return out;
}
async function openRaw(key, all, aad) {
  return new Uint8Array(await subtle.decrypt({ name: "AES-GCM", iv: all.subarray(0, 12), additionalData: enc.encode(aad) }, key, all.subarray(12)));
}

// a fresh data key: the raw bytes are only needed once, to wrap them
export async function newDataKey(kek) {
  const dk = randomBytes(32);
  const wrap = b64(await sealRaw(await raw(kek, ["encrypt"]), dk, "notes-dk-v1"));
  return { wrap, key: await raw(dk, ["encrypt", "decrypt"]) };
}
// unwrap into a NON-extractable CryptoKey that can be kept in IndexedDB on this device
export async function unwrapDataKey(kek, wrap) {
  const dk = await openRaw(await raw(kek, ["decrypt"]), unb64(wrap), "notes-dk-v1");
  return raw(dk, ["encrypt", "decrypt"]);
}

export const sealNote = async (key, id, obj) => b64(await sealRaw(key, enc.encode(JSON.stringify(obj)), id));
export const openNote = async (key, id, blob) => JSON.parse(dec.decode(await openRaw(key, unb64(blob), id)));

// media (images / videos in notes): raw bytes, not base64. sealed = iv12 || AES-GCM(DK, bytes, aad "jot-media:<id>:<part>")
// with part "full" (the file) or "thumb" (a small JPEG preview). Referenced from a note as ![alt](jot-media:<id>).
export const mediaAad = (id, part) => `jot-media:${id}:${part}`;
export const sealMedia = (key, id, part, bytes) => sealRaw(key, bytes, mediaAad(id, part));
export const openMedia = (key, id, part, sealed) => openRaw(key, sealed, mediaAad(id, part));
