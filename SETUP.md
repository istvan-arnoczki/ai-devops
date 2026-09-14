# Local DevOps AI Setup (llama.cpp only)

One local model — reasoning enabled, docs-first, internet-second, no
offline doc store — served by **llama.cpp via llama-swap**, used from
**Open WebUI** (browser), **sgpt** (CLI), and **VS Code** (Continue
extension). Answers from Open WebUI are grounded in live web search
(tagged `[DOCS]`/`[WEB]`, with URL + quote); `sgpt` uses the same model
weights but an honestly-adapted prompt, since it can't execute tools —
more on that in Part 1.7.

---

# Part 0 — Prerequisites

## 0.1 Folder layout

```
your-project/
├── docker-compose.yml
└── data/
    ├── open-webui/        (created automatically on first `up`)
    ├── searxng/           (created automatically on first `up`)
    ├── llama-swap/        (create config.yaml here BEFORE first `up`)
    └── llama-cpp/models/  (HF model cache)
```

## 0.2 GPU passthrough

### Install the NVIDIA driver and Container Toolkit

**Install the NVIDIA driver on Windows itself, not inside WSL** — WSL2
picks up the Windows-side driver automatically. Grab the latest driver
from `https://www.nvidia.com/drivers` if you haven't already.

Inside your WSL2 Ubuntu shell, install the **NVIDIA Container Toolkit**,
which is what lets Docker containers actually see the GPU:

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update
sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo service docker restart
```

`nvidia-ctk runtime configure` is the step that actually wires the
toolkit into Docker's runtime config — skipping it is the most common
reason `--gpus all` fails with a runtime error on an otherwise correctly
installed toolkit.

### Confirm it works

```bash
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

This must show your GPU. The compose file below uses the `gpus: all`
Compose shorthand (2.3+) — **not** `deploy.resources.reservations.devices`,
which is officially valid per the Compose spec but is known to be
silently ignored outside Swarm mode on some Compose versions: it parses
without error, but the container never actually gets the GPU, and
inference silently falls back to full CPU with the GPU sitting idle. If
you ever see high CPU / growing system RAM / idle GPU despite `nvidia-smi`
working standalone, see **Appendix B**.

## 0.3 SearXNG (powers the `[WEB]`/`[DOCS]` web search fallback)

```yaml
  searxng:
    image: searxng/searxng:latest
    container_name: searxng
    ports:
      - "8888:8080"
    volumes:
      - ./data/searxng:/etc/searxng
    environment:
      - SEARXNG_BASE_URL=http://localhost:8888/
      - UWSGI_WORKERS=2
      - UWSGI_THREADS=2
    restart: unless-stopped
```

**One-time config fix required** — SearXNG only enables HTML output by
default; the JSON format Open WebUI needs must be added by hand:

```bash
docker compose up -d searxng   # let it generate the initial file first
cat ./data/searxng/settings.yml
```

Edit `./data/searxng/settings.yml`:

```yaml
# Read the documentation before extending the defaults:
# https://docs.searxng.org/admin/settings/

use_default_settings: true

server:
  secret_key: "REPLACE-WITH-A-REAL-RANDOM-KEY"
  image_proxy: true
  limiter: false

search:
  formats:
    - html
    - json
```

Generate a real secret key:
```bash
openssl rand -hex 32
```

Restart and verify:
```bash
docker compose restart searxng
curl "http://localhost:8888/search?q=test&format=json"
```
You should get a JSON body starting with `{"query": "test", ...}`, not
`<!DOCTYPE html>`.

## 0.4 Two different model lists in Open WebUI — don't confuse them

**The chat dropdown** (top of a chat window) lists the raw model
(`assistant`) directly from the llama-swap connection. **Workspace →
Models** only lists custom models you've explicitly built via the `+`
flow — it's a page for saved presets (system prompt + params bundled
together), not a catalog of every model a connection exposes.

**This matters practically**: if you pick the raw `assistant` model
straight from the chat dropdown instead of your custom
`DevOps Assistant (docs-first)` model, you get **no system prompt at
all** — no `[DOCS]`/`[WEB]` tagging, no reasoning-first behavior, none of
Appendix A's rules. It'll still generate answers, just without any of the
grounding this setup is for. Always select your custom model for actual
use.

---

# Part 1 — llama.cpp + llama-swap

## 1.1 Installing llama.cpp itself

**No separate install step needed.** The
`ghcr.io/mostlygeek/llama-swap:unified-cuda13` image already contains a
CUDA-compiled `llama-server` binary — llama-swap's whole job is spawning
and managing that binary. Confirm it's there once the container is up:
```bash
docker exec -it llama-swap llama-server --version
```

