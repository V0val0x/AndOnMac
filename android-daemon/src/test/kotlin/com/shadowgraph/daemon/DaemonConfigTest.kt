package com.shadowgraph.daemon

import com.shadowgraph.daemon.config.DaemonConfig
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DaemonConfigTest {
    @Test
    fun `parses defaults when args are empty`() {
        val cfg = DaemonConfig.parse(emptyArray())
        assertEquals(DaemonConfig.DEFAULT_PORT, cfg.port)
        assertEquals(DaemonConfig.DEFAULT_DEBOUNCE_MS, cfg.debounceMs)
        assertEquals(DaemonConfig.DEFAULT_MAX_DEPTH, cfg.maxDepth)
        assertEquals(DaemonConfig.DEFAULT_HEARTBEAT_MS, cfg.heartbeatMs)
        assertFalse(cfg.includeUnimportant)
        assertFalse(cfg.includeInvisible)
        assertFalse(cfg.meaningfulOnly)
        assertFalse(cfg.verbose)
    }

    @Test
    fun `parses mixed inline and space-separated flags`() {
        val cfg = DaemonConfig.parse(
            arrayOf(
                "--port=28000",
                "--debounce-ms", "35",
                "--max-depth=32",
                "--heartbeat-ms", "2000",
                "--queue-capacity=64",
                "--include-unimportant",
                "--include-invisible",
                "--meaningful-only",
                "--no-stdin-watchdog",
                "--verbose"
            )
        )
        assertEquals(28000, cfg.port)
        assertEquals(35L, cfg.debounceMs)
        assertEquals(32, cfg.maxDepth)
        assertEquals(2000L, cfg.heartbeatMs)
        assertEquals(64, cfg.clientQueueCapacity)
        assertTrue(cfg.includeUnimportant)
        assertTrue(cfg.includeInvisible)
        assertTrue(cfg.meaningfulOnly)
        assertFalse(cfg.watchStdin)
        assertTrue(cfg.verbose)
    }

    @Test
    fun `rejects invalid port and unknown flags`() {
        assertFailsWith<IllegalArgumentException> {
            DaemonConfig.parse(arrayOf("--port=80"))
        }
        assertFailsWith<IllegalArgumentException> {
            DaemonConfig.parse(arrayOf("--unknown-flag"))
        }
        assertFailsWith<IllegalArgumentException> {
            DaemonConfig.parse(arrayOf("--debounce-ms"))
        }
        assertFailsWith<IllegalArgumentException> {
            DaemonConfig.parse(arrayOf("--include-unimportant=maybe"))
        }
        assertFailsWith<DaemonConfig.HelpRequestedException> {
            DaemonConfig.parse(arrayOf("--help"))
        }
    }

    @Test
    fun `parses inline false boolean flags accurately`() {
        val cfg = DaemonConfig.parse(
            arrayOf(
                "--include-unimportant=false",
                "--no-stdin-watchdog=false"
            )
        )
        assertFalse(cfg.includeUnimportant)
        assertTrue(cfg.watchStdin)
    }
}
