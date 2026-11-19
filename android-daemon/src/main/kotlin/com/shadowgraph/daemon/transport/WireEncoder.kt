package com.shadowgraph.daemon.transport

/**
 * Abstracts wire serialization (e.g., NDJSON today, binary/varint codec later)
 * without coupling [com.shadowgraph.daemon.graph.ShadowTreeDiffer] or
 * [DaemonTcpServer] to a specific framing format.
 */
interface WireEncoder {
    val formatName: String

    fun encodeHello(hello: WireHello, out: ByteArrayBuffer)
    fun encodeSnapshot(snapshot: WireSnapshot, out: ByteArrayBuffer)
    fun encodeDiff(diff: WireDiff, out: ByteArrayBuffer)
    fun encodeHeartbeat(heartbeat: WireHeartbeat, out: ByteArrayBuffer)
    fun encodeError(error: WireError, out: ByteArrayBuffer)
    fun encodePong(pong: WirePong, out: ByteArrayBuffer)
    fun encodeSecureScreen(secure: WireSecureScreen, out: ByteArrayBuffer)
    fun encodeInputResult(result: WireInputResult, out: ByteArrayBuffer)
}
