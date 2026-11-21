package com.shadowgraph.daemon.transport

import com.shadowgraph.daemon.input.InputInjector
import kotlin.math.roundToInt

/**
 * Pure Kotlin stdlib parser for inbound 1-line JSON control commands.
 * Supported commands:
 * - {"cmd":"snapshot"}
 * - {"cmd":"ping"}
 * - {"cmd":"set_debounce","ms":30}
 * - {"cmd":"shutdown"}
 * - {"cmd":"tap","id":1,"x":540,"y":1200}
 * - {"cmd":"swipe","id":2,"x1":540,"y1":1900,"x2":540,"y2":450,"duration_ms":145,"hold_ms":25}
 * - {"cmd":"keyevent","id":3,"keycode":4}
 */
object CommandParser {
    private const val MAX_COORD = 16_384
    private const val MIN_SWIPE_DURATION_MS = 10L
    private const val MAX_SWIPE_DURATION_MS = 10_000L
    private const val MAX_SWIPE_HOLD_MS = 1_000L
    private const val MIN_KEYCODE = 1
    private const val MAX_KEYCODE = 1024

    fun parseLine(line: String): InboundCommand {
        val trimmed = line.trim()
        if (trimmed.isEmpty()) {
            return InboundCommand.Unknown(line, "empty_line")
        }
        if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
            return InboundCommand.Unknown(line, "not_json_object")
        }

        val fields = parseFlatJsonObject(trimmed)
            ?: return InboundCommand.Unknown(line, "malformed_json")

        val cmd = fields["cmd"] as? String
            ?: return InboundCommand.Unknown(line, "missing_cmd")

