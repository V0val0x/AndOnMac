package com.shadowgraph.daemon.input

import android.app.UiAutomation
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import kotlin.math.hypot
import kotlin.math.max

/**
 * Pure trajectory step emitted by [InputInjector.planSwipeSteps] so swipe planning
 * is 100% deterministic and unit-testable on the desktop JVM without Android runtime mocks.
 */
data class SwipeStep(
    val action: Int,
    val x: Float,
    val y: Float,
    val offsetMs: Long,
    val sync: Boolean
)

data class InputExecutionResult(
    val ok: Boolean,
    val error: String? = null,
    val elapsedMs: Long = 0L
)

/**
 * Low-latency native Android input injector backed by [UiAutomation.injectInputEvent].
 * Eliminates the ~350–500 ms `adb shell input` subprocess + JVM startup penalty per gesture
 * and supports zero-fling drag swipes (~120Hz MotionEvent steps with ease-out + terminal hold).
 */
object InputInjector {
    const val STEP_ACTION_DOWN = 0
    const val STEP_ACTION_MOVE = 1
    const val STEP_ACTION_UP = 2
    const val STEP_ACTION_CANCEL = 3
    private const val KEY_FLAG_CANCELED = 0x20

    const val DEFAULT_SWIPE_DURATION_MS = 145L
    const val DEFAULT_SWIPE_HOLD_MS = 25L
    const val DEFAULT_STEP_INTERVAL_MS = 8L
    const val TOUCH_SLOP_PRIMER_PX = 32.0f

    /**
     * Plans a smooth ~120Hz sequence of `DOWN` -> `MOVE`... -> `UP` touch events.
     *
     * When [holdMs] > 0 (zero-fling drag mode):
     * 1. Emits a synchronous touch-slop primer `MOVE` (~32px along the drag vector, `sync = true`)
     *    right after `DOWN` so Android `RecyclerView.onInterceptTouchEvent` enters
     *    `SCROLL_STATE_DRAGGING` deterministically instead of swallowing a variable first Choreographer
     *    frame jump (which otherwise causes ±150px scroll non-determinism across runs).
     * 2. Drives the remaining stroke with a quadratic ease-out curve (`1 - (1-t)^2`) so peak
     *    velocity occurs immediately after touch-slop interception and decelerates smoothly toward 0
     *    well inside Android `VelocityTracker`'s 100ms lookback window, then pauses for [holdMs] at
     *    `(x2, y2)` before emitting a stationary `MOVE` + `UP` (`sync = true`) for 0px fling drift.
     *
     * When [holdMs] == 0 (flick mode, e.g. dismissing a heads-up notification), uses linear
     * interpolation so natural flick velocity is preserved.
     */
    fun planSwipeSteps(
        x1: Float,
        y1: Float,
        x2: Float,
        y2: Float,
        durationMs: Long = DEFAULT_SWIPE_DURATION_MS,
        holdMs: Long = DEFAULT_SWIPE_HOLD_MS,
        stepIntervalMs: Long = DEFAULT_STEP_INTERVAL_MS
    ): List<SwipeStep> {
        val clampedDuration = durationMs.coerceIn(10L, 10_000L)
        val clampedHold = holdMs.coerceIn(0L, 1_000L)
        val clampedInterval = stepIntervalMs.coerceIn(4L, 50L)
        val totalMoveSteps = max(1, ((clampedDuration + clampedInterval / 2L) / clampedInterval).toInt())

        val steps = ArrayList<SwipeStep>(totalMoveSteps + 4)
        steps.add(
            SwipeStep(
                action = STEP_ACTION_DOWN,
                x = x1,
                y = y1,
                offsetMs = 0L,
                sync = true
            )
        )

        val dx = x2 - x1
        val dy = y2 - y1
        val dist = hypot(dx.toDouble(), dy.toDouble()).toFloat()
        val zeroFling = clampedHold > 0L

        if (zeroFling && dist > TOUCH_SLOP_PRIMER_PX * 1.5f && totalMoveSteps >= 3) {
            // Deterministic synchronous touch-slop primer step
            val primerFrac = TOUCH_SLOP_PRIMER_PX / dist
            val primerX = x1 + dx * primerFrac
            val primerY = y1 + dy * primerFrac
            val primerOffsetMs = (clampedDuration / totalMoveSteps).coerceAtLeast(1L)
            steps.add(
                SwipeStep(
                    action = STEP_ACTION_MOVE,
                    x = primerX,
                    y = primerY,
                    offsetMs = primerOffsetMs,
                    sync = true
                )
            )

            val remDx = x2 - primerX
            val remDy = y2 - primerY
            val dragSteps = totalMoveSteps - 1
            val remDuration = (clampedDuration - primerOffsetMs).coerceAtLeast(1L)
            for (i in 1..dragSteps) {
                val t = i.toFloat() / dragSteps.toFloat()
                // Quadratic ease-out (1 - (1-t)^2): fast early drag, near-zero velocity inside LSQ2 horizon
                val inv = 1.0f - t
                val progress = 1.0f - inv * inv
                val px = if (i == dragSteps) x2 else primerX + remDx * progress
                val py = if (i == dragSteps) y2 else primerY + remDy * progress
                val offsetMs = primerOffsetMs + (remDuration * i) / dragSteps
                steps.add(
                    SwipeStep(
                        action = STEP_ACTION_MOVE,
                        x = px,
                        y = py,
                        offsetMs = offsetMs,
                        sync = false
                    )
                )
            }
        } else {
            for (i in 1..totalMoveSteps) {
                val t = i.toFloat() / totalMoveSteps.toFloat()
                val progress = if (zeroFling) {
                    val inv = 1.0f - t
                    1.0f - inv * inv
                } else {
                    t
                }
                val px = if (i == totalMoveSteps) x2 else x1 + dx * progress
                val py = if (i == totalMoveSteps) y2 else y1 + dy * progress
                val offsetMs = (clampedDuration * i) / totalMoveSteps
                steps.add(
                    SwipeStep(
                        action = STEP_ACTION_MOVE,
                        x = px,
                        y = py,
                        offsetMs = offsetMs,
                        sync = false
                    )
                )
            }
        }

        if (zeroFling) {
            val liftOffsetMs = clampedDuration + clampedHold
            steps.add(
                SwipeStep(
                    action = STEP_ACTION_MOVE,
                    x = x2,
                    y = y2,
                    offsetMs = liftOffsetMs,
                    sync = false
                )
            )
            steps.add(
                SwipeStep(
                    action = STEP_ACTION_UP,
                    x = x2,
                    y = y2,
                    offsetMs = liftOffsetMs,
                    sync = true
                )
            )
        } else {
            steps.add(
                SwipeStep(
                    action = STEP_ACTION_UP,
                    x = x2,
                    y = y2,
                    offsetMs = clampedDuration,
                    sync = true
                )
            )
        }

        return steps
    }

