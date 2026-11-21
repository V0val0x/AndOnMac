package com.shadowgraph.daemon

import com.shadowgraph.daemon.input.InputInjector
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class InputInjectorTest {
    @Test
    fun `plans zero-fling ease-out 120Hz swipe with terminal hold pause`() {
        val steps = InputInjector.planSwipeSteps(
            x1 = 540f,
            y1 = 1900f,
            x2 = 540f,
            y2 = 450f,
            durationMs = 145L,
            holdMs = 25L,
            stepIntervalMs = 8L
        )

        // 1 DOWN + ~18 MOVEs + 1 stationary hold MOVE + 1 UP
        assertTrue(steps.size >= 18, "Expected ~120Hz step density, got ${steps.size}")

        val first = steps.first()
        assertEquals(InputInjector.STEP_ACTION_DOWN, first.action)
        assertEquals(540f, first.x)
        assertEquals(1900f, first.y)
        assertEquals(0L, first.offsetMs)
        assertTrue(first.sync)

        val last = steps.last()
        assertEquals(InputInjector.STEP_ACTION_UP, last.action)
        assertEquals(540f, last.x)
        assertEquals(450f, last.y)
        assertEquals(170L, last.offsetMs)
        assertTrue(last.sync)

        val holdMove = steps[steps.size - 2]
        val finalDragMove = steps[steps.size - 3]
        assertEquals(InputInjector.STEP_ACTION_MOVE, holdMove.action)
        assertEquals(InputInjector.STEP_ACTION_MOVE, finalDragMove.action)
        assertEquals(450f, finalDragMove.y)
        assertEquals(450f, holdMove.y)
        assertEquals(145L, finalDragMove.offsetMs)
        assertEquals(170L, holdMove.offsetMs)
        assertFalse(holdMove.sync)

        // Step 1 must be the synchronous touch-slop primer (~32px along stroke)
        val primer = steps[1]
        assertEquals(InputInjector.STEP_ACTION_MOVE, primer.action)
        assertTrue(primer.sync, "Touch-slop primer step must be synchronous")
        assertTrue(abs((first.y - primer.y) - InputInjector.TOUCH_SLOP_PRIMER_PX) < 0.05f)

        // Verify quadratic ease-out deceleration: first drag delta > final drag delta
        val dragMoves = steps.subList(2, steps.size - 2)
        val firstDragDelta = abs(dragMoves[0].y - primer.y)
        val lastDragDelta = abs(dragMoves.last().y - dragMoves[dragMoves.size - 2].y)
        assertTrue(
            firstDragDelta > lastDragDelta * 3f,
            "Expected quadratic ease-out deceleration (firstDragDelta=$firstDragDelta, lastDragDelta=$lastDragDelta)"
        )

        // Timestamps must be monotonically non-decreasing
        for (i in 1 until steps.size) {
            assertTrue(steps[i].offsetMs >= steps[i - 1].offsetMs)
        }
    }

    @Test
    fun `plans linear flick swipe without hold when holdMs is zero`() {
        val steps = InputInjector.planSwipeSteps(
            x1 = 540f,
            y1 = 300f,
            x2 = 540f,
            y2 = 20f,
            durationMs = 160L,
            holdMs = 0L,
            stepIntervalMs = 8L
        )

        // 1 DOWN + 20 MOVEs + 1 UP = 22 steps
        assertEquals(22, steps.size)
        assertEquals(InputInjector.STEP_ACTION_DOWN, steps.first().action)
        assertEquals(InputInjector.STEP_ACTION_UP, steps.last().action)
        assertEquals(160L, steps.last().offsetMs)

        // Linear spacing: every MOVE delta should be equal (280 / 20 = 14px)
        val moves = steps.subList(1, steps.size - 1)
        val expectedStepY = (20f - 300f) / 20f
        for (i in moves.indices) {
            val expectedY = 300f + expectedStepY * (i + 1)
            assertTrue(
                abs(moves[i].y - expectedY) < 0.01f,
                "Expected linear y=$expectedY at index $i, got ${moves[i].y}"
            )
        }
    }

    @Test
    fun `handles zero-distance and short swipes without NaN or primer overshoot`() {
        // Zero-distance swipe must never divide by zero or produce NaN
        val zeroSteps = InputInjector.planSwipeSteps(
            x1 = 540f,
            y1 = 1200f,
            x2 = 540f,
            y2 = 1200f,
            durationMs = 145L,
            holdMs = 25L
        )
        assertTrue(zeroSteps.all { it.x == 540f && it.y == 1200f && !it.x.isNaN() && !it.y.isNaN() })

        // Short swipe (< 1.5x touch slop primer) must stay monotonically within [1000, 980]
        val shortSteps = InputInjector.planSwipeSteps(
            x1 = 540f,
            y1 = 1000f,
            x2 = 540f,
            y2 = 980f,
            durationMs = 100L,
            holdMs = 25L
        )
        assertTrue(shortSteps.all { it.y in 980f..1000f }, "Short swipe must never overshoot endpoints")
        assertEquals(980f, shortSteps.last().y)
    }

    @Test
    fun `stationary hold step preserves full holdMs even when prior drag move finished late`() {
        val steps = InputInjector.planSwipeSteps(
            x1 = 540f,
            y1 = 1900f,
            x2 = 540f,
            y2 = 450f,
            durationMs = 145L,
            holdMs = 25L
        )
        val finalDrag = steps[steps.size - 3]
        val holdMove = steps[steps.size - 2]

        // Suppose downTime=1000, and due to CPU/IPC jitter finalDrag actually landed 35ms late at uptime=1180.
        // Without relative hold anchoring, downTime+170=1170 would skip the hold completely (sleepMs <= 0).
        val target = InputInjector.computeStepTargetUptimeMs(
            downTime = 1000L,
            prevEventTime = 1180L,
            prevStepOffsetMs = finalDrag.offsetMs,
            step = holdMove,
            prevX = finalDrag.x,
            prevY = finalDrag.y
        )
        assertEquals(1205L, target, "Stationary hold must guarantee full 25ms pause after late final drag move")
    }
}
