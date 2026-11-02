package app.jot

import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.util.zip.InflaterInputStream

/**
 * Rebuilds the new APK from the installed one plus a small patch made by mkpatch.py (bsdiff, zlib-packed).
 * The caller still checks the result against the full APK's SHA-256, so a bad patch can't install anything.
 */
object Patch {
    fun apply(old: File, patch: File, out: OutputStream, progress: (Long, Long) -> Unit = { _, _ -> }) {
        val head = DataInputStream(FileInputStream(patch))
        val newSize: Long; val count: Long; val lens = LongArray(3)
        head.use {
            val magic = ByteArray(8); it.readFully(magic)
            if (String(magic, Charsets.US_ASCII) != "TLPATCH1") throw Exception("Not an update patch")
            newSize = it.readLong(); count = it.readLong()
            for (i in 0..2) { lens[i] = it.readLong(); if (i < 2) skipFully(it, lens[i]) }
        }
        if (newSize !in 0..(1L shl 31) || count < 0 || lens.any { it < 0 }) throw Exception("Damaged patch")
        // the three zlib sections follow the 24-byte header, each after its 8-byte length
        fun section(i: Int): InputStream {
            var off = 24L + 8
            for (j in 0 until i) off += lens[j] + 8
            val f = FileInputStream(patch); skipFully(f, off)
            return InflaterInputStream(BufferedInputStream(f, 64 * 1024))   // default Inflater: freed on close
        }
        val ctrl = DataInputStream(section(0)); val diff = section(1); val extra = section(2)
        RandomAccessFile(old, "r").use { src ->
            val oldSize = src.length()
            val buf = ByteArray(64 * 1024); val ob = ByteArray(64 * 1024)
            var oldPos = 0L; var written = 0L
            try {
                for (c in 0 until count) {
                    val x = ctrl.readLong(); val y = ctrl.readLong(); val z = ctrl.readLong()
                    if (x < 0 || y < 0 || written + x + y > newSize) throw Exception("Damaged patch")
                    var left = x
                    while (left > 0) {                       // diff bytes + old bytes
                        val n = minOf(left, buf.size.toLong()).toInt()
                        readFully(diff, buf, n)
                        val lo = oldPos.coerceIn(0, oldSize); val hi = (oldPos + n).coerceIn(0, oldSize)
                        if (hi > lo) { src.seek(lo); src.readFully(ob, 0, (hi - lo).toInt()) }
                        for (k in 0 until n) {
                            val p = oldPos + k
                            if (p in lo until hi) buf[k] = (buf[k] + ob[(p - lo).toInt()]).toByte()
                        }
                        out.write(buf, 0, n); oldPos += n; left -= n; written += n
                    }
                    left = y
                    while (left > 0) {                       // new bytes copied as-is
                        val n = minOf(left, buf.size.toLong()).toInt()
                        readFully(extra, buf, n)
                        out.write(buf, 0, n); left -= n; written += n
                    }
                    oldPos += z
                    progress(written, newSize)
                }
            } finally { ctrl.close(); diff.close(); extra.close() }
            if (written != newSize) throw Exception("Damaged patch")
        }
    }

    private fun skipFully(inp: InputStream, n: Long) {   // InputStream.skipNBytes needs a newer Android
        var left = n
        while (left > 0) { val s = inp.skip(left); if (s <= 0) { if (inp.read() < 0) throw EOFException("Damaged patch"); left-- } else left -= s }
    }

    private fun readFully(inp: InputStream, b: ByteArray, n: Int) {
        var off = 0
        while (off < n) { val r = inp.read(b, off, n - off); if (r < 0) throw EOFException("Damaged patch"); off += r }
    }
}
