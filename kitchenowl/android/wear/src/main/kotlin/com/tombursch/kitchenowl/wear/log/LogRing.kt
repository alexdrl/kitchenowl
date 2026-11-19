package com.tombursch.kitchenowl.wear.log

import java.io.File
import java.io.RandomAccessFile

/**
 * The watch's log buffer on disk: `log-<generation>.log` files of JSON lines, a new
 * generation once the current one passes [maxFileBytes], [keepFiles] kept (~200 KB in all).
 *
 * The watch has no network: the lines go to the phone over the Data Layer ([LogRelay]).
 * The relay cursor (`relay-cursor`) remembers what was already handed over, so each relay
 * carries only new lines. Pure JVM code, unit-tested.
 */
class LogRing(
    private val dir: File,
    private val maxFileBytes: Long = 100_000,
    private val keepFiles: Int = 2,
) {
    data class Position(val gen: Int, val offset: Long)

    /** New lines (complete, newline-terminated) and where the relay stands after them. */
    class Batch(val text: String, val lines: Int, val end: Position)

    private var gen: Int? = null
    private val cursorFile = File(dir, "relay-cursor")

    private fun fileFor(gen: Int) = File(dir, "log-$gen.log")

    /** Existing generations, oldest first. */
    fun generations(): List<Pair<Int, File>> =
        (dir.listFiles() ?: emptyArray())
            .mapNotNull { f -> NAME.matchEntire(f.name)?.let { it.groupValues[1].toInt() to f } }
            .sortedBy { it.first }

    val totalBytes: Long
        get() = generations().sumOf { it.second.length() }

    @Synchronized
    fun append(line: String) {
        if (!dir.exists()) dir.mkdirs()
        var current = gen ?: generations().lastOrNull()?.first ?: 0
        if (fileFor(current).length() >= maxFileBytes) {
            current++
            generations().filter { it.first <= current - keepFiles }.forEach { it.second.delete() }
        }
        gen = current
        fileFor(current).appendText(if (line.endsWith("\n")) line else "$line\n", Charsets.UTF_8)
    }

    /**
     * The lines after the relay cursor, at most [maxBytes] (always at least one line when there
     * is one, even if longer). Null when everything was relayed already.
     */
    @Synchronized
    fun takeNew(maxBytes: Int): Batch? {
        val gens = generations()
        if (gens.isEmpty()) return null
        var start = readCursor() ?: Position(gens.first().first, 0)
        if (gens.none { it.first == start.gen }) {
            // Its file was rotated away: from the oldest one left.
            start = Position(gens.firstOrNull { it.first > start.gen }?.first ?: gens.first().first, 0)
        }
        val out = StringBuilder()
        var size = 0
        var lines = 0
        var end = start
        for ((g, file) in gens) {
            if (g < start.gen) continue
            var offset = if (g == start.gen) start.offset else 0L
            val bytes = readFrom(file, offset) ?: run { offset = 0L; readFrom(file, 0L)!! }
            var lineStart = 0
            for (i in bytes.indices) {
                if (bytes[i] != '\n'.code.toByte()) continue
                val length = i + 1 - lineStart
                if (lines > 0 && size + length > maxBytes) return Batch(out.toString(), lines, end)
                out.append(String(bytes, lineStart, length, Charsets.UTF_8))
                size += length
                lines++
                lineStart = i + 1
                end = Position(g, offset + lineStart)
            }
        }
        return if (lines == 0) null else Batch(out.toString(), lines, end)
    }

    /** The batch was handed to the Data Layer. */
    @Synchronized
    fun commit(end: Position) {
        if (!dir.exists()) dir.mkdirs()
        cursorFile.writeText("${end.gen} ${end.offset}")
    }

    private fun readCursor(): Position? = try {
        val (g, o) = cursorFile.readText().trim().split(" ")
        Position(g.toInt(), o.toLong())
    } catch (e: Exception) {
        null
    }

    private fun readFrom(file: File, offset: Long): ByteArray? =
        RandomAccessFile(file, "r").use { raf ->
            val length = raf.length()
            if (offset > length) return null
            raf.seek(offset)
            ByteArray((length - offset).toInt()).also { raf.readFully(it) }
        }

    private companion object {
        val NAME = Regex("""log-(\d+)\.log""")
    }
}
