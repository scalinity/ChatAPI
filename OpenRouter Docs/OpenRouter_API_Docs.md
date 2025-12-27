# OpenRouter API Documentation

## Complete Reference for AI Coding Agents

### 1. Overview

#### 1.1 Architectural Purpose and Design Philosophy

In the rapidly evolving landscape of artificial intelligence, the fragmentation of model providers presents a significant integration challenge for developers and autonomous agents. OpenRouter functions as a high-performance normalization layer and routing engine, designed to unify access to a diverse ecosystem of Large Language Models (LLMs). For AI coding agents, this infrastructure is critical: it abstracts away the complexity of managing dozens of disparate API schemas, authentication protocols, and billing interfaces into a single, standardized endpoint.

The platform is not merely a passive proxy but an active routing service that optimizes for cost, performance, and reliability. By adhering to a request and response schema that mirrors the OpenAI Chat Completion API, OpenRouter ensures high compatibility with existing tooling while extending functionality through proprietary features such as "Bring Your Own Key" (BYOK) architectures, granular routing preferences, and unified credit management. This design philosophy prioritizes **interoperability**, allowing applications to switch seamlessly between proprietary models like GPT-4o and open-weight models like Llama 3 or Mixtral without requiring codebase refactoring.

#### 1.2 Core Capabilities and Feature Set

OpenRouter differentiates itself through a robust set of features engineered for production-grade AI applications.

- **Unified Schema Normalization**: The API enforces a strict normalization of requests and responses. Regardless of whether the underlying provider is Azure, DeepInfra, Fireworks, or Anthropic, the client application interacts with a consistent JSON schema. This eliminates the need for provider-specific adapter logic within the client.

- **Intelligent Routing and Fallbacks**: The platform implements sophisticated routing logic that goes beyond simple load balancing. Clients can define complex fallback chains, prioritize providers based on latency or throughput, and set price ceilings. This ensures that if a primary provider experiences downtime or rate limiting, the request is automatically rerouted to a healthy alternative without service interruption.

- **Marketplace Economics and Competition**: OpenRouter aggregates multiple providers for the same model, creating a competitive marketplace. For instance, a request for `meta-llama/llama-3-70b-instruct` might be served by DeepInfra, Fireworks, or Together AI. The API allows users to automatically route to the lowest-cost provider at any given moment, optimizing operational expenses dynamically.

- **Structured Outputs and Reliability**: To support agentic workflows that require precise data entry, the API supports Structured Outputs. This feature enforces JSON Schema validation on model responses, ensuring that outputs are machine-parseable and type-safe, which is essential for chaining complex logic.

- **Standardized Error Handling**: Error responses are normalized into a consistent format, allowing agents to implement uniform retry strategies and error logging mechanisms regardless of the origin of the failure.

#### 1.3 Strategic Use Cases

The versatility of the OpenRouter API supports a wide range of implementation patterns.

- **Multi-Model Agent Architectures**: Complex agents can leverage the API to dynamically switch between "fast" models (e.g., Haiku, Llama 3 8B) for initial reasoning or filtering tasks and "strong" models (e.g., GPT-4o, Opus) for final generation. This tiered approach optimizes both latency and cost.

- **Resilient Production Systems**: For applications where uptime is non-negotiable, the automatic fallback capability provides a layer of resilience against single-provider outages. If OpenAI is unreachable, traffic can instantly shift to Azure or another aggregator hosting the same model.

- **Unified Model Evaluation**: Researchers and developers can utilize the API to run identical prompts across hundreds of models to benchmark performance. This capability is facilitated by the single integration point, removing the overhead of maintaining dozens of separate SDKs.

---

### 2. Authentication

Authentication within the OpenRouter ecosystem is designed to be secure, flexible, and supportive of both direct API usage and third-party application integrations. The platform utilizes standard Bearer token authentication while also supporting advanced OAuth flows for user-centric applications.

#### 2.1 API Key Generation and Management

Access to the OpenRouter API requires a valid API key, which serves as the primary credential for identifying the calling account and authorizing resource usage. Keys are generated via the OpenRouter dashboard and are displayed only once upon creation for security reasons. A typical key follows the format `sk-or-v1-...`, allowing for easy regex validation in client applications.

It is a critical security best practice to manage these keys via environment variables rather than hardcoding them into source repositories. OpenRouter keys also support credit limits, allowing developers to set strict spending caps. This feature is particularly vital for autonomous agents operating in loops, preventing accidental credit drain due to runaway processes.

#### 2.2 Authentication Headers and App Attribution

Every API request must include the `Authorization` header containing the API key. Beyond basic access, OpenRouter implements a unique system of "App Attribution" headers. These optional but recommended headers allow developers to identify their applications to the platform. By providing a site URL and a name, applications can gain visibility on OpenRouter's leaderboards and usage rankings.

**Required and Recommended Headers:**

| Header | Required | Description |
|--------|----------|-------------|
| `Authorization` | Yes | Bearer token with API key |
| `Content-Type` | Yes | Must be `application/json` |
| `HTTP-Referer` | Recommended | Attribution URL for your app |
| `X-Title` | Recommended | Attribution name for your app |

**Code Example: Header Configuration (Python)**