**Optional native build**, only if you want direct access to llama.cpp's
own CLI tools (`llama-bench`, `llama-quantize`, `llama-cli`). Needs the
actual CUDA *toolkit* (`nvcc`) inside WSL, not just the Windows driver:
```bash
wget https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update
sudo apt-get install -y cuda-toolkit-13-0   # match your driver's reported CUDA version
sudo apt-get install -y git cmake build-essential

git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j$(nproc)
./build/bin/llama-server --version
```
A separate binary from the one inside Docker — handy for testing, doesn't
replace the containerized setup below.

## 1.2 Full docker-compose.yml

```yaml
services:
  searxng:
    image: searxng/searxng:latest
    container_name: searxng
    ports:
      - "8888:8080"
    volumes:
      - ./data/searxng:/etc/searxng
    environment:
      - SEARXNG_BASE_URL=http://localhost:8888/
      - UWSGI_WORKERS=2
      - UWSGI_THREADS=2
    restart: unless-stopped

  llama-swap:
    image: ghcr.io/mostlygeek/llama-swap:unified-cuda13
    container_name: llama-swap
    gpus: all
    ports:
      - "8090:8080"
    volumes:
      - ./data/llama-swap/config.yaml:/config/config.yaml
      - ./data/llama-cpp/models:/root/.cache/huggingface
    environment:
      - LLAMA_SWAP_CONFIG=/config/config.yaml
      - LLAMA_SWAP_LISTEN=0.0.0.0:8080
      - LLAMA_SWAP_WATCH_CONFIG=true
    restart: unless-stopped

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    ports:
      - "3000:8080"
    volumes:
      - ./data/open-webui:/app/backend/data
    environment:
      - ENABLE_RAG_WEB_SEARCH=true
      - RAG_WEB_SEARCH_ENGINE=searxng
      - SEARXNG_QUERY_URL=http://searxng:8080/search?q=<query>&format=json
      - RAG_WEB_SEARCH_RESULT_COUNT=4
      - RAG_WEB_SEARCH_CONCURRENT_REQUESTS=4
    depends_on:
      - llama-swap
      - searxng
    restart: unless-stopped
```

Notes:
- `gpus: all` — see 0.2. Confirm with
  `docker exec -it llama-swap nvidia-smi` after `up`.
- The `unified-cuda13` tag matches a CUDA 13.x driver — check your own
  `nvidia-smi` output; if it reports CUDA 12.x, use the matching
  `unified-cuda12` tag from `https://github.com/mostlygeek/llama-swap`.
- `RAG_WEB_SEARCH_RESULT_COUNT=4` (not higher) is deliberate — more
  snippets in context increases the chance the model cross-wires which
  URL belongs to which claim, producing fabricated citations.

**Create the config file on the host before your first `up` for this
service** — Docker bind-mounts a source path that doesn't exist yet as a
*directory*, not a file. If `./data/llama-swap/config.yaml` isn't already
a real file when the container first starts, you'll get a directory of
that name instead, and nothing you write afterward lands where llama-swap
actually reads from:
```bash
mkdir -p ./data/llama-swap ./data/llama-cpp/models
touch ./data/llama-swap/config.yaml
```

## 1.3 Bring up SearXNG and llama-swap

```bash
docker compose up -d searxng llama-swap
docker exec -it llama-swap nvidia-smi   # confirm GPU is visible
```

## 1.4 config.yaml — reasoning model, sgpt's fast model, and autocomplete

`./data/llama-swap/config.yaml`:

```yaml
healthCheckTimeout: 180
logLevel: info

models:
  "assistant":
    cmd: |
      llama-server
      -hf Qwen/Qwen3-14B-GGUF:Q4_K_M
      --port ${PORT}
      --host 0.0.0.0
      --ctx-size 16384
      --n-gpu-layers 99
      --flash-attn on
      --cache-type-k q8_0
      --cache-type-v q8_0
      --jinja
      --temp 0.6
      --top-p 0.95
      --top-k 20
    ttl: 300

  "quick":
    cmd: |
      llama-server
      -hf Qwen/Qwen2.5-Coder-7B-Instruct-GGUF:Q4_K_M
      --port ${PORT}
      --host 0.0.0.0
      --ctx-size 8192
      --n-gpu-layers 99
      --flash-attn on
      --cache-type-k q8_0
      --cache-type-v q8_0
    ttl: 300

  "autocomplete":
    cmd: |
      llama-server
      -hf Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M
      --port ${PORT}
      --host 0.0.0.0
      --ctx-size 4096
      --n-gpu-layers 99
      --flash-attn on
    ttl: 300

groups:
  "concurrent":
    swap: false
    exclusive: false
    members:
      - "assistant"
      - "autocomplete"
```

