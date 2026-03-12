# ChatAPI

**A hyper-secure, privacy-first macOS app for auditing LLM behavior via OpenRouter.**

ChatAPI is a native SwiftUI "clean room" scientific instrument designed for researchers, developers, and the deeply curious who want to observe exactly what a large language model says — with zero interference, zero logging, and zero data persistence.

---

## Why ChatAPI Exists

Most LLM chat interfaces quietly shape the conversation — adding system prompts, storing history, injecting context, phoning home with analytics. ChatAPI strips all of that away. What you get is a direct, unmediated line to any model on OpenRouter, running inside a macOS app that forgets everything the moment you close it.

If you want to study how models behave when nothing is whispering in their ear, this is the tool.

---

## Security Guarantees (by Design)

| Guarantee | How |
|---|---|
| **Zero persistence** | No CoreData, no SQLite, no UserDefaults — all state lives in RAM only |
| **Stateless by default** | With *Context Free* enabled, the model receives only the current prompt (UI history is never sent) |
| **No hidden system priming** | System prompt is `nil` by default and omitted from the JSON payload when empty |
| **No telemetry** | No analytics, no crash reporters, no `print`, no `os_log` |
| **Direct networking** | `URLSession` with an ephemeral configuration targets OpenRouter directly — no cookies, no cache |

---

## Features

- **Model switching** — Choose from any model available on OpenRouter
- - **Streaming responses** — Real-time token delivery via Server-Sent Events (SSE)
  - - **Context Free mode** — Send only the current message, no conversation history
    - - **Custom system prompts** — Or leave blank for truly unprimed model behavior
      - - **Stream inspector** — View the raw SSE transcript as tokens arrive
        - - **Keychain-backed API key** — Stored securely in the macOS Keychain so it works whether launched from Finder, Xcode, or Terminal
         
          - ---

          ## Getting Started

          ### Prerequisites

          - macOS 13+ (Ventura)
          - - Xcode 15+
            - - An [OpenRouter](https://openrouter.ai) API key
             
              - ### Running
             
              - 1. Open `ChatAPI.xcodeproj` in Xcode
                2. 2. Set a signing team (or run unsigned locally)
                   3. 3. Provide your OpenRouter API key via one of:
                      4.    - **Environment variable** (preferred): `export OPENROUTER_API_KEY="sk-or-..."` in `~/.zshrc`
                            -    - **In-app key field**: Paste directly into the app — it will be stored in the macOS Keychain for persistence across launches
                             
                                 - > The environment variable takes precedence when both are present.
                                   >
                                   > ---
                                   >
                                   > ## Tech Stack
                                   >
                                   > | Layer | Technology |
                                   > |---|---|
                                   > | UI | SwiftUI |
                                   > | Language | Swift 5.9+ |
                                   > | Networking | URLSession (ephemeral) |
                                   > | Streaming | Server-Sent Events (SSE) |
                                   > | Key Storage | macOS Keychain |
                                   > | AI Backend | OpenRouter API |
                                   >
                                   > ---
                                   >
                                   > ## Project Structure
                                   >
                                   > ```
                                   > ChatAPI/
                                   > ├── ChatAPI.xcodeproj     # Xcode project
                                   > └── ChatAPI/
                                   >     ├── Models/            # Data models
                                   >     ├── Resources/         # App resources
                                   >     ├── Security/          # Keychain & security utilities
                                   >     ├── Services/          # API client, networking
                                   >     ├── ViewModels/        # MVVM view models
                                   >     ├── Views/             # SwiftUI views
                                   >     ├── AppDelegate.swift  # App lifecycle
                                   >     └── ChatAPIApp.swift   # Entry point
                                   > ```
                                   >
                                   > ---
                                   >
                                   > ## Notes
                                   >
                                   > - The app does **not** client-side filter or redact content — it renders exactly what the model returns
                                   > - - Streaming mode uses Server-Sent Events for real-time token delivery
                                   >   - - The inspector shows a raw transcript of the SSE stream for full transparency
                                   >    
                                   >     - ---
                                   >
                                   > ## License
                                   >
                                   > Proprietary. All rights reserved.
                                   >
                                   > ---
                                   >
                                   > *ChatAPI: See exactly what the model says — nothing more, nothing less.*