        return when (cmd) {
            "snapshot" -> InboundCommand.Snapshot
            "ping" -> InboundCommand.Ping
            "shutdown" -> InboundCommand.Shutdown
            "set_debounce" -> {
                val ms = (fields["ms"] as? Long)
                    ?: return InboundCommand.Unknown(line, "missing_or_invalid_ms")
                if (ms !in 0L..5000L) {
                    return InboundCommand.Unknown(line, "ms_out_of_range")
                }
                InboundCommand.SetDebounce(ms)
            }
            "tap" -> parseTap(line, fields)
            "swipe" -> parseSwipe(line, fields)
            "keyevent" -> parseKeyevent(line, fields)
            else -> InboundCommand.Unknown(line, "unknown_cmd:$cmd")
        }
    }

    private fun parseOptionalId(fields: Map<String, Any?>): Long? {
        if (!fields.containsKey("id") || fields["id"] == null) return 0L
        val raw = fields["id"] as? Long ?: return null
        return if (raw >= 0L) raw else null
    }

    private fun parseCoord(fields: Map<String, Any?>, key: String): Int? {
        val v = when (val raw = fields[key]) {
            is Long -> if (raw in 0L..MAX_COORD.toLong()) raw.toInt() else return null
            is Double -> if (raw.isFinite() && raw >= 0.0 && raw <= MAX_COORD.toDouble()) raw.roundToInt() else return null
            else -> return null
        }
        return if (v in 0..MAX_COORD) v else null
    }

    private fun parseTap(line: String, fields: Map<String, Any?>): InboundCommand {
        val id = parseOptionalId(fields) ?: return InboundCommand.Unknown(line, "invalid_id", cmd = "tap")
        val replyId = if (fields.containsKey("id") && fields["id"] != null) id else null
        val x = parseCoord(fields, "x")
            ?: return InboundCommand.Unknown(line, "missing_or_invalid_x", id = replyId, cmd = "tap")
        val y = parseCoord(fields, "y")
            ?: return InboundCommand.Unknown(line, "missing_or_invalid_y", id = replyId, cmd = "tap")
        return InboundCommand.Tap(id = id, x = x, y = y)
    }

    private fun parseSwipe(line: String, fields: Map<String, Any?>): InboundCommand {
        val id = parseOptionalId(fields) ?: return InboundCommand.Unknown(line, "invalid_id", cmd = "swipe")
        val replyId = if (fields.containsKey("id") && fields["id"] != null) id else null
        val x1 = parseCoord(fields, "x1")
            ?: return InboundCommand.Unknown(line, "missing_or_invalid_x1", id = replyId, cmd = "swipe")
        val y1 = parseCoord(fields, "y1")
            ?: return InboundCommand.Unknown(line, "missing_or_invalid_y1", id = replyId, cmd = "swipe")
        val x2 = parseCoord(fields, "x2")
            ?: return InboundCommand.Unknown(line, "missing_or_invalid_x2", id = replyId, cmd = "swipe")
        val y2 = parseCoord(fields, "y2")
            ?: return InboundCommand.Unknown(line, "missing_or_invalid_y2", id = replyId, cmd = "swipe")

        val durationMs = if (!fields.containsKey("duration_ms") || fields["duration_ms"] == null) {
            InputInjector.DEFAULT_SWIPE_DURATION_MS
        } else {
            val raw = fields["duration_ms"] as? Long
                ?: return InboundCommand.Unknown(line, "invalid_duration_ms", id = replyId, cmd = "swipe")
            if (raw !in MIN_SWIPE_DURATION_MS..MAX_SWIPE_DURATION_MS) {
                return InboundCommand.Unknown(line, "duration_ms_out_of_range", id = replyId, cmd = "swipe")
            }
            raw
        }

        val holdMs = if (!fields.containsKey("hold_ms") || fields["hold_ms"] == null) {
            InputInjector.DEFAULT_SWIPE_HOLD_MS
        } else {
            val raw = fields["hold_ms"] as? Long
                ?: return InboundCommand.Unknown(line, "invalid_hold_ms", id = replyId, cmd = "swipe")
            if (raw !in 0L..MAX_SWIPE_HOLD_MS) {
                return InboundCommand.Unknown(line, "hold_ms_out_of_range", id = replyId, cmd = "swipe")
            }
            raw
        }

        return InboundCommand.Swipe(
            id = id,
            x1 = x1,
            y1 = y1,
            x2 = x2,
            y2 = y2,
            durationMs = durationMs,
            holdMs = holdMs
        )
    }

    private fun parseKeyevent(line: String, fields: Map<String, Any?>): InboundCommand {
        val id = parseOptionalId(fields) ?: return InboundCommand.Unknown(line, "invalid_id", cmd = "keyevent")
        val replyId = if (fields.containsKey("id") && fields["id"] != null) id else null
        val rawCode = fields["keycode"] as? Long
            ?: return InboundCommand.Unknown(line, "missing_or_invalid_keycode", id = replyId, cmd = "keyevent")
        if (rawCode !in MIN_KEYCODE.toLong()..MAX_KEYCODE.toLong()) {
            return InboundCommand.Unknown(line, "keycode_out_of_range", id = replyId, cmd = "keyevent")
        }
        return InboundCommand.Keyevent(id = id, keycode = rawCode.toInt())
    }

    private fun parseFlatJsonObject(input: String): Map<String, Any?>? {
        val result = HashMap<String, Any?>(4)
        var i = 1 // skip '{'
        val n = input.length - 1 // stop before '}'

        fun skipWs() {
            while (i < n && input[i].isWhitespace()) i++
        }

        fun parseString(): String? {
            if (i >= n || input[i] != '"') return null
            i++
            val sb = StringBuilder()
            while (i < n) {
                val c = input[i++]
                when (c) {
                    '"' -> return sb.toString()
                    '\\' -> {
                        if (i >= n) return null
                        when (val esc = input[i++]) {
                            '"', '\\', '/' -> sb.append(esc)
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            'b' -> sb.append('\b')
                            'f' -> sb.append('\u000C')
                            'u' -> {
                                if (i + 4 > n) return null
                                val hex = input.substring(i, i + 4)
                                val code = hex.toIntOrNull(16) ?: return null
                                sb.append(code.toChar())
                                i += 4
                            }
                            else -> return null
                        }
                    }
                    else -> sb.append(c)
                }
            }
            return null
        }

        fun skipNestedValue(): Boolean {
            if (i >= n) return false
            val open = input[i]
            val close = if (open == '{') '}' else ']'
            var depth = 0
            while (i < n) {
                val c = input[i++]
                if (c == '"') {
                    i--
                    if (parseString() == null) return false
                } else if (c == open) {
                    depth++
                } else if (c == close) {
                    depth--
                    if (depth == 0) return true
                }
            }
            return false
        }

        skipWs()
        if (i >= n) return result

        while (i < n) {
            skipWs()
            val key = parseString() ?: return null
            skipWs()
            if (i >= n || input[i] != ':') return null
            i++
            skipWs()
            if (i >= n) return null

            val value: Any? = when (val c = input[i]) {
                '"' -> parseString() ?: return null
                '{', '[' -> {
                    if (!skipNestedValue()) return null
                    null
                }
                't' -> {
                    if (input.startsWith("true", i)) {
                        i += 4
                        true
                    } else return null
                }
                'f' -> {
                    if (input.startsWith("false", i)) {
                        i += 5
                        false
                    } else return null
                }
                'n' -> {
                    if (input.startsWith("null", i)) {
                        i += 4
                        null
                    } else return null
                }
                '-', in '0'..'9' -> {
                    val start = i
                    if (c == '-') i++
                    while (i < n && (input[i].isDigit() || input[i] == '.' || input[i] == 'e' || input[i] == 'E' || input[i] == '+' || input[i] == '-')) {
                        i++
                    }
                    val token = input.substring(start, i)
                    token.toLongOrNull() ?: token.toDoubleOrNull() ?: return null
                }
                else -> return null
            }

            result[key] = value
            skipWs()
            if (i >= n) break
            if (input[i] == ',') {
                i++
                skipWs()
                if (i >= n) return null
            } else {
                return null
            }
        }
        return result
    }
}