Notes:
- `Qwen3-14B` fits fully in 12GB VRAM (~9GB at Q4_K_M), has native/
  reliable tool-calling support, and supports Qwen3's hybrid thinking
  mode — the combination the Open WebUI setup depends on.
- `--jinja` is required for correct chat-template/tool-call formatting —
  without it, the web-search flow is likely to break or degrade.
- `--flash-attn` needs an explicit value (`on`/`off`/`auto`) on this
  build — a bare `--flash-attn` flag makes `llama-server` exit
  immediately with an argument error before ever loading the model. If
  `docker logs llama-swap` shows `process exited: code=1` with almost no
  elapsed time, this is the first thing to check.
- `--temp 0.6 --top-p 0.95 --top-k 20` on `assistant` is Qwen's own
  recommended sampling profile **for thinking mode specifically** — low
  temperature actively degrades thinking-mode output (causes repetition
  or getting stuck), so this isn't a stylistic choice, it's required
  given reasoning is always on for that model.
- Thinking mode itself is controlled by `/think` in the system prompt
  (Appendix A), not a CLI flag — there isn't one. `quick` and
  `autocomplete` have no `/think` and no thinking-tuned sampling.
- `quick` is only wired into `sgpt`, not Open WebUI or VS Code — a
  CLI-speed accommodation for when `/think`'s latency is more than you
  want for a quick terminal lookup.
- `autocomplete` (`Qwen2.5-Coder-1.5B-Instruct`) is Continue's own current
  documented recommendation for local autocomplete (confirmed across
  multiple current `docs.continue.dev` pages) — not `starcoder2:3b`,
  which was an older recommendation from an earlier version of their
  docs. It's small (~0.9GB at Q4_K_M) and, per Qwen's own model card,
  retains strong fill-in-the-middle capability despite being the
  instruct-tuned variant. It's only wired into VS Code's `autocomplete`
  role (1.8), not `sgpt` or Open WebUI.
- **`Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF`** is the official Qwen org
  GGUF repo — verified directly against Qwen's own quickstart README, not
  a third-party conversion, so no build-recency/pre-tokenizer concerns
  like the earlier `starcoder2-3b` situation.
- **The `groups` block is what keeps `assistant` and `autocomplete`
  loaded simultaneously** instead of llama-swap's default swap-on-demand
  behavior — without it, every autocomplete keystroke after a chat
  message (or vice versa) would trigger a multi-second reload, which is
  a genuinely bad experience for something that's supposed to feel
  instant. `quick` is deliberately left out of the group — it's only
  used interactively via `sgpt`, never alongside the other two in the
  same moment, so it doesn't need to coexist in VRAM with them.
- **VRAM math is comfortable here**, unlike the earlier `starcoder2-3b`
  estimate — roughly ~10–11GB for `assistant` plus ~1.2–1.5GB for
  `autocomplete` (a 1.5B model, not 3B) on a 12GB card. Worth confirming
  for real anyway (`docker exec -it llama-swap nvidia-smi` while both are
  loaded) rather than fully trusting the estimate, but the margin is
  meaningfully better than the earlier model choice. If it's ever tight,
  lower `assistant`'s `--ctx-size` from `16384` toward `12288` first —
  biggest single lever, trims KV cache directly.

Apply:
```bash
docker compose up -d llama-swap
```

## 1.5 Pre-warm all three models before using them

**Models download lazily on first generation request, not at container
startup.** The first request simultaneously spawns the process,
downloads the GGUF from Hugging Face, loads it into VRAM, then generates
— which commonly exceeds Open WebUI's or llama-swap's own
`healthCheckTimeout` and shows up as a generic error rather than an
obvious "still downloading" message. Pre-warm all three once:
```bash
docker exec -it llama-swap llama-server -hf Qwen/Qwen3-14B-GGUF:Q4_K_M --port 9999
docker exec -it llama-swap llama-server -hf Qwen/Qwen2.5-Coder-7B-Instruct-GGUF:Q4_K_M --port 9999
docker exec -it llama-swap llama-server -hf Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M --port 9999
```
Let each run until you see a "server listening" message, then `Ctrl+C`.
The GGUF files are now cached under `./data/llama-cpp/models` —
subsequent loads read from local disk in seconds, regardless of which
model llama-swap is asked to swap to.

## 1.6 Connect Open WebUI

llama-swap speaks the OpenAI-compatible API, connect it as a generic
provider through the Admin UI (more version-stable than guessing at env
var names):

**Admin Settings → Connections → Add Connection → OpenAI API**
- **Base URL**: `http://llama-swap:8080/v1`
- **API Key**: any non-empty placeholder, e.g. `sk-local-no-auth`.
- Save, confirm `assistant` appears as a selectable model.

