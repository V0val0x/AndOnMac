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

    @Test
    fun `injectTapWith emits ACTION_CANCEL only when DOWN succeeded and UP failed`() {
        // Case 1: DOWN returns false -> must NOT send ACTION_CANCEL
        val events1 = mutableListOf<Int>()
        val res1 = InputInjector.injectTapWith(
            x = 200,
            y = 400,
            uptimeMillis = { 1000L },
            injectTouch = { _, _, action, _, _, _, _ ->
                events1.add(action)
                false
            }
        )
        assertFalse(res1.ok)
        assertEquals("inject_down_returned_false", res1.error)
        assertEquals(listOf(InputInjector.STEP_ACTION_DOWN), events1)

        // Case 2: DOWN returns true, UP returns false -> MUST send ACTION_CANCEL with monotonic eventTime
        data class RecordedTouch(val downTime: Long, val eventTime: Long, val action: Int, val x: Float, val y: Float)
        val events2 = mutableListOf<RecordedTouch>()
        var clock = 2000L
        val res2 = InputInjector.injectTapWith(
            x = 200,
            y = 400,
            uptimeMillis = { clock.also { clock += 3L } },
            injectTouch = { downTime, eventTime, action, x, y, _, _ ->
                events2.add(RecordedTouch(downTime, eventTime, action, x, y))
                action != InputInjector.STEP_ACTION_UP
            }
        )
        assertFalse(res2.ok)
        assertEquals("inject_up_returned_false", res2.error)
        assertEquals(
            listOf(
                InputInjector.STEP_ACTION_DOWN,
                InputInjector.STEP_ACTION_UP,
                InputInjector.STEP_ACTION_CANCEL
            ),
            events2.map { it.action }
        )
        assertTrue(events2[2].eventTime >= events2[1].eventTime, "ACTION_CANCEL eventTime must be monotonic")
    }

    @Test
    fun `injectSwipeWith emits monotonic ACTION_CANCEL on mid-stroke failure, UP failure, and interrupt while preserving hold pause under jitter`() {
        // Case 1: Mid-stroke MOVE returns false -> aborts and emits ACTION_CANCEL at last coordinates with eventTime >= prevEventTime
        data class TouchEvt(val eventTime: Long, val action: Int, val x: Float, val y: Float)
        val midEvents = mutableListOf<TouchEvt>()
        var clock1 = 5000L
        var callIdx = 0
        val resMid = InputInjector.injectSwipeWith(
            x1 = 540,
            y1 = 1900,
            x2 = 540,
            y2 = 450,
            durationMs = 145L,
            holdMs = 25L,
            uptimeMillis = { clock1 },
            sleepMs = { ms -> clock1 += ms },
            injectTouch = { _, eventTime, action, x, y, _, _ ->
                midEvents.add(TouchEvt(eventTime, action, x, y))
                callIdx++
                callIdx != 4
            }
        )
        assertFalse(resMid.ok)
        assertEquals("inject_swipe_step_returned_false", resMid.error)
        assertEquals(InputInjector.STEP_ACTION_CANCEL, midEvents.last().action)
        val failedMove = midEvents[midEvents.size - 2]
        val cancelEvt = midEvents.last()
        assertEquals(failedMove.x, cancelEvt.x)
        assertEquals(failedMove.y, cancelEvt.y)
        assertTrue(cancelEvt.eventTime >= failedMove.eventTime)

        // Case 2: UP returns false -> emits ACTION_CANCEL (verifies upSent only set when ok == true)
        val upFailActions = mutableListOf<Int>()
        var clock2 = 6000L
        val resUpFail = InputInjector.injectSwipeWith(
            x1 = 540,
            y1 = 1900,
            x2 = 540,
            y2 = 450,
            durationMs = 80L,
            holdMs = 25L,
            uptimeMillis = { clock2 },
            sleepMs = { ms -> clock2 += ms },
            injectTouch = { _, _, action, _, _, _, _ ->
                upFailActions.add(action)
                action != InputInjector.STEP_ACTION_UP
            }
        )
        assertFalse(resUpFail.ok)
        assertEquals(InputInjector.STEP_ACTION_UP, upFailActions[upFailActions.size - 2])
        assertEquals(InputInjector.STEP_ACTION_CANCEL, upFailActions.last())

        // Case 3: Heavy +40ms jitter before final drag MOVE -> final drag lands late,
        // and stationary hold MUST still sleep full 25ms after final drag eventTime
        val sleeps = mutableListOf<Long>()
        val eventTimes = mutableListOf<Long>()
        val planned = InputInjector.planSwipeSteps(540f, 1900f, 540f, 450f, durationMs = 145L, holdMs = 25L)
        val finalDragIndex = planned.size - 3
        val holdMoveIndex = planned.size - 2
        var stepIdx = 0
        var clock3 = 7000L
        val resJitter = InputInjector.injectSwipeWith(
            x1 = 540,
            y1 = 1900,
            x2 = 540,
            y2 = 450,
            durationMs = 145L,
            holdMs = 25L,
            uptimeMillis = { clock3 },
            sleepMs = { ms ->
                sleeps.add(ms)
                clock3 += ms
            },
            injectTouch = { _, eventTime, _, _, _, _, _ ->
                eventTimes.add(eventTime)
                if (stepIdx == finalDragIndex - 1) {
                    // Simulate 40ms CPU/IPC stall before final drag step so finalDrag lands past downTime+170
                    clock3 += 40L
                }
                stepIdx++
                true
            }
        )
        assertTrue(resJitter.ok)
        assertEquals(25L, sleeps.last(), "Stationary hold pause must sleep full 25ms even after late drag stall")
        assertEquals(
            25L,
            eventTimes[holdMoveIndex] - eventTimes[finalDragIndex],
            "Hold MOVE eventTime must be full 25ms after late final drag MOVE eventTime"
        )

        // Case 4: InterruptedException mid-sleep -> emits ACTION_CANCEL and restores thread interrupt flag
        val interruptActions = mutableListOf<Int>()
        var clock4 = 8000L
        try {
            val resInt = InputInjector.injectSwipeWith(
                x1 = 540,
                y1 = 1900,
                x2 = 540,
                y2 = 450,
                durationMs = 80L,
                holdMs = 25L,
                uptimeMillis = { clock4 },
                sleepMs = { throw InterruptedException("shutdown") },
                injectTouch = { _, _, action, _, _, _, _ ->
                    interruptActions.add(action)
                    true
                }
            )
            assertFalse(resInt.ok)
            assertEquals(listOf(InputInjector.STEP_ACTION_DOWN, InputInjector.STEP_ACTION_CANCEL), interruptActions)
            assertTrue(Thread.currentThread().isInterrupted, "InterruptedException must preserve thread interrupt flag")
        } finally {
            // Clear interrupt flag so subsequent tests on this runner thread are unaffected
            Thread.interrupted()
        }
    }

    @Test
    fun `injectKeyeventWith emits canceled UP when exception occurs after DOWN`() {
        data class KeyEvt(val isDown: Boolean, val keycode: Int, val flags: Int)
        val events = mutableListOf<KeyEvt>()
        var calls = 0
        val res = InputInjector.injectKeyeventWith(
            keycode = 4,
            uptimeMillis = {
                calls++
                if (calls == 2) throw IllegalStateException("clock_glitch")
                1000L
            },
            injectKey = { _, _, isDown, code, flags ->
                events.add(KeyEvt(isDown, code, flags))
                true
            }
        )
        assertFalse(res.ok)
        assertEquals(2, events.size)
        assertTrue(events[0].isDown)
        assertFalse(events[1].isDown)
        assertEquals(0x20, events[1].flags)
    }
}