    /**
     * Computes the target uptime for [step] during swipe playback.
     * For stationary terminal hold steps (`MOVE` at the same `(x, y)` with a later `offsetMs`),
     * guarantees at least `step.offsetMs - prevStepOffsetMs` after `prevEventTime` so mid-swipe
     * CPU/IPC jitter never truncates or eliminates the zero-fling hold pause.
     */
    internal fun computeStepTargetUptimeMs(
        downTime: Long,
        prevEventTime: Long,
        prevStepOffsetMs: Long,
        step: SwipeStep,
        prevX: Float,
        prevY: Float
    ): Long {
        val scheduledUptime = downTime + step.offsetMs
        val isStationaryHold = step.action == STEP_ACTION_MOVE
            && step.x == prevX
            && step.y == prevY
            && step.offsetMs > prevStepOffsetMs
        return if (isStationaryHold) {
            max(scheduledUptime, prevEventTime + (step.offsetMs - prevStepOffsetMs))
        } else {
            scheduledUptime
        }
    }

    fun injectTap(uia: UiAutomation, x: Int, y: Int): InputExecutionResult =
        injectTapWith(
            x = x,
            y = y,
            uptimeMillis = { SystemClock.uptimeMillis() },
            injectTouch = { downTime, eventTime, stepAction, tx, ty, pressure, sync ->
                injectTouchEvent(
                    uia = uia,
                    downTime = downTime,
                    eventTime = eventTime,
                    action = toAndroidMotionAction(stepAction),
                    x = tx,
                    y = ty,
                    pressure = pressure,
                    sync = sync
                )
            }
        )