**Create the docs-first custom model manually** (not via JSON import —
Open WebUI's import schema isn't stable/documented enough to hand-craft
reliably; manual creation always matches whatever your version actually
expects):

**Workspace → Models → `+`**
- **Name**: `DevOps Assistant (docs-first)`
- **Base Model**: `assistant`
- **System Prompt**: the full prompt from **Appendix A**.
- **Advanced Params**: `temperature 0.6`, `top_p 0.95`, `top_k 20`,
  `repeat_penalty 1`, `num_ctx 16384`, `Function Calling: Native`.
- **Capabilities**: see the checklist in **Appendix A.1** — pay
  particular attention to the Web Search note there, it appears in three
  separate places in the UI and only one of them actually matters for
  native tool-calling.

## 1.7 Connect sgpt

**Important distinction before you set this up**: `sgpt` is a raw
completion client — it has no mechanism to execute a tool call the way
Open WebUI does. If you gave it the exact same system prompt (which
claims "you have a web search tool"), the model may still attempt to
emit a tool-call-formatted response, and since nothing on the `sgpt` side
executes it, you'd likely see garbled tool-call JSON printed to your
terminal instead of a real answer. So `sgpt` uses the **same model
weights**, via a **separate, honestly-adapted role** that doesn't claim
tool access it can't use.

```bash
pip install shell-gpt --break-system-packages
mkdir -p ~/.config/shell_gpt
cat > ~/.config/shell_gpt/.sgptrc << 'EOF'
API_BASE_URL=http://localhost:8090/v1
OPENAI_API_KEY=sk-local-no-auth
DEFAULT_MODEL=assistant
CHAT_CACHE_LENGTH=100
CHAT_CACHE_PATH=/tmp/shell_gpt/chat_cache
CACHE_LENGTH=100
CACHE_PATH=/tmp/shell_gpt/cache
REQUEST_TIMEOUT=60
DEFAULT_COLOR=magenta
CODE_THEME=dracula
DISABLE_STREAMING=false
PRETTIFY_MARKDOWN=true
SHELL_INTERACTION=true
OS_NAME=auto
SHELL_NAME=auto
EOF
```
`API_BASE_URL` must be in this file, not just an environment variable —
shell-gpt doesn't read `OPENAI_API_BASE`-style env vars for this, and
setting only env vars silently falls through to OpenAI's real endpoint
and fails with a 401.

`CODE_THEME` controls syntax-highlighting colors for rendered code blocks
(standard Pygments theme names — `dracula`, `monokai`, `github-dark`,
etc.), separate from `DEFAULT_COLOR`'s flat text color. Note that
markdown/syntax-highlight rendering depends on the *role's* type, not
just `PRETTIFY_MARKDOWN` — a custom role can suppress it regardless of
this setting, which is why every `--role` example below includes an
explicit `--md` flag to force rendering on.

Create the adapted role interactively (prefer the CLI flow over
hand-writing the role file — same reasoning as avoiding the Open WebUI
JSON import: an undocumented file schema is a worse bet than the
official creation path):
```bash
sgpt --create-role devops
```
When prompted for the role's system prompt, paste **Appendix A.2**
(the sgpt-adapted prompt — no false tool claims, but keeps the
anti-fabrication discipline).

Use it:
```bash
sgpt --role devops --md "explain this renovate.json error: <paste>"
```
Since there's no live search in this context, treat any specific
option/flag name it states as something to verify yourself — the role's
prompt asks it to flag uncertainty explicitly, but a local model's
self-assessment of its own certainty is not fully reliable either.

**For fast lookups where you don't want `/think`'s latency** — override
the model per-call with `--model`, pointing at the lightweight `quick`
entry from `config.yaml` instead of the default `assistant`:
```bash
sgpt --model quick "quick syntax check: does this bash line look right? <paste>"
```
This uses `quick` directly with no role/system prompt at all (plain raw
completion) — appropriate for fast, low-stakes syntax questions, not for
anything where the anti-fabrication discipline in Appendix A.2 actually
matters. If you want `quick` with the same fabrication-discipline prompt
instead of no prompt, create a second role once:
```bash
sgpt --create-role devops-quick
```
paste Appendix A.2 but remove the `/think` line (there's no reasoning
mode to enable on this model), then use:
```bash
sgpt --model quick --role devops-quick --md "..."
```
`DEFAULT_MODEL=assistant` in `.sgptrc` stays as your default for anything
you'd type without a flag — `--model quick` is an explicit, deliberate
opt-out for a single call, not a config-wide switch.

### Give sgpt real web search instead of the honestly-hedged offline prompt

