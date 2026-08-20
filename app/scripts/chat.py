#!/usr/bin/env python3
"""Minimal streaming terminal chat for the local Qwen3.8-27B-NVFP4 vLLM server.

Thinking tokens are rendered dim; the final answer in normal text.
Sampling defaults follow Unsloth's instruct-mode recommendation
(temperature 0.7, top_p 0.8, top_k 20, presence_penalty 1.5).
"""
import argparse


def build_template_kwargs(args):
    if args.no_think:
        return {"enable_thinking": False}
    if args.effort:
        return {"reasoning_effort": args.effort}
    return {}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="localhost")
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--no-think", action="store_true",
                   help="disable thinking mode (direct answers)")
    # "high" is not a level this model's chat template accepts - it 400s.
    p.add_argument("--effort", choices=["low", "medium", "xhigh"],
                   help="reasoning effort for thinking mode")
    p.add_argument("--system", help="optional system prompt")
    p.add_argument("--temperature", type=float, default=0.7)
    args = p.parse_args()

    from openai import OpenAI
    client = OpenAI(base_url=f"http://{args.host}:{args.port}/v1", api_key="local")
    try:
        model = client.models.list().data[0].id
    except Exception:
        raise SystemExit(
            f"No server at http://{args.host}:{args.port} — start it with run.ps1 "
            "(or scripts/serve.sh in WSL) first."
        )

    template_kwargs = build_template_kwargs(args)
    base = [{"role": "system", "content": args.system}] if args.system else []
    messages = list(base)
    print(f"Connected to {model}.  /reset clears history, /quit or Ctrl+C exits.")

    while True:
        try:
            user = input("\nyou > ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not user:
            continue
        if user == "/quit":
            break
        if user == "/reset":
            messages = list(base)
            print("(history cleared)")
            continue

        messages.append({"role": "user", "content": user})
        extra = {"top_k": 20}
        if template_kwargs:
            extra["chat_template_kwargs"] = template_kwargs
        stream = client.chat.completions.create(
            model=model, messages=messages, stream=True,
            temperature=args.temperature, top_p=0.8, presence_penalty=1.5,
            extra_body=extra,
        )

        print("qwen > ", end="", flush=True)
        reply, thinking = [], False
        try:
            for chunk in stream:
                if not chunk.choices:
                    continue
                delta = chunk.choices[0].delta
                # vLLM 0.27.1 calls it `reasoning`; other builds use
                # `reasoning_content`. Reading only one silently drops it.
                reasoning = (getattr(delta, "reasoning", None)
                             or getattr(delta, "reasoning_content", None))
                if reasoning:
                    if not thinking:
                        print("\033[2m", end="")
                        thinking = True
                    print(reasoning, end="", flush=True)
                elif delta.content:
                    if thinking:
                        print("\033[0m\n", end="")
                        thinking = False
                    print(delta.content, end="", flush=True)
                    reply.append(delta.content)
        except KeyboardInterrupt:
            pass
        finally:
            if thinking:
                print("\033[0m", end="")
        print()
        messages.append({"role": "assistant", "content": "".join(reply)})


if __name__ == "__main__":
    main()
