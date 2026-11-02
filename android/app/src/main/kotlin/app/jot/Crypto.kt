package app.jot

import org.json.JSONObject
import java.security.SecureRandom
import java.text.Normalizer
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Jot's end-to-end encryption. Must match spec/crypto.mjs (vectors.json is checked by CryptoTest).
 *
 *   passphrase -PBKDF2-SHA256(salt, iter, 64 bytes)-> kek = [0,32), auth = base64([32,64))
 *   wrap = AES-GCM(kek, DK, aad "notes-dk-v1");  note blob = base64(AES-GCM(DK, utf8(json), aad = note id))
 */
object Crypto {
    const val WRAP = "notes-dk-v1"
    private val rnd = SecureRandom()

    class Derived(val kek: ByteArray, val auth: String)

    fun random(n: Int) = ByteArray(n).also { rnd.nextBytes(it) }
    fun b64(b: ByteArray): String = Base64.getEncoder().encodeToString(b)
    fun unb64(s: String): ByteArray = Base64.getDecoder().decode(s)
    fun newId(): String = Base64.getUrlEncoder().withoutPadding().encodeToString(random(16))

    fun fromPassphrase(pass: String, saltB64: String, iter: Int): Derived {
        val spec = PBEKeySpec(Normalizer.normalize(pass, Normalizer.Form.NFKC).toCharArray(), unb64(saltB64), iter, 512)
        val bits = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        spec.clearPassword()
        return Derived(bits.copyOfRange(0, 32), b64(bits.copyOfRange(32, 64)))
    }

    fun seal(key: ByteArray, plain: ByteArray, aad: String, iv: ByteArray = random(12)): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        c.updateAAD(aad.toByteArray())
        return iv + c.doFinal(plain)
    }

    fun open(key: ByteArray, all: ByteArray, aad: String): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, all, 0, 12))
        c.updateAAD(aad.toByteArray())
        return c.doFinal(all, 12, all.size - 12)
    }

    fun wrapKey(kek: ByteArray, dk: ByteArray) = b64(seal(kek, dk, WRAP))
    fun unwrapKey(kek: ByteArray, wrap: String) = open(kek, unb64(wrap), WRAP)
    fun sealNote(dk: ByteArray, id: String, c: NoteContent): String = b64(seal(dk, c.toJson().toString().toByteArray(), id))
    /** images / videos: raw sealed bytes, aad "jot-media:<id>:<part>" with part "full" or "thumb" */
    fun sealMedia(dk: ByteArray, id: String, part: String, bytes: ByteArray) = seal(dk, bytes, "jot-media:$id:$part")
    fun openMedia(dk: ByteArray, id: String, part: String, sealed: ByteArray) = open(dk, sealed, "jot-media:$id:$part")
    fun openNote(dk: ByteArray, id: String, blob: String) = NoteContent.from(JSONObject(String(open(dk, unb64(blob), id))))
}
