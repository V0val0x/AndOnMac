# GEMINI.md — AndOnMac (Gemini CLI & Antigravity)

<!-- DROIDPATH_MCP_RULES_START -->
# AndOnMac / DroidPath Android Control Protocol (Shadow DOM & Layer 3 A* Router)

Follow this strict protocol whenever controlling an Android device through AndOnMac MCP tools:

1. **Navigate First with `auto_explore: true`**:
   - For any multi-step goal or known screen destination, ALWAYS call `android_navigate_to_node(target: "...", auto_explore: true)` first.
   - It computes the shortest A* route across the persistent Spatial Graph (`shadow_graph.json`) and automatically falls back to live Shadow DOM discovery (`android_explore_and_click`) if no route exists yet.
2. **Direct Discovery via `android_explore_and_click`**:
   - To find and tap a single element on the current screen (or via a breadcrumb prefix like `"Display > Night Light"`), call `android_explore_and_click(target: "...")`.
   - It scores live Shadow DOM nodes, auto-scrolls scrollable containers (up to `max_scrolls`, reversing at the bottom), dismisses occluding heads-up notifications, and records new edges into the Spatial Graph automatically.
3. **NEVER Call `android_screenshot` While Shadow DOM Is Alive**:
   - **STRICTLY FORBIDDEN** to call `android_screenshot` while the Shadow DOM daemon stream is alive (`android_get_ui_tree`, `android_explore_and_click`, and `android_navigate_to_node` provide <1ms accessibility trees at a fraction of the token cost).
   - Only use `android_screenshot` if the Shadow DOM stream is explicitly unavailable or the user specifically asks to inspect non-text imagery.
4. **Handle `needs_selection` Without Guessing**:
   - If `android_explore_and_click` (or `auto_explore: true`) returns `status: "needs_selection"` with a compressed top-20 PII-scrubbed `candidates` list, select the matching candidate from that list and tap it or refine `target`. Do NOT fall back to screenshots.
5. **Mandatory Human-in-the-Loop (`requires_confirmation`)**:
   - If ANY tool returns `status: "requires_confirmation"` (`is_hazardous: true`, e.g., payment, purchase, transfer, send, delete, factory reset):
     - **STOP IMMEDIATELY.**
     - Present the exact `blocked_action` and `hazard_reason` to the user in chat.
     - **NEVER** pass `confirmed: true` without explicit user approval in the current conversation.
6. **Mandatory Biometric / `FLAG_SECURE` Privacy Pause (`secure_screen_active`)**:
   - If a tool returns `status: "secure_screen_active"` (`code: "SECURE_SCREEN_ACTIVE"`):
     - **STOP IMMEDIATELY.** Do not attempt taps, swipes, or screenshots.
     - Ask the user to unlock/authenticate on the physical Android device and retry only after confirmation.
   - Never ask for, echo, or persist raw passwords, payment card PANs, CVV/CVC, or OTP codes. Password inputs are masked to `***` on-device and PANs/OTPs are scrubbed to `<CARD>` / `<OTP>` before hashing or graph persistence.
7. **Minimal-Token Efficiency (Cloud & Local / On-Device Models)**:
   - Prefer 1 high-level `android_navigate_to_node(target, auto_explore: true)` or `android_explore_and_click(target)` call over raw `android_get_ui_tree` + coordinate loops.
<!-- DROIDPATH_MCP_RULES_END -->