The `devops` role above (Appendix A.2) exists because `sgpt` has no
built-in mechanism to execute a tool call. That's fixable — `shell-gpt`
has a genuine function-calling feature, letting you give it a real
Python function the model can actually invoke. Once this is set up,
`sgpt` gets the same live-search capability as Open WebUI, not just the
same weights.

**Install dependencies:**
```bash
pip install instructor requests --break-system-packages
```

**Create the function file** — `~/.config/shell_gpt/functions/search_web.py`:
```python
import requests
from pydantic import Field
from instructor import OpenAISchema


class Function(OpenAISchema):
    """
    Searches the web via a local SearXNG instance and returns the top
    results (title, URL, snippet) as plain text. Use this whenever you
    need current information, official documentation, or anything you
    cannot answer confidently from training knowledge alone.
    """
    query: str = Field(..., description="The search query to run")

    class Config:
        title = "search_web"

    @classmethod
    def execute(cls, query: str) -> str:
        try:
            resp = requests.get(
                "http://localhost:8888/search",
                params={"q": query, "format": "json"},
                timeout=15,
            )
            resp.raise_for_status()
            data = resp.json()
        except Exception as e:
            return f"Search failed: {e}"

        results = data.get("results", [])[:5]
        if not results:
            return "No results found."

        lines = []
        for r in results:
            title = r.get("title", "")
            url = r.get("url", "")
            content = r.get("content", "")
            lines.append(f"- {title}\n  URL: {url}\n  {content}")
        return "\n\n".join(lines)
```
Note it hits `localhost:8888`, not the Docker-internal `searxng:8080` —
`sgpt` runs on the host, not inside the compose network, same reasoning
as `.sgptrc`'s `API_BASE_URL` pointing at `localhost:8090`.

**Deliberately do not run** `sgpt --install-functions` — that installs
shell-gpt's own default functions, including one that lets the model
execute arbitrary shell commands on your system. That's real command
execution capability, and it's out of scope here for the same reason
Open WebUI's "Terminal" capability is unchecked in Appendix A.1. Only
the search function above goes in.

**Enable function calling** — add to `~/.config/shell_gpt/.sgptrc`:
```
OPENAI_USE_FUNCTIONS=true
SHOW_FUNCTIONS_OUTPUT=true
```
`SHOW_FUNCTIONS_OUTPUT=true` is worth keeping on — it shows you when the
model actually calls `search_web` and what came back, which is exactly
how you'll confirm this is really working rather than silently not
firing.

**Create the real-search role** — same idea as before, but now paste
**Appendix A.3** (functionally the same prompt as Open WebUI's, since the
"no tool access" caveat from A.2 no longer applies):
```bash
sgpt --create-role devops-search
```

**Test it** — this is unverified until you run it for real (I can't
execute `shell_gpt`/`instructor` in my own environment, so treat this as
a first draft to debug against, not a guarantee):
```bash
sgpt --role devops-search --md "what does renovate's managerFilePatterns option do"
```
With `SHOW_FUNCTIONS_OUTPUT=true`, you should see the function call and
its raw SearXNG results printed before the final answer. If it errors
instead:
- A Python traceback naming `instructor` or `pydantic` → likely a version
  mismatch between what's installed and what this schema expects; check
  `pip show instructor` and the current example in shell-gpt's own README
  function-calling section, since the exact base class/decorator pattern
  has shifted across shell-gpt versions before.
- The model responds but never calls the function → confirm
  `OPENAI_USE_FUNCTIONS=true` actually saved, and that `--jinja` is still
  present on the `assistant` model in `config.yaml` (same tool-calling
  requirement as the Open WebUI path).
- `Search failed: ...` in the output → SearXNG isn't reachable at
  `localhost:8888` from the host; re-run the `curl` test from 0.3.

Once this is confirmed working, `--role devops` (A.2) becomes optional —
keep it around as a fallback for if SearXNG or the function ever breaks
and you still want a usable, honestly-hedged CLI assistant in the
meantime.

## 1.8 Connect VS Code (Continue extension)

Install the **Continue** extension, edit `~/.continue/config.yaml`:

```yaml
name: Local DevOps Config
version: 0.0.1
schema: v1
models:
  - name: Local Assistant (llama-swap)
    provider: openai
    model: assistant
    apiBase: http://localhost:8090/v1
    apiKey: sk-local-no-auth
    roles:
      - chat
      - edit

  - name: Local Autocomplete (llama-swap)
    provider: openai
    model: autocomplete
    apiBase: http://localhost:8090/v1
    apiKey: sk-local-no-auth
    roles:
      - autocomplete
    promptTemplates:
      autocomplete: "<|fim_prefix|>{{{prefix}}}<|fim_suffix|>{{{suffix}}}<|fim_middle|>"
```

