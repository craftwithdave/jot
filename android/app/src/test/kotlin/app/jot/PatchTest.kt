package app.jot

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.File

/** Fixtures made by mkpatch.py (insertion, deletion, sparse edits, new tail): the phone must rebuild them exactly. */
class PatchTest {
    private fun res(name: String) = File(javaClass.getResource("/$name")!!.toURI())

    @Test fun rebuildsNewFileFromOldPlusPatch() {
        val out = ByteArrayOutputStream()
        Patch.apply(res("patch-old.bin"), res("patch-test.patch"), out)
        assertArrayEquals(res("patch-new.bin").readBytes(), out.toByteArray())
    }
    @Test fun rejectsGarbage() {
        val f = File.createTempFile("bad", ".patch").apply { writeBytes(ByteArray(64) { 7 }); deleteOnExit() }
        assertThrows(Exception::class.java) { Patch.apply(res("patch-old.bin"), f, ByteArrayOutputStream()) }
    }
    @Test fun rejectsTruncatedPatch() {
        val p = res("patch-test.patch").readBytes()
        val f = File.createTempFile("cut", ".patch").apply { writeBytes(p.copyOf(p.size - 500)); deleteOnExit() }
        assertThrows(Exception::class.java) { Patch.apply(res("patch-old.bin"), f, ByteArrayOutputStream()) }
    }
}
