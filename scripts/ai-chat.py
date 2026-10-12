#!/usr/bin/env python3
"""Interactive streaming chat for OpenAI-compatible chat-completions APIs."""

import json
import os
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def endpoint_from_base_url(base_url):
    base_url = base_url.rstrip("/")
    if base_url.endswith("/chat/completions"):
        return base_url
    return f"{base_url}/chat/completions"


def stream_reply(endpoint, model, api_key, messages):
    payload = json.dumps(
        {"model": model, "messages": messages, "stream": True}
    ).encode()
    headers = {"Content-Type": "application/json", "Accept": "text/event-stream"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = Request(endpoint, data=payload, headers=headers, method="POST")

    try:
        response = urlopen(request, timeout=300)
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"API returned HTTP {error.code}: {detail}") from error
    except (URLError, TimeoutError) as error:
        raise RuntimeError(f"Could not connect to the API: {error}") from error

    answer = []
    with response:
        for raw_line in response:
            line = raw_line.decode("utf-8", errors="replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                event = json.loads(data)
            except json.JSONDecodeError as error:
                raise RuntimeError(f"API returned invalid stream data: {data}") from error

            if "error" in event:
                raise RuntimeError(f"API error: {event['error']}")
            choices = event.get("choices") or []
            if not choices:
                continue
            content = choices[0].get("delta", {}).get("content", "")
            if isinstance(content, list):
                content = "".join(
                    part.get("text", "")
                    for part in content
                    if isinstance(part, dict)
                )
            if content:
                print(content, end="", flush=True)
                answer.append(content)
    print()
    return "".join(answer)


def main():
    base_url = os.environ.get("AI_BASE_URL", "").strip()
    model = os.environ.get("AI_MODEL", "").strip()
    if not base_url or not model:
        print("ai-chat: set AI_BASE_URL and AI_MODEL, or start chat with `ai`", file=sys.stderr)
        return 2

    endpoint = endpoint_from_base_url(base_url)
    api_key = os.environ.get("AI_API_KEY", "")
    messages = []
    print(f"Chatting with {model} at {base_url}. Use /clear or /exit.")

    while True:
        try:
            prompt = input("you> ")
        except EOFError:
            print()
            return 0
        except KeyboardInterrupt:
            print("\nExiting chat.")
            return 0

        prompt = prompt.strip()
        if not prompt:
            continue
        if prompt in {"/exit", "/quit"}:
            return 0
        if prompt == "/clear":
            messages.clear()
            print("Conversation cleared.")
            continue

        updated_messages = messages + [{"role": "user", "content": prompt}]
        print("assistant> ", end="", flush=True)
        try:
            answer = stream_reply(endpoint, model, api_key, updated_messages)
        except (OSError, RuntimeError) as error:
            print(f"\nai-chat: {error}", file=sys.stderr)
            continue
        messages = updated_messages + [{"role": "assistant", "content": answer}]


if __name__ == "__main__":
    raise SystemExit(main())
