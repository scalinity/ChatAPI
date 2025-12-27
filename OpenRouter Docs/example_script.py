import os
import requests

# =========================
# CONFIGURATION
# =========================

OPENROUTER_API_KEY = os.environ["OPENROUTER_API_KEY"]
API_URL = "https://openrouter.ai/api/v1/chat/completions"

# =========================
# REQUEST PAYLOAD
# =========================

payload = {
    "model": "google/gemini-3-flash-preview",

    # ---- INPUT ----
    "messages": [
        {
            "role": "user",
            "content": (
                "Provide a deep, technical, academically rigorous analysis of the following topic. "
                "Do not simplify. Do not optimize for readability. "
                "Prioritize correctness, completeness, and theoretical depth.\n\n"
                "TOPIC: [REPLACE WITH YOUR RESEARCH QUESTION]"
            )
        }
    ],

    # ---- OUTPUT CAPACITY ----
    "max_tokens": 8192,

    # ---- SAMPLING ----
    "temperature": 0.7,
    "top_p": 0.98,
    "top_k": 40,

    # ---- REPETITION CONTROL ----
    "frequency_penalty": 0.0,
    "presence_penalty": 0.0,
    "repetition_penalty": 1.0,

    # ---- REASONING / THINKING ----
    "reasoning": {
        "enabled": True,
        "effort": "high",
        "exclude": False
    },

    # ---- STREAMING ----
    "stream": True
}

# =========================
# HEADERS
# =========================

headers = {
    "Authorization": f"Bearer {OPENROUTER_API_KEY}",
    "Content-Type": "application/json"
}

# =========================
# EXECUTION
# =========================

response = requests.post(
    API_URL,
    headers=headers,
    json=payload,
    timeout=300
)

response.raise_for_status()
data = response.json()

# =========================
# OUTPUT
# =========================

print(data["choices"][0]["message"]["content"])