`autocomplete` now points at `Qwen2.5-Coder-1.5B-Instruct` (1.4) — a
fill-in-the-middle-capable model, not `assistant`. Thinking mode adds a
hidden reasoning trace before every response, which is fine for a chat
question but was actively bad for inline completions needing to feel
instant — that's why `assistant` was deliberately excluded from this role
earlier, and why a second model exists specifically for it rather than
compromising either one. This only works as configured because 1.4's
`groups` block keeps both loaded in VRAM at once — without it, every
completion after a chat message would trigger a multi-second reload.

**The explicit `promptTemplates.autocomplete` block matters, don't skip
it.** Continue normally infers the correct FIM prompt template from the
model name string — but that inference is documented to specifically key
off known Ollama model tags, and our `model:` field here is `autocomplete`
(a llama-swap alias), going through a generic `provider: openai`
connection rather than `provider: ollama`. If that inference doesn't
fire correctly for this setup, completions come back missing their FIM
special tokens entirely — garbled or nonsensical output that looks like
a broken model, when it's actually a template-detection mismatch.
Setting the template explicitly, sourced directly from Continue's own
documented example for this exact model, sidesteps the guesswork
entirely rather than hoping name-based detection works with a
non-Ollama provider.

**Windows note**: on `C:\Users\<user>\.continue\config.yaml` (PowerShell), not
the WSL path, if VS Code isn't connected via Remote-WSL — and double-check
for a stray `config.ts` in the same folder, which can silently override
`config.yaml` for the autocomplete pipeline specifically even when the
chat pipeline reads it fine.

## 1.9 Verify end-to-end

1. In Open WebUI, ask an obscure, version-specific question through the
   `DevOps Assistant (docs-first)` model. Confirm a `[DOCS]` or `[WEB]`
   tag with a real URL appears — not a bare confident answer.
2. Confirm thinking mode is actually engaging (a collapsible reasoning
   block before the answer). If it isn't, re-check that `/think` is
   genuinely the first line of the system prompt.
3. If tool-calling doesn't fire reliably, re-check the SearXNG query URL
   (`&format=json`), confirm `--jinja` is present in `config.yaml`, and
   re-check the three-Web-Search-toggles note in Appendix A.1.
4. Test `sgpt --role devops` with the same kind of question and confirm
   it does **not** print raw tool-call-looking JSON — if it does, the
   adapted role prompt didn't take, re-check `sgpt --list-roles`.

---

# Appendix A — System prompt (Open WebUI, full tool access)

```
/think

You are a DevOps assistant with reasoning enabled. You have a web search tool. You do NOT have a local/offline document store - all documentation lookups happen live via web search.

PRIORITY OFFICIAL DOMAINS (search these first / prefer results from these):
- docs.renovatebot.com
- docs.github.com, cli.github.com
- docs.python.org
- gnu.org/software/bash
- developer.hashicorp.com/terraform, registry.terraform.io
- kubernetes.io/docs, kubectl reference at kubernetes.io/docs/reference/kubectl
- cloud.google.com/docs
- docs.docker.com
- helm.sh/docs
- docs.ansible.com
- terragrunt.gruntwork.io/docs
- argo-cd.readthedocs.io
- prometheus.io/docs, grafana.com/docs
- pre-commit.com
- mikefarah.gitbook.io/yq, jqlang.org
- github.com/getsops/sops, developer.hashicorp.com/vault/docs

RULES, in order, every time:

1. For any factual/technical question, search the web, prioritizing the domains above. Do not answer from prior/training knowledge alone - always search first, even if you think you know the answer, since docs and APIs change.

2. If you find the answer on one of the priority domains: tag the answer [DOCS]. Include the exact page URL, and a short exact quoted snippet (one sentence or less) from the page that supports the claim. Do not paraphrase the quote into something the page didn't say. If you can't produce a real supporting quote + URL, you don't have grounding - don't use the [DOCS] tag.

3. If the priority domains don't have it, search the broader web. Tag that answer [WEB], include the source URL, and still quote the specific supporting snippet where possible.

4. If neither search turns up a supported answer, say so plainly: 'Not found in official documentation or general web search.' Do not guess or fill the gap from memory.

5. Never blend an unsourced claim into a [DOCS] or [WEB] answer. Every distinct factual claim needs its own source. If an answer draws on multiple sources, tag and cite each part separately.

6. Be concise. Quote only the minimum needed to support each claim - do not reproduce large blocks of the source page.

7. When the official docs are ambiguous or you find conflicting info between sources, say so explicitly rather than picking one silently.

8. Only cite a URL if it appears verbatim in the search results returned to you this turn. Never construct, complete, or guess a URL from memory, even if you recognize the site's typical structure or have seen similar URLs during training. If you are not certain a URL is one you actually retrieved this turn, omit the citation and say the specific page could not be confirmed, rather than presenting an unverified URL as a source.

9. Apply the same verbatim standard from rule 8 to configuration option names, command flags, and API field names, not just URLs. Before stating that a specific option/flag/field exists, confirm you can point to it appearing, spelled exactly that way, in the search results returned to you this turn. A plausible-sounding name that fits the tool's naming pattern is not the same as a confirmed one - if you cannot find the exact name in what you retrieved, say so explicitly ("I could not confirm an option with this name") rather than stating one that seems likely.

10. Confirming an option/flag/field name is spelled correctly (rule 9) is not the same as confirming it is the right answer to the question asked. A real option that exists for a different feature or section of the docs is not a valid answer just because the string matches - confirm the documented purpose of the option actually matches what is being asked, not just that the name is real.

11. If the user tells you a previous answer was incorrect, do not simply apologize and offer a new guess. Perform a fresh search, using different search terms than your first attempt, before answering again. If you still cannot confirm a correct answer after the second attempt, say so plainly rather than presenting another unconfirmed guess as if correction alone made it more reliable.

12. When a question involves how two configuration behaviors interact (e.g. whether one setting overrides or adds to another), explicitly state which it is and name the correct option to achieve the user's actual goal, before giving your final answer. Do not stop at restating a single retrieved fact if the practical implication requires combining it with another.

13. Before giving your final answer to a question that requires connecting more than one fact, explicitly write out: (a) each relevant fact you found, with its source, (b) how those facts interact or constrain each other, (c) the practical conclusion or recommendation that follows. Only then give the final answer.

14. You do not have access to scheduling, automation, or recurring-task tools, and must never attempt to call one. If a question seems to ask for monitoring, scheduling, or recurring checks, explain that this is out of scope for you rather than attempting a tool call.
```