    internal fun injectTapWith(
        x: Int,
        y: Int,
        uptimeMillis: () -> Long,
        injectTouch: (
            downTime: Long,
            eventTime: Long,
            stepAction: Int,
            x: Float,
            y: Float,
            pressure: Float,
            sync: Boolean
        ) -> Boolean
    ): InputExecutionResult {
        val startNs = System.nanoTime()
        var downSent = false
        var upSent = false
        var downTime = 0L
        var prevEventTime = 0L
        val fx = x.toFloat()
        val fy = y.toFloat()
        return try {
            downTime = uptimeMillis()
            prevEventTime = downTime

            val okDown = injectTouch(downTime, downTime, STEP_ACTION_DOWN, fx, fy, 1.0f, true)
            if (!okDown) {
                return InputExecutionResult(
                    ok = false,
                    error = "inject_down_returned_false",
                    elapsedMs = elapsedMs(startNs)
                )
            }
            downSent = true

            val upTime = max(prevEventTime, uptimeMillis())
            prevEventTime = upTime
            val okUp = injectTouch(downTime, upTime, STEP_ACTION_UP, fx, fy, 0.0f, true)
            if (!okUp) {
                return InputExecutionResult(
                    ok = false,
                    error = "inject_up_returned_false",
                    elapsedMs = elapsedMs(startNs)
                )
            }
            upSent = true

            InputExecutionResult(ok = true, error = null, elapsedMs = elapsedMs(startNs))
        } catch (t: Throwable) {
            if (t is InterruptedException) {
                Thread.currentThread().interrupt()
            }
            InputExecutionResult(
                ok = false,
                error = "${t.javaClass.simpleName}: ${t.message ?: "unknown"}",
                elapsedMs = elapsedMs(startNs)
            )
        } finally {
            if (downSent && !upSent) {
                try {
                    val cancelTime = max(prevEventTime, uptimeMillis())
                    injectTouch(downTime, cancelTime, STEP_ACTION_CANCEL, fx, fy, 0.0f, true)
                } catch (_: Throwable) {
                }
            }
        }
    }

    fun injectSwipe(
        uia: UiAutomation,
        x1: Int,
        y1: Int,
        x2: Int,
        y2: Int,
        durationMs: Long = DEFAULT_SWIPE_DURATION_MS,
        holdMs: Long = DEFAULT_SWIPE_HOLD_MS
    ): InputExecutionResult =
        injectSwipeWith(
            x1 = x1,
            y1 = y1,
            x2 = x2,
            y2 = y2,
            durationMs = durationMs,
            holdMs = holdMs,
            uptimeMillis = { SystemClock.uptimeMillis() },
            sleepMs = { ms -> Thread.sleep(ms) },
            injectTouch = { downTime, eventTime, stepAction, tx, ty, pressure, sync ->
                injectTouchEvent(
                    uia = uia,
                    downTime = downTime,
                    eventTime = eventTime,
                    action = toAndroidMotionAction(stepAction),
                    x = tx,
                    y = ty,
                    pressure = pressure,
                    sync = sync
                )
            }
        )

    internal fun injectSwipeWith(
        x1: Int,
        y1: Int,
        x2: Int,
        y2: Int,
        durationMs: Long = DEFAULT_SWIPE_DURATION_MS,
        holdMs: Long = DEFAULT_SWIPE_HOLD_MS,
        uptimeMillis: () -> Long,
        sleepMs: (Long) -> Unit,
        injectTouch: (
            downTime: Long,
            eventTime: Long,
            stepAction: Int,
            x: Float,
            y: Float,
            pressure: Float,
            sync: Boolean
        ) -> Boolean
    ): InputExecutionResult {
        val startNs = System.nanoTime()
        val steps = planSwipeSteps(
            x1 = x1.toFloat(),
            y1 = y1.toFloat(),
            x2 = x2.toFloat(),
            y2 = y2.toFloat(),
            durationMs = durationMs,
            holdMs = holdMs
        )

        var downSent = false
        var upSent = false
        var downTime = 0L
        var prevEventTime = 0L
        var lastX = x1.toFloat()
        var lastY = y1.toFloat()

        return try {
            downTime = uptimeMillis()
            prevEventTime = downTime
            var prevStepOffsetMs = 0L

            for (step in steps) {
                if (step.offsetMs > 0L) {
                    val targetUptime = computeStepTargetUptimeMs(
                        downTime = downTime,
                        prevEventTime = prevEventTime,
                        prevStepOffsetMs = prevStepOffsetMs,
                        step = step,
                        prevX = lastX,
                        prevY = lastY
                    )
                    val waitMs = targetUptime - uptimeMillis()
                    if (waitMs > 0L) {
                        sleepMs(waitMs)
                    }
                }

                val eventTime = max(prevEventTime, uptimeMillis())
                prevEventTime = eventTime
                prevStepOffsetMs = step.offsetMs
                lastX = step.x
                lastY = step.y

                val pressure = if (step.action == STEP_ACTION_UP) 0.0f else 1.0f

                val ok = injectTouch(
                    downTime,
                    eventTime,
                    step.action,
                    step.x,
                    step.y,
                    pressure,
                    step.sync
                )

                if (step.action == STEP_ACTION_DOWN && ok) {
                    downSent = true
                }
                if (step.action == STEP_ACTION_UP && ok) {
                    upSent = true
                }
                if (!ok) {
                    return InputExecutionResult(
                        ok = false,
                        error = "inject_swipe_step_returned_false",
                        elapsedMs = elapsedMs(startNs)
                    )
                }
            }

            InputExecutionResult(ok = true, error = null, elapsedMs = elapsedMs(startNs))
        } catch (t: Throwable) {
            if (t is InterruptedException) {
                Thread.currentThread().interrupt()
            }
            InputExecutionResult(
                ok = false,
                error = "${t.javaClass.simpleName}: ${t.message ?: "unknown"}",
                elapsedMs = elapsedMs(startNs)
            )
        } finally {
            // Never leave a stuck pointer down if interrupted mid-swipe.
            if (downSent && !upSent) {
                try {
                    val cancelTime = max(prevEventTime, uptimeMillis())
                    injectTouch(
                        downTime,
                        cancelTime,
                        STEP_ACTION_CANCEL,
                        lastX,
                        lastY,
                        0.0f,
                        true
                    )
                } catch (_: Throwable) {
                }
            }
        }
    }