```python
import os

api_key = os.getenv("OPENROUTER_API_KEY")

headers = {
    "Authorization": f"Bearer {api_key}",
    "HTTP-Referer": "https://github.com/my-org/coding-agent",  # Attribution URL
    "X-Title": "Autonomous Coding Agent v1",                    # Attribution Name
    "Content-Type": "application/json"
}
```

#### 2.3 OAuth and PKCE for Third-Party Integration

For applications that act as platforms themselves—allowing end-users to bring their own OpenRouter accounts—the API supports a standard OAuth 2.0 flow with Proof Key for Code Exchange (PKCE). This mechanism ensures that the application never needs to handle or store the user's long-term API keys directly, significantly reducing the security surface area.

The flow involves redirecting the user to OpenRouter's authorization URL with a generated `code_challenge`. Upon successful login and authorization by the user, OpenRouter redirects back to the application with a temporary code. This code is then exchanged via a server-side POST request to `https://openrouter.ai/api/v1/auth/keys` to obtain a user-controlled API key.

**OAuth Flow Parameters:**
- `callback_url`: The URL where the user is returned after authorization.
- `code_challenge`: A secure random string (hashed) used to verify the request.
- `code_challenge_method`: typically `S256`.

---

### 3. API Endpoints

The OpenRouter API is versioned to ensure stability. The current stable base URL for all endpoints is `https://openrouter.ai/api/v1`. The API surface is concise, focusing on chat completions, model discovery, and account management.

#### 3.1 Chat Completions

- **Endpoint**: `/chat/completions`
- **Method**: `POST`
- **Functionality**: This is the core endpoint for all generation tasks. It accepts a conversation history and configuration parameters, returning a text or code completion. It is designed to be a drop-in replacement for the OpenAI Chat API, facilitating easy migration.
- **Usage**: Used for text generation, code completion, reasoning tasks, and tool invocation.

#### 3.2 Models Discovery

- **Endpoint**: `/models`
- **Method**: `GET`
- **Functionality**: Returns a dynamic list of all available models supported by the platform. The response is rich in metadata, providing details on pricing (per token), context window size, architecture (modalities, tokenizer), and specific capabilities like tool support or structured outputs.
- **Usage**: Agents should query this endpoint periodically to discover new models or update pricing configurations.

#### 3.3 Model Endpoints Status

- **Endpoint**: `/models/{model_id}/endpoints`
- **Method**: `GET`
- **Functionality**: Provides granular details about the specific providers (endpoints) available for a given model. This includes real-time data on uptime, latency, and throughput for each provider, which is critical for making informed routing decisions manually if needed.

#### 3.4 Generation Stats and Costing

- **Endpoint**: `/generation`
- **Method**: `GET`
- **Functionality**: Retrieves precise accounting data for a completed request. While the standard response includes token counts, they are normalized. This endpoint returns the *native* token usage and exact cost in USD for a specific generation ID, ensuring accurate billing reconciliation.
- **Parameters**: Requires the `id` of the generation (returned in the completion response).

#### 3.5 Key Verification and Limits

- **Endpoint**: `/auth/key`
- **Method**: `GET`
- **Functionality**: Allows an agent to introspect its own API key. The response includes details on the credit limit, remaining credits, and any rate limit caps (e.g., for free tier usage). This allows agents to self-regulate and warn users before credits are exhausted.

---

### 4. Request Format

The request structure for OpenRouter is a superset of the standard OpenAI API. While it maintains backward compatibility with standard parameters like `messages` and `temperature`, it introduces a powerful `provider` object that exposes OpenRouter's unique routing and orchestration capabilities.

#### 4.1 Request Headers

As detailed in the Authentication section, the `Authorization` header is mandatory. The `Content-Type` must always be set to `application/json`.

#### 4.2 Request Body Schema

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | Yes | Model identifier (e.g., `openai/gpt-4o`) |
| `messages` | array | Yes | Conversation history |
| `max_tokens` | integer | No | Maximum tokens to generate |
| `temperature` | float | No | Sampling temperature (0-2) |
| `top_p` | float | No | Nucleus sampling parameter |
| `stream` | boolean | No | Enable streaming responses |
| `tools` | array | No | Function/tool definitions |
| `provider` | object | No | OpenRouter routing preferences |

#### 4.3 Message Object Structure

The `messages` array is the core of the context. Each object within the array must contain a `role` and `content`.

- **`role`**: One of `system`, `user`, `assistant`, or `tool`.
- **`content`**: The actual text of the message. For multimodal models (e.g., GPT-4o, Claude 3.5 Sonnet), this can be an array of content parts, including text and image URLs (base64 or remote).

#### 4.4 Advanced Provider Routing (`provider` object)

The `provider` object is the mechanism by which developers leverage OpenRouter's aggregation capabilities. It allows for fine-grained control over which provider serves the request.

- **`order`** (array): An explicit list of provider slugs. If specified, OpenRouter will attempt these providers in the exact order listed, bypassing the default load balancing logic.
- **`sort`** (string): Defines the sorting strategy for provider selection. Options include:
  - `price`: Route to the cheapest available provider
  - `latency`: Route to the fastest provider
  - `throughput`: Route to the provider with highest capacity
- **`allow_fallbacks`** (boolean): Whether to allow automatic fallback to other providers if the primary fails.
- **`require_parameters`** (boolean): Only route to providers that support all requested parameters.