## A.1 — Capabilities checklist (Open WebUI)

Your Open WebUI version likely exposes a broad "agent OS" capability set
(Terminal, sub-agents, automations, channels, etc.) beyond what a
docs-first assistant needs. More enabled tools means more chances the
model picks the wrong one — trim aggressively:

**Web Search specifically appears in three separate places, and they are
not the same toggle:**
- **Capabilities → Web Search** — mostly a capability indicator/badge.
- **Default Features → Web Search** — the classic behavior: Open WebUI
  automatically runs a search before every message and injects results
  into context, independent of the model deciding anything.
- **Builtin Tools → Web Search** — registers `web_search` as an actual
  **callable function** for native tool-calling.

With `Function Calling: Native` set, the model needs a real callable
tool — that only comes from **Builtin Tools**. If only the first two are
checked, native mode has nothing to call, and the model will accurately
say it can't access the internet rather than hallucinating — check **all
three**, not just the top two.

**Check:** Web Search (all three locations above), Citations, File
Upload, File Context, Status Updates, Chat History, Time & Calculation,
Files.

**Uncheck:** Terminal (real shell/code execution — meaningful risk, not
needed here), Sub-agents, Task Management, Notes, Channels, Automations,
Notifications, Calendar, Ask User, Code Interpreter (optional later),
Image Generation, Memory (keep lookups stateless/deterministic), Knowledge
Base (no local doc store — this would pull from stored docs instead of
live search), Vision (unless your base model actually supports it).

## A.2 — Adapted system prompt (sgpt, no tool access)

Use this for the `sgpt --create-role devops` prompt (Part 1.7). Same
weights, same reasoning mode, but honest about not having live search —
claiming a tool the client can't execute risks the model emitting
tool-call-formatted text that just prints as garbled output in a
terminal.

```
/think

You are a DevOps assistant. You do NOT have live internet or documentation search access in this session - answer using training knowledge only.

Because you cannot verify current documentation here, apply extra caution:

1. Before stating the name of a specific configuration option, command flag, or API field, consider whether you are genuinely confident it is real versus inferring a plausible-sounding name that fits the tool's naming pattern. If you are not highly confident, say so explicitly rather than stating it as fact.

2. Do not fabricate citations, URLs, or quoted documentation snippets - you have no way to verify them in this session, so never include them.

3. For anything version-specific, recently-changed, or exact-syntax-critical, explicitly recommend the user verify against current official documentation before relying on your answer, rather than presenting it as confirmed.

4. Be concise.
```

---

# Appendix B — WSL / GPU troubleshooting

## B.1 — Silent CPU fallback (GPU idle, high CPU/RAM)