    fun injectKeyevent(uia: UiAutomation, keycode: Int): InputExecutionResult =
        injectKeyeventWith(
            keycode = keycode,
            uptimeMillis = { SystemClock.uptimeMillis() },
            injectKey = { downTime, eventTime, isDown, code, flags ->
                val event = KeyEvent(
                    downTime,
                    eventTime,
                    if (isDown) KeyEvent.ACTION_DOWN else KeyEvent.ACTION_UP,
                    code,
                    0,
                    0,
                    KeyCharacterMap.VIRTUAL_KEYBOARD,
                    0,
                    flags,
                    InputDevice.SOURCE_KEYBOARD
                )
                uia.injectInputEvent(event, true)
            }
        )

    internal fun injectKeyeventWith(
        keycode: Int,
        uptimeMillis: () -> Long,
        injectKey: (
            downTime: Long,
            eventTime: Long,
            isDown: Boolean,
            keycode: Int,
            flags: Int
        ) -> Boolean
    ): InputExecutionResult {
        val startNs = System.nanoTime()
        var downSent = false
        var upAttempted = false
        var downTime = 0L
        return try {
            downTime = uptimeMillis()
            if (!injectKey(downTime, downTime, true, keycode, 0)) {
                return InputExecutionResult(
                    ok = false,
                    error = "inject_key_down_returned_false",
                    elapsedMs = elapsedMs(startNs)
                )
            }
            downSent = true

            val upTime = max(downTime, uptimeMillis())
            upAttempted = true
            if (!injectKey(downTime, upTime, false, keycode, 0)) {
                return InputExecutionResult(
                    ok = false,
                    error = "inject_key_up_returned_false",
                    elapsedMs = elapsedMs(startNs)
                )
            }

            InputExecutionResult(ok = true, error = null, elapsedMs = elapsedMs(startNs))
        } catch (t: Throwable) {
            if (t is InterruptedException) {
                Thread.currentThread().interrupt()
            }
            InputExecutionResult(
                ok = false,
                error = "${t.javaClass.simpleName}: ${t.message ?: "unknown"}",
                elapsedMs = elapsedMs(startNs)
            )
        } finally {
            if (downSent && !upAttempted) {
                try {
                    val cancelTime = max(downTime, uptimeMillis())
                    injectKey(downTime, cancelTime, false, keycode, KEY_FLAG_CANCELED)
                } catch (_: Throwable) {
                }
            }
        }
    }

    private fun toAndroidMotionAction(stepAction: Int): Int = when (stepAction) {
        STEP_ACTION_DOWN -> MotionEvent.ACTION_DOWN
        STEP_ACTION_UP -> MotionEvent.ACTION_UP
        STEP_ACTION_CANCEL -> MotionEvent.ACTION_CANCEL
        else -> MotionEvent.ACTION_MOVE
    }

    private fun injectTouchEvent(
        uia: UiAutomation,
        downTime: Long,
        eventTime: Long,
        action: Int,
        x: Float,
        y: Float,
        pressure: Float,
        sync: Boolean
    ): Boolean {
        val event = MotionEvent.obtain(
            downTime,
            eventTime,
            action,
            x,
            y,
            pressure,
            1.0f,
            0,
            1.0f,
            1.0f,
            0,
            0
        )
        return try {
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            uia.injectInputEvent(event, sync)
        } finally {
            event.recycle()
        }
    }

    private fun elapsedMs(startNs: Long): Long =
        max(0L, (System.nanoTime() - startNs) / 1_000_000L)
}
