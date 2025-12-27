# OpenScience Native (macOS)

**A hyper-secure, privacy-first “clean room” scientific instrument for auditing LLM behavior via OpenRouter.**

## Key guarantees (by design)
- **Zero persistence**: no CoreData/SQLite/UserDefaults usage; all app state exists only in RAM.
- **Stateless-by-default**: when **Context Free** is enabled, the model receives **only the current user prompt** (UI history is not sent).
- **No hidden system priming**: system prompt is **nil by default** and **omitted from JSON** when empty.
- **No telemetry / no logs**: no analytics, no crash reporters, no `print`, no `os_log`.
- **Direct networking**: `URLSession` targets `https://openrouter.ai/api/v1` using an **ephemeral** configuration (no cookies/cache).

## Running
1. Open `OpenScienceNative.xcodeproj` in Xcode.
2. Set a signing team (or run unsigned locally as appropriate).
3. Provide your OpenRouter key:
   - Preferred: `OPENROUTER_API_KEY` environment variable (e.g. exported in `~/.zshrc`), or
   - Paste into the in-app key field.

**Key persistence (allowed exception):** the app will store the API key in the **macOS Keychain** so it works when launched from **Finder**, **Xcode**, or **Terminal**. Environment variable still takes precedence when present.

## Notes
- The app **does not** client-side filter or redact content. It renders exactly what the model returns.
- Streaming mode uses Server-Sent Events (SSE). The inspector shows a raw transcript of the stream.