Symptom: `nvidia-smi` works standalone, but the model runs on CPU anyway.
Usually a **WSL2 GPU-passthrough race condition at boot** — WSL's GPU
paravirtualization layer (`/dev/dxg`) can still be settling when the
container starts and probes for CUDA, the probe fails, and it silently
falls back to CPU for that container's whole life.

Fast fix:
```bash
docker compose restart llama-swap
```

Durable fix — wait for the GPU before starting the stack:
```bash
#!/usr/bin/env bash
# start-ai-stack.sh
echo "Waiting for GPU to be ready in WSL..."
until nvidia-smi > /dev/null 2>&1; do
  sleep 2
done
echo "GPU ready, starting stack..."
docker compose up -d
```

## B.2 — WSL virtual network collision on boot

Symptom:
```
wsl: Failed to create virtual network with address range: ... The object already exists.
```
Usually **"Default Switch" and "WSL"** (both Hyper-V virtual switches)
independently recalculating overlapping subnets on boot — check with
elevated PowerShell:
```powershell
Get-VMSwitch
```
Fix, in order of effort:
```powershell
# 1. Restart Windows's Host Network Service - clears stale network state
net stop hns
net start hns
wsl --shutdown
```
```bash
# 2. From WSL, recreate Docker's network cleanly rather than reusing stale state
docker compose down
docker compose up -d
```
```powershell
# 3. Update WSL itself
wsl --update
```
Option 4, mirrored networking mode (`%UserProfile%\.wslconfig`,
`networkingMode=mirrored`), sidesteps this class of problem entirely, but
has an open, unresolved issue on some WSL versions causing Docker
port-binding failures — test in isolation before combining with this
stack.

## B.3 — After a network reset, verify each layer before assuming it's fixed

```bash
ip addr show eth0                          # WSL's own network - must show a real 172.x IP
docker exec -it llama-swap curl http://localhost:8080/v1/models
docker exec -it open-webui curl http://llama-swap:8080/v1/models   # container-to-container
docker compose ps                          # all should show "Up", not "Restarting"/"Exited"
```
If Open WebUI shows the configured model but it's not selectable, this is
almost always a stale connection to llama-swap, not a missing model — try
`docker compose restart open-webui` and a hard browser refresh before
assuming something is actually broken.

## B.4 — Fabricated citations (a model states a URL that 404s)

Not a network problem — LLMs regenerate text token-by-token rather than
literally copying from tool output, so a model can blend a real domain
with a *predicted, plausible-but-wrong* path, especially for well-known
doc sites it saw heavily in training. Smaller/quantized local models do
this more than large frontier models; it won't fully go away with
prompting alone (rule 8 in Appendix A helps, doesn't eliminate it).
**Don't trust the URL in the response text** — check Open WebUI's
citations panel (source cards/footnotes under a response) instead; that's
generated from the actual raw search results, not typed by the model.

## B.5 — llama.cpp doesn't show tokens/sec in logs

Possibly a known regression in recent `llama-server` builds (GitHub issue
#15865) where console/web timing display broke starting around build
`b6399`. More reliable workaround — request timing directly in the API
response instead of relying on log/console output:
```bash
curl http://localhost:8090/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "assistant",
    "messages": [{"role":"user","content":"test"}],
    "timings_per_token": true
  }'
```
Or poll the live `/slots` endpoint during generation (needs `--slots`
added to the model's `cmd:` in `config.yaml`):
```bash
watch -n 0.5 'curl -s http://localhost:8090/slots | jq'
```

---

# Appendix C — Trust tiers: what to verify before acting

A 14B local model, even with 14 layered rules and full tool access, can
still fabricate both an answer and a citation for it on a moderately
specific task (config syntax, exact option names) — this is a capacity
ceiling, not a prompt-wording problem, and no amount of additional
prompting fully closes it. Calibrate trust by task type rather than
treating every answer the same:

- **Trust with light spot-checking**: general explanations, architecture
  questions, "how does X work," conceptual comparisons.
- **Verify the specific claim before acting on it**: any stated
  option/flag/field name — click through the citation, don't just trust
  the `[DOCS]` tag.
- **Never trust as final — always validate externally**: any generated
  code/config artifact you're actually going to deploy. For Renovate
  specifically, run `npx renovate-config-validator` against anything
  generated before it goes near a real repo — a good habit independent of
  AI use entirely, and the same principle applies to Terraform (`terraform
  validate`), Kubernetes manifests (`kubectl apply --dry-run=client`), and
  so on.

If a task keeps landing in the "never trust as final" tier often enough
to be annoying, that's a signal to reach for a larger model (even a
pay-as-you-go API call for just that one verification) rather than adding
another rule to Appendix A — twelve-plus rules deep is already past the
point of reliable diminishing returns for a model this size.
