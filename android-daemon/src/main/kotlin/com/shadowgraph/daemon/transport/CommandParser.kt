package com.shadowgraph.daemon.transport

/**
 * Pure Kotlin stdlib parser for inbound 1-line JSON control commands.
 * Supported commands:
 * - {"cmd":"snapshot"}
 * - {"cmd":"ping"}
 * - {"cmd":"set_debounce","ms":30}
 * - {"cmd":"shutdown"}
 */
object CommandParser {
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
            else -> InboundCommand.Unknown(line, "unknown_cmd:$cmd")
        }
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
