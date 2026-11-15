import Foundation

public enum LineFramerError: Error, Sendable, Equatable {
    case frameTooLarge(byteCount: Int, limit: Int)
}

/// Stateful LF (`0x0A`) byte-stream framer for arbitrary `NWConnection` TCP chunks.
/// Operates exclusively on raw UTF-8 bytes so multi-byte characters split across TCP packets
/// are never corrupted, and bounds memory strictly to `maxFrameBytes`.
public struct LineFramer: Sendable {
    public let maxFrameBytes: Int
    private var buffer = Data()
    private var peakBufferBytes: Int = 0

    /// Number of bytes currently buffered for an incomplete trailing line.
    public var bufferedByteCount: Int {
        buffer.count
    }

    public init(maxFrameBytes: Int = 8 * 1024 * 1024) {
        self.maxFrameBytes = max(1, maxFrameBytes)
    }

    /// Appends an incoming TCP byte chunk and returns all complete newline-delimited frames.
    /// Empty lines (`\n` or `\r\n`) are skipped cleanly.
    public mutating func append(_ chunk: Data) throws -> [Data] {
        guard !chunk.isEmpty else { return [] }

        var frames: [Data] = []
        let lf: UInt8 = 0x0A
        let cr: UInt8 = 0x0D
        let maxBytes = maxFrameBytes

        try chunk.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            let total = rawBuffer.count
            var segmentStart = 0

            for i in 0..<total {
                if base[i] == lf {
                    var segmentEnd = i
                    if segmentEnd > segmentStart && base[segmentEnd - 1] == cr {
                        segmentEnd -= 1
                    }
                    let sliceCount = segmentEnd - segmentStart

                    if buffer.isEmpty {
                        if sliceCount > maxBytes {
                            reset()
                            throw LineFramerError.frameTooLarge(byteCount: sliceCount, limit: maxBytes)
                        }
                        if sliceCount > 0 {
                            frames.append(Data(bytes: base + segmentStart, count: sliceCount))
                        }
                    } else {
                        let combinedCount = buffer.count + sliceCount
                        if combinedCount > maxBytes {
                            reset()
                            throw LineFramerError.frameTooLarge(byteCount: combinedCount, limit: maxBytes)
                        }
                        if sliceCount > 0 {
                            buffer.append(base + segmentStart, count: sliceCount)
                        }
                        // Trim trailing CR if CR was the final byte of previous chunk and LF was first byte here
                        if buffer.last == cr {
                            buffer.removeLast()
                        }
                        if !buffer.isEmpty {
                            frames.append(buffer)
                        }
                        if peakBufferBytes > 256 * 1024 {
                            // Release oversized capacity after large snapshots to avoid pinned RSS growth
                            buffer = Data()
                            peakBufferBytes = 0
                        } else {
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    segmentStart = i + 1
                }
            }

            // Retain incomplete trailing bytes
            if segmentStart < total {
                let tailCount = total - segmentStart
                let nextBufferedCount = buffer.count + tailCount
                if nextBufferedCount > maxBytes {
                    reset()
                    throw LineFramerError.frameTooLarge(byteCount: nextBufferedCount, limit: maxBytes)
                }
                buffer.append(base + segmentStart, count: tailCount)
                if buffer.count > peakBufferBytes {
                    peakBufferBytes = buffer.count
                }
            }
        }

        return frames
    }

    /// Discards any partial buffered data and releases backing memory.
    public mutating func reset() {
        buffer = Data()
        peakBufferBytes = 0
    }
}
