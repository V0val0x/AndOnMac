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
}
