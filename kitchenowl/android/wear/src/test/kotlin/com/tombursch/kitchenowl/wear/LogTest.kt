package com.tombursch.kitchenowl.wear

import com.tombursch.kitchenowl.wear.log.LogPayload
import com.tombursch.kitchenowl.wear.log.LogRing
import com.tombursch.kitchenowl.wear.log.WearLog
import com.tombursch.kitchenowl.wear.log.decodeLogPayload
import com.tombursch.kitchenowl.wear.log.encodeLogPayload
import com.tombursch.kitchenowl.wear.log.logRequestId
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

class LogTest {
    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("wearlog").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun line(i: Int) = """{"t":$i,"l":"info","m":"m$i"}"""

    @Test
    fun relaysOnlyNewLinesAfterACommit() {
        val ring = LogRing(dir)
        ring.append(line(1))
        ring.append(line(2))
        val first = ring.takeNew(10_000)!!
        assertEquals(2, first.lines)
        assertEquals("${line(1)}\n${line(2)}\n", first.text)

        // Not committed (the Data Layer refused): the same lines again.
        assertEquals(first.text, ring.takeNew(10_000)!!.text)

        ring.commit(first.end)
        assertNull(ring.takeNew(10_000))
        ring.append(line(3))
        assertEquals("${line(3)}\n", ring.takeNew(10_000)!!.text)
    }

    @Test
    fun batchesStayUnderTheItemSize() {
        val ring = LogRing(dir)
        repeat(10) { ring.append(line(it)) } // ~30 bytes each
        val batch = ring.takeNew(100)!!
        assertTrue(batch.text.length <= 100)
        assertEquals(batch.text.lines().filter { it.isNotEmpty() }.size, batch.lines)
        ring.commit(batch.end)
        val rest = generateSequence { ring.takeNew(100)?.also { ring.commit(it.end) } }.sumOf { it.lines }
        assertEquals(10, batch.lines + rest)
    }

    @Test
    fun rotatesAndKeepsAboutTwoFiles() {
        val ring = LogRing(dir, maxFileBytes = 100, keepFiles = 2)
        repeat(30) { ring.append(line(it)) }
        val gens = ring.generations()
        assertEquals(2, gens.size)
        assertTrue(ring.totalBytes < 300)
        // A cursor never set: everything still there, oldest first, newest last.
        val all = generateSequence { ring.takeNew(1_000)?.also { ring.commit(it.end) } }.joinToString("") { it.text }
        assertTrue(all.trim().endsWith(line(29)))
    }

    @Test
    fun aRotatedAwayCursorRestartsAtTheOldestFile() {
        val ring = LogRing(dir, maxFileBytes = 40, keepFiles = 2)
        ring.append(line(1))
        ring.commit(ring.takeNew(1_000)!!.end)
        repeat(6) { ring.append(line(10 + it)) }
        val batch = ring.takeNew(1_000)!!
        assertTrue(batch.text.trim().endsWith(line(15)))
    }

    @Test
    fun linesUseThePhonesFormat() {
        val text = WearLog.encodeLine(
            1_700_000_000_000, "warn", "Sync", "Unreadable list", IllegalStateException("bad"),
            mapOf("bytes" to 12, "ok" to false, "missing" to null),
        )
        val json = Json.parseToJsonElement(text).jsonObject
        assertEquals("1700000000000", json["t"]!!.jsonPrimitive.content)
        assertEquals("warn", json["l"]!!.jsonPrimitive.content)
        assertEquals("wear", json["src"]!!.jsonPrimitive.content)
        val fields = json["f"]!!.jsonObject
        assertEquals("Sync", fields["tag"]!!.jsonPrimitive.content)
        assertEquals("12", fields["bytes"]!!.jsonPrimitive.content)
        assertNull(fields["missing"])
        assertEquals("java.lang.IllegalStateException", json["et"]!!.jsonPrimitive.content)
        assertEquals("bad", json["e"]!!.jsonPrimitive.content)
        assertTrue(json["st"]!!.jsonPrimitive.content.contains("IllegalStateException"))
    }

    @Test
    fun payloadRoundTripAndRequestPaths() {
        val payload = LogPayload(
            createdMs = 5, requestId = "ab12cd", uploadNow = true,
            resource = mapOf("service.name" to "kitchenowl-wear"), lines = "${line(1)}\n",
        )
        val bytes = encodeLogPayload(payload)
        assertEquals(payload, decodeLogPayload(bytes))
        val raw = Json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject
        // The names the phone (WearLogInbox.kt) reads.
        assertEquals(setOf("version", "created_ms", "request_id", "upload_now", "resource", "lines"), raw.keys)
        assertNull(decodeLogPayload("nope".toByteArray()))
        assertEquals("ab12cd", logRequestId("/kitchenowl/logs-request/ab12cd"))
        assertNull(logRequestId("/kitchenowl/logs/ab12cd"))
    }
}
