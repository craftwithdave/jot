package app.jot

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/** vectors.json comes from spec/fixtures.mjs (the reference crypto.mjs); build.sh copies it in. */
class CryptoTest {
    private val v = JSONObject(javaClass.getResource("/vectors.json")!!.readText())
    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    @Test fun matchesReference() {
        val d = Crypto.fromPassphrase(v.getString("pass"), v.getString("salt"), v.getInt("iter"))
        assertEquals(v.getString("kek"), hex(d.kek))
        assertEquals(v.getString("auth"), d.auth)
        val dk = Crypto.unwrapKey(d.kek, v.getString("wrap"))
        assertEquals(v.getString("dk"), hex(dk))
        val note = Crypto.openNote(dk, v.getString("id"), v.getString("blob"))
        assertEquals(NoteContent.from(JSONObject(v.getString("noteJson"))), note)
        assertEquals(note, Crypto.openNote(dk, "x", Crypto.sealNote(dk, "x", note)))
    }

    @Test fun media() {
        val d = Crypto.fromPassphrase(v.getString("pass"), v.getString("salt"), v.getInt("iter"))
        val dk = Crypto.unwrapKey(d.kek, v.getString("wrap"))
        val id = v.getString("id")
        val plain = Crypto.openMedia(dk, id, "thumb", Crypto.unb64(v.getString("mediaSealed")))
        assertEquals(v.getString("mediaPlain"), hex(plain))
        assertEquals(hex(plain), hex(Crypto.openMedia(dk, id, "full", Crypto.sealMedia(dk, id, "full", plain))))
        // the part is bound: a thumb can't be opened as the full file
        assertThrows(Exception::class.java) { Crypto.openMedia(dk, id, "full", Crypto.unb64(v.getString("mediaSealed"))) }
    }
}
