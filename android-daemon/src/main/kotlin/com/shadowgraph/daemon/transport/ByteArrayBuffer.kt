package com.shadowgraph.daemon.transport

/**
 * Reusable UTF-8 byte buffer designed for zero-allocation serialization in the hot loop.
 * Call [reset] before encoding each frame, then [toByteArray] (or [writeTo]) once encoded.
 */
class ByteArrayBuffer(initialCapacity: Int = 16 * 1024) {
    var data: ByteArray = ByteArray(initialCapacity)
        private set
    var size: Int = 0
        private set

    fun reset() {
        size = 0
    }

    fun ensureCapacity(additional: Int) {
        val required = size + additional
        if (required <= data.size) return
        var newCap = data.size * 2
        while (newCap < required) {
            newCap *= 2
        }
        data = data.copyOf(newCap)
    }

    fun appendByte(b: Int) {
        ensureCapacity(1)
        data[size++] = b.toByte()
    }

    fun appendAscii(s: String) {
        val len = s.length
        ensureCapacity(len)
        for (i in 0 until len) {
            data[size++] = s[i].code.toByte()
        }
    }

    fun appendBoolean(value: Boolean) {
        if (value) {
            ensureCapacity(4)
            data[size++] = 't'.code.toByte()
            data[size++] = 'r'.code.toByte()
            data[size++] = 'u'.code.toByte()
            data[size++] = 'e'.code.toByte()
        } else {
            ensureCapacity(5)
            data[size++] = 'f'.code.toByte()
            data[size++] = 'a'.code.toByte()
            data[size++] = 'l'.code.toByte()
            data[size++] = 's'.code.toByte()
            data[size++] = 'e'.code.toByte()
        }
    }

    fun appendInt(value: Int) {
        appendLong(value.toLong())
    }

    fun appendLong(value: Long) {
        if (value == 0L) {
            appendByte('0'.code)
            return
        }
        if (value == Long.MIN_VALUE) {
            appendAscii("-9223372036854775808")
            return
        }
        ensureCapacity(20)
        var v = value
        if (v < 0L) {
            data[size++] = '-'.code.toByte()
            v = -v
        }
        val start = size
        while (v > 0L) {
            val q = v / 10L
            val r = (v - q * 10L).toInt()
            data[size++] = ('0'.code + r).toByte()
            v = q
        }
        // Reverse digits in-place
        var lo = start
        var hi = size - 1
        while (lo < hi) {
            val tmp = data[lo]
            data[lo] = data[hi]
            data[hi] = tmp
            lo++
            hi--
        }
    }

    /**
     * Appends [s] as a quoted, RFC-8259-escaped UTF-8 JSON string without intermediate allocations.
     */
    fun appendJsonString(s: String) {
        val len = s.length
        // Reserve at least 1 byte per char + 2 quotes; multi-byte/escaped branches ensure extra capacity as needed
        ensureCapacity(len + 2)
        data[size++] = '"'.code.toByte()
        var i = 0
        while (i < len) {
            val c = s[i]
            val code = c.code
            when {
                code == '"'.code -> {
                    ensureCapacity(2)
                    data[size++] = '\\'.code.toByte()
                    data[size++] = '"'.code.toByte()
                }
                code == '\\'.code -> {
                    ensureCapacity(2)
                    data[size++] = '\\'.code.toByte()
                    data[size++] = '\\'.code.toByte()
                }
                code == '\n'.code -> {
                    ensureCapacity(2)
                    data[size++] = '\\'.code.toByte()
                    data[size++] = 'n'.code.toByte()
                }
                code == '\r'.code -> {
                    ensureCapacity(2)
                    data[size++] = '\\'.code.toByte()
                    data[size++] = 'r'.code.toByte()
                }
                code == '\t'.code -> {
                    ensureCapacity(2)
                    data[size++] = '\\'.code.toByte()
                    data[size++] = 't'.code.toByte()
                }
                code == '\b'.code -> {
                    ensureCapacity(2)
                    data[size++] = '\\'.code.toByte()
                    data[size++] = 'b'.code.toByte()
                }
                code == 0x0C -> {
                    ensureCapacity(2)
                    data[size++] = '\\'.code.toByte()
                    data[size++] = 'f'.code.toByte()
                }
                code < 0x20 -> {
                    ensureCapacity(6)
                    data[size++] = '\\'.code.toByte()
                    data[size++] = 'u'.code.toByte()
                    data[size++] = '0'.code.toByte()
                    data[size++] = '0'.code.toByte()
                    data[size++] = HEX_DIGITS[(code ushr 4) and 0xF]
                    data[size++] = HEX_DIGITS[code and 0xF]
                }
                code < 0x80 -> {
                    ensureCapacity(1)
                    data[size++] = code.toByte()
                }
                code < 0x800 -> {
                    ensureCapacity(2)
                    data[size++] = (0xC0 or (code ushr 6)).toByte()
                    data[size++] = (0x80 or (code and 0x3F)).toByte()
                }
                Character.isHighSurrogate(c) && i + 1 < len && Character.isLowSurrogate(s[i + 1]) -> {
                    val cp = Character.toCodePoint(c, s[i + 1])
                    ensureCapacity(4)
                    data[size++] = (0xF0 or (cp ushr 18)).toByte()
                    data[size++] = (0x80 or ((cp ushr 12) and 0x3F)).toByte()
                    data[size++] = (0x80 or ((cp ushr 6) and 0x3F)).toByte()
                    data[size++] = (0x80 or (cp and 0x3F)).toByte()
                    i++
                }
                Character.isSurrogate(c) -> {
                    // Unpaired surrogate -> U+FFFD replacement char in UTF-8 (EF BF BD)
                    ensureCapacity(3)
                    data[size++] = 0xEF.toByte()
                    data[size++] = 0xBF.toByte()
                    data[size++] = 0xBD.toByte()
                }
                else -> {
                    ensureCapacity(3)
                    data[size++] = (0xE0 or (code ushr 12)).toByte()
                    data[size++] = (0x80 or ((code ushr 6) and 0x3F)).toByte()
                    data[size++] = (0x80 or (code and 0x3F)).toByte()
                }
            }
            i++
        }
        ensureCapacity(1)
        data[size++] = '"'.code.toByte()
    }

    fun toByteArray(): ByteArray = data.copyOf(size)

    companion object {
        private val HEX_DIGITS = byteArrayOf(
            '0'.code.toByte(), '1'.code.toByte(), '2'.code.toByte(), '3'.code.toByte(),
            '4'.code.toByte(), '5'.code.toByte(), '6'.code.toByte(), '7'.code.toByte(),
            '8'.code.toByte(), '9'.code.toByte(), 'a'.code.toByte(), 'b'.code.toByte(),
            'c'.code.toByte(), 'd'.code.toByte(), 'e'.code.toByte(), 'f'.code.toByte()
        )
    }
}
