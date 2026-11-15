package com.shadowgraph.daemon.config

data class DaemonConfig(
    val port: Int = DEFAULT_PORT,
    val debounceMs: Long = DEFAULT_DEBOUNCE_MS,
    val maxDepth: Int = DEFAULT_MAX_DEPTH,
    val heartbeatMs: Long = DEFAULT_HEARTBEAT_MS,
    val includeUnimportant: Boolean = false,
    val includeInvisible: Boolean = false,
    val meaningfulOnly: Boolean = false,
    val watchStdin: Boolean = true,
    val clientQueueCapacity: Int = DEFAULT_CLIENT_QUEUE_CAPACITY,
    val verbose: Boolean = false
) {
    init {
        require(port in 1024..65535) { "port must be in 1024..65535, got $port" }
        require(debounceMs in 0L..5000L) { "debounceMs must be in 0..5000, got $debounceMs" }
        require(maxDepth in 1..256) { "maxDepth must be in 1..256, got $maxDepth" }
        require(heartbeatMs in 500L..60000L) { "heartbeatMs must be in 500..60000, got $heartbeatMs" }
        require(clientQueueCapacity in 4..1024) { "clientQueueCapacity must be in 4..1024, got $clientQueueCapacity" }
    }

    companion object {
        const val DEFAULT_PORT = 27189
        const val DEFAULT_DEBOUNCE_MS = 20L
        const val DEFAULT_MAX_DEPTH = 48
        const val DEFAULT_HEARTBEAT_MS = 5000L
        const val DEFAULT_CLIENT_QUEUE_CAPACITY = 32

        fun parse(args: Array<String>): DaemonConfig {
            var port = DEFAULT_PORT
            var debounceMs = DEFAULT_DEBOUNCE_MS
            var maxDepth = DEFAULT_MAX_DEPTH
            var heartbeatMs = DEFAULT_HEARTBEAT_MS
            var includeUnimportant = false
            var includeInvisible = false
            var meaningfulOnly = false
            var watchStdin = true
            var clientQueueCapacity = DEFAULT_CLIENT_QUEUE_CAPACITY
            var verbose = false

            var i = 0
            while (i < args.size) {
                val arg = args[i]
                val eqIdx = arg.indexOf('=')
                val key: String
                val inlineVal: String?
                if (eqIdx > 0 && arg.startsWith("--")) {
                    key = arg.substring(0, eqIdx)
                    inlineVal = arg.substring(eqIdx + 1)
                } else {
                    key = arg
                    inlineVal = null
                }

                fun nextValue(): String {
                    if (inlineVal != null) return inlineVal
                    if (i + 1 >= args.size) {
                        throw IllegalArgumentException("Missing value for argument $key")
                    }
                    i += 1
                    return args[i]
                }

                when (key) {
                    "--port" -> port = nextValue().toIntOrNull()
                        ?: throw IllegalArgumentException("Invalid --port value")
                    "--debounce-ms" -> debounceMs = nextValue().toLongOrNull()
                        ?: throw IllegalArgumentException("Invalid --debounce-ms value")
                    "--max-depth" -> maxDepth = nextValue().toIntOrNull()
                        ?: throw IllegalArgumentException("Invalid --max-depth value")
                    "--heartbeat-ms" -> heartbeatMs = nextValue().toLongOrNull()
                        ?: throw IllegalArgumentException("Invalid --heartbeat-ms value")
                    "--queue-capacity" -> clientQueueCapacity = nextValue().toIntOrNull()
                        ?: throw IllegalArgumentException("Invalid --queue-capacity value")
                    "--include-unimportant" -> includeUnimportant = parseBoolFlag(key, inlineVal)
                    "--include-invisible" -> includeInvisible = parseBoolFlag(key, inlineVal)
                    "--meaningful-only" -> meaningfulOnly = parseBoolFlag(key, inlineVal)
                    "--no-stdin-watchdog" -> watchStdin = !parseBoolFlag(key, inlineVal)
                    "--verbose" -> verbose = parseBoolFlag(key, inlineVal)
                    "--help", "-h" -> throw HelpRequestedException()
                    else -> throw IllegalArgumentException("Unknown argument: $arg")
                }
                i += 1
            }

            return DaemonConfig(
                port = port,
                debounceMs = debounceMs,
                maxDepth = maxDepth,
                heartbeatMs = heartbeatMs,
                includeUnimportant = includeUnimportant,
                includeInvisible = includeInvisible,
                meaningfulOnly = meaningfulOnly,
                watchStdin = watchStdin,
                clientQueueCapacity = clientQueueCapacity,
                verbose = verbose
            )
        }

        fun usage(): String = buildString {
            appendLine("Usage: app_process / com.shadowgraph.daemon.DaemonMain [options]")
            appendLine("  --port=<1024..65535>        Loopback TCP port (default: $DEFAULT_PORT)")
            appendLine("  --debounce-ms=<0..5000>     Event coalescing window in ms (default: $DEFAULT_DEBOUNCE_MS)")
            appendLine("  --max-depth=<1..256>        Max UI tree traversal depth (default: $DEFAULT_MAX_DEPTH)")
            appendLine("  --heartbeat-ms=<500..60000> Heartbeat frame interval in ms (default: $DEFAULT_HEARTBEAT_MS)")
            appendLine("  --queue-capacity=<4..1024>  Per-client outbound frame queue (default: $DEFAULT_CLIENT_QUEUE_CAPACITY)")
            appendLine("  --include-unimportant       Include non-important accessibility views")
            appendLine("  --include-invisible         Include invisible-to-user nodes")
            appendLine("  --meaningful-only           Filter to interactive/text/resourceId nodes (AndroidUINode style)")
            appendLine("  --no-stdin-watchdog         Disable stdin EOF auto-shutdown (for detached mode)")
            appendLine("  --verbose                   Emit diagnostic logs to stderr")
        }

        private fun parseBoolFlag(key: String, inlineVal: String?): Boolean {
            if (inlineVal == null) return true
            return inlineVal.toBooleanStrictOrNull()
                ?: throw IllegalArgumentException("Invalid boolean value for $key: $inlineVal")
        }
    }

    class HelpRequestedException : RuntimeException("Help requested")
}
