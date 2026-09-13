# Local DevOps AI Setup

Docs-first, non-hallucinating DevOps assistant, running entirely locally in
Docker. Answers are grounded in live web search of official documentation
first (tagged `[DOCS]`, with URL + quote), falling back to general web
search only when the docs don't cover it (tagged `[WEB]`). No offline/local
doc store.

**Two interchangeable serving engines, pick one:**

- **Part 1 — llama-swap** (recommended): raw llama.cpp under the hood,
  ~15-30% faster and lighter on VRAM than Ollama, at the cost of manual
  `--n-gpu-layers` tuning per model instead of automatic fitting.
- **Part 2 — Ollama**: simpler, automatic VRAM fitting, slightly slower.

Both connect identically to **Open WebUI** (browser chat), **sgpt** (CLI),
and **VS Code** (via the Continue extension) — each Part below is complete
and standalone, so follow one straight through rather than jumping between
them. Shared reference material (the system prompt, GPU/WSL troubleshooting,
benchmarking) lives in the appendices at the end so it isn't duplicated
four times.

---

# Part 0 — Shared prerequisites

Do this once regardless of which engine you pick.

## 0.1 Folder layout

Everything lives next to `docker-compose.yml`:

```
your-project/
├── docker-compose.yml
└── data/
    ├── open-webui/        (created automatically on first `up`)
    ├── searxng/           (created automatically on first `up`)
    ├── ollama/            (Part 2 only)
    ├── llama-swap/        (Part 1 only — create config.yaml here
    │                        BEFORE first `up`, see Part 1.4)
    └── llama-cpp/models/  (Part 1 only — HF model cache)
```

## 0.2 GPU passthrough

### Install the NVIDIA driver and Container Toolkit

**Install the NVIDIA driver on Windows itself, not inside WSL** — WSL2
picks up the Windows-side driver automatically; installing a separate
driver inside the WSL Ubuntu distro is unnecessary and can conflict.
Grab the latest driver from `https://www.nvidia.com/drivers` (or use
GeForce Experience / whatever came with your GPU) if you haven't already.

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

This must show your GPU. Both engines below use the `gpus: all` Compose
shorthand (2.3+) in their service definitions — **not**
`deploy.resources.reservations.devices`, which is officially valid per the
Compose spec but is known to be silently ignored outside Swarm mode on some
Compose versions: it parses without error, but the container never
actually gets the GPU, and inference silently falls back to full CPU with
the GPU sitting idle. If you ever see high CPU / growing system RAM / idle
GPU despite `nvidia-smi` working standalone, see **Appendix B**.

## 0.3 SearXNG (shared by both paths — this is what powers the `[WEB]`/`[DOCS]` web search fallback)

Add this service to `docker-compose.yml` (both Part 1 and Part 2 include it
in their full files below — this is just the explanation):

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
default; the JSON format Open WebUI needs must be added by hand, and the
key doesn't exist in the generated file until you add it:

```bash
docker compose up -d searxng   # let it generate the initial file first
cat ./data/searxng/settings.yml
```

Edit `./data/searxng/settings.yml` to add the missing `search:` block and
`limiter: false`:

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

Generate a real secret key (don't leave a placeholder if this instance
will ever be reachable beyond localhost):
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

Once either engine is connected, you'll notice **the chat dropdown** (top
of a chat window) lists every raw model the connection exposes — e.g.
`quick`, `power`, `power-reasoning`, `power-30b`, or `qwen3:14b` directly —
while **Workspace → Models** only lists custom models you've explicitly
built there via the `+` flow. This is intentional, not a bug: Workspace →
Models is a page for your saved presets (system prompt + params bundled
together), not a catalog of every model a connection happens to expose.

**This matters practically**: if you pick a raw base model straight from
the chat dropdown (`power`, `qwen3:14b`, etc.) instead of one of your
custom models (`DevOps Assistant (docs-first)`, etc.), you get **no
system prompt at all** — no `[DOCS]`/`[WEB]` tagging, no priority-domain
search behavior, none of Appendix A's rules. It'll still generate
answers, just without any of the docs-first grounding this whole setup is
for. Always select your custom model, not the raw base model, for actual
use — the raw entries are only useful for the standalone testing/tuning
commands elsewhere in this guide (pre-warming, benchmarking, etc.).

---

# Part 1 — llama-swap (recommended engine)

llama-swap is a small proxy that replicates Ollama's "auto-load on
request, auto-unload after idle, swap between models" convenience on top
of raw llama.cpp, since llama.cpp's own server only ever holds one model
at a time. It speaks the **OpenAI-compatible API**, not Ollama's native
API — that matters for how Open WebUI and VS Code connect to it below.

## 1.1 Installing llama.cpp itself

**No separate install step needed for this path.** The
`ghcr.io/mostlygeek/llama-swap:unified-cuda13` image already contains a
CUDA-compiled `llama-server` binary — llama-swap's whole job is spawning
and managing that binary per model. Confirm it's there once the container
is up:
```bash
docker exec -it llama-swap llama-server --version
```

**Optional native build**, only if you want direct access to llama.cpp's
own CLI tools (`llama-bench` for precise `--n-gpu-layers` tuning outside
the container, `llama-quantize`, `llama-cli`). This needs the actual CUDA
*toolkit* (`nvcc`) inside WSL, not just the Windows driver:
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
Useful for tuning `--n-gpu-layers` methodically:
```bash
./build/bin/llama-bench -m /path/to/model.gguf -ngl 20,30,40,99
```
This is a separate binary from the one inside Docker — handy for testing,
doesn't replace the containerized setup below.

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
- `gpus: all` — see Part 0.2. Confirm with
  `docker exec -it llama-swap nvidia-smi` after `up`.
- The `unified-cuda13` tag matches a CUDA 13.x driver (check your own
  `nvidia-smi` output — if it reports CUDA 12.x, use the matching
  `unified-cuda12` tag from `https://github.com/mostlygeek/llama-swap`
  instead).
- `RAG_WEB_SEARCH_RESULT_COUNT=4` (not higher) is deliberate — more
  snippets in context increases the chance the model cross-wires which
  URL belongs to which claim, producing fabricated citations (Appendix A,
  rule 8, plus Appendix B's citation note).
- No `OLLAMA_BASE_URL` here — this path doesn't use Ollama at all. Open
  WebUI connects to llama-swap as a generic OpenAI-compatible endpoint
  (section 1.6).

**Create the config file on the host *before* your first `up` for this
service — this matters, not a style choice.** Docker bind-mounts a source
path that doesn't exist yet as a *directory*, not a file. If
`./data/llama-swap/config.yaml` isn't already a real file when the
container first starts, you'll get a directory of that name instead, and
nothing you write afterward lands where llama-swap actually reads from:
```bash
mkdir -p ./data/llama-swap ./data/llama-cpp/models
touch ./data/llama-swap/config.yaml
```

## 1.3 Bring up SearXNG and llama-swap

```bash
docker compose up -d searxng llama-swap
docker exec -it llama-swap nvidia-smi   # confirm GPU is visible
```

## 1.4 config.yaml — model definitions

`./data/llama-swap/config.yaml`:

```yaml
healthCheckTimeout: 180
logLevel: info

models:
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

  "power":
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
    ttl: 300

  "power-reasoning":
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

  "power-30b":
    cmd: |
      llama-server
      -hf Qwen/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_M
      --port ${PORT}
      --host 0.0.0.0
      --ctx-size 16384
      --n-gpu-layers 20
      --flash-attn on
      --cache-type-k q8_0
      --cache-type-v q8_0
      --jinja
    ttl: 300
```

Caveats, don't skip these:

- **`-hf` repo/quant strings confirmed correct** — these are the official
  Qwen GGUF repo names. Testing one standalone still doubles as
  pre-warming the model cache (see 1.5):
  ```bash
  docker exec -it llama-swap llama-server -hf Qwen/Qwen3-14B-GGUF:Q4_K_M --port 9999
  ```
- **`--jinja` is required** for proper chat-template/tool-call formatting
  — without it, tool calling for the web-search flow is likely to break
  or degrade.
- **`--flash-attn` needs an explicit value** (`on`/`off`/`auto`) on this
  build — a bare `--flash-attn` flag makes `llama-server` exit
  immediately with an argument-parsing error, before ever loading the
  model. If `docker logs llama-swap` shows `process exited: code=1` with
  almost no elapsed time (versus a slow failure, which usually means a
  download/timeout issue), run the exact command from the log manually to
  see the real error — flag syntax has shifted across llama.cpp versions
  before and may again.
- **`--n-gpu-layers 20` on `power-30b` is a starting guess, not verified.**
  Unlike Ollama, llama.cpp doesn't automatically back off if this doesn't
  fit — it errors or OOMs. Tune it:
  1. Run manually with `--n-gpu-layers 99` and watch for an OOM error.
  2. If it OOMs, lower in steps of ~5-10 and retry.
  3. Once it loads cleanly, watch `nvidia-smi` during a real generation to
     confirm VRAM sits comfortably under 12GB, then lock that number in.
  4. Faster alternative: if you did the native build in 1.1, use
     `llama-bench -m <file> -ngl 20,30,40,99` to sweep this in one command
     instead of manual trial and error.
- **Thinking mode** (`power-reasoning`) is controlled the same way as with
  Qwen3 generally — `/think` / `/no_think` in the prompt or system message
  — there's no separate llama.cpp CLI flag for it. The
  `--temp`/`--top-p`/`--top-k` values match Qwen's own recommended
  sampling profile for thinking mode (low temperature actively degrades
  it — causes repetition or getting stuck).

Apply:
```bash
docker compose up -d llama-swap
```

## 1.5 Pre-warm every model before using it through the UI

**Models download lazily on first generation request, not at container
startup or when you merely select one in a dropdown.** The first request
to a new model simultaneously spawns the process, downloads several GB
from Hugging Face, loads it into VRAM, then generates — which commonly
exceeds Open WebUI's or llama-swap's own `healthCheckTimeout` and shows up
as a generic error, not an obvious "still downloading" message. Pre-warm
each model once (this is the same command as the verification step above):
```bash
docker exec -it llama-swap llama-server -hf Qwen/Qwen2.5-Coder-7B-Instruct-GGUF:Q4_K_M --port 9999
docker exec -it llama-swap llama-server -hf Qwen/Qwen3-14B-GGUF:Q4_K_M --port 9999
docker exec -it llama-swap llama-server -hf Qwen/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_M --port 9999
```
Let each run until you see a "server listening" message, then `Ctrl+C`.
The GGUF is now cached under `./data/llama-cpp/models` — subsequent loads
(via CLI or through Open WebUI/sgpt/VS Code) read from local disk in
seconds instead of re-downloading.

## 1.6 Connect Open WebUI

llama-swap speaks OpenAI's API shape, not Ollama's — connect it as a
generic OpenAI-compatible provider, done through the Admin UI (more
version-stable than guessing at env var names):

**Admin Settings → Connections → Add Connection → OpenAI API**
- **Base URL**: `http://llama-swap:8080/v1`
- **API Key**: any non-empty placeholder, e.g. `sk-local-no-auth` —
  llama-swap doesn't enforce one, but the connection form typically
  requires a non-empty value.
- Save, then confirm `quick`, `power`, `power-reasoning`, `power-30b`
  appear as selectable models.

**Create the docs-first custom model** — do this manually rather than via
JSON import (Open WebUI's import schema isn't stable/documented enough to
hand-craft reliably; manual creation always matches whatever your version
actually expects):

**Workspace → Models → `+`**
- **Name**: `DevOps Assistant (docs-first)`
- **Base Model**: `power` (the connection you just added)
- **System Prompt**: paste the full prompt from **Appendix A**.
- **Advanced Params**: `temperature 0.15`, `top_p 0.9`,
  `repeat_penalty 1.1`, `num_ctx 16384`, `Function Calling: Native`.
- **Capabilities**: see the checklist in **Appendix A.1**.

Repeat this for `power-reasoning` (Qwen's recommended sampling —
`temperature 0.6`, `top_p 0.95`, `top_k 20` — instead of the above, plus
starting the system prompt with `/think`) and `power-30b` if you want them
as selectable custom models too, rather than raw base models.

## 1.7 Connect sgpt

```bash
pip install shell-gpt --break-system-packages
mkdir -p ~/.config/shell_gpt
cat > ~/.config/shell_gpt/.sgptrc << 'EOF'
API_BASE_URL=http://localhost:8090/v1
OPENAI_API_KEY=sk-local-no-auth
DEFAULT_MODEL=quick
CHAT_CACHE_LENGTH=100
CHAT_CACHE_PATH=/tmp/shell_gpt/chat_cache
CACHE_LENGTH=100
CACHE_PATH=/tmp/shell_gpt/cache
REQUEST_TIMEOUT=60
DEFAULT_COLOR=magenta
DISABLE_STREAMING=false
PRETTIFY_MARKDOWN=true
SHELL_INTERACTION=true
OS_NAME=auto
SHELL_NAME=auto
EOF
```
shell-gpt reads `API_BASE_URL` **from this config file**, not from
`OPENAI_API_BASE`/similar environment variables — setting only env vars
will silently fall through to OpenAI's real endpoint and fail with a 401.
Test:
```bash
sgpt "explain this renovate.json error: <paste>"
```
Note: `sgpt` is stateless and doesn't carry the system prompt or
web-search behavior — it's a plain, fast Q&A path. Use Open WebUI for the
docs-first/citation behavior.

## 1.8 Connect VS Code (Continue extension)

Install the **Continue** extension from the VS Code marketplace. Open its
config (Continue side panel → gear icon → Configure, or edit
`~/.continue/config.yaml` directly):

```yaml
name: Local DevOps Config
version: 0.0.1
schema: v1
models:
  - name: Local Quick (llama-swap)
    provider: openai
    model: quick
    apiBase: http://localhost:8090/v1
    apiKey: sk-local-no-auth
    roles:
      - chat
      - edit
      - autocomplete

  - name: Local Power (llama-swap)
    provider: openai
    model: power
    apiBase: http://localhost:8090/v1
    apiKey: sk-local-no-auth
    roles:
      - chat
      - edit
```
Reload the window (command palette → *Developer: Reload Window*), open
the Continue panel, and pick one of these models. `quick` is a sensible
choice for the `autocomplete` role specifically — it's the smaller/faster
model and autocomplete needs low latency more than reasoning depth.
Note VS Code/Continue talks directly to llama-swap, bypassing Open
WebUI's citation/web-search behavior entirely — it's a coding assistant
here, not the docs-first researcher.

## 1.9 Verify end-to-end

1. In Open WebUI, ask an obscure, version-specific question through the
   `DevOps Assistant (docs-first)` model. Confirm a `[DOCS]` or `[WEB]`
   tag with a real URL appears — not a bare confident answer.
2. Check the tokens/sec sanity range and compare against Ollama if you've
   run both — see **Appendix D**.
3. If tool-calling doesn't fire reliably, re-check the SearXNG query URL
   (`&format=json`) and confirm `--jinja` is present in the relevant
   model's `cmd:` block.

---

# Part 2 — Ollama (simpler alternative)

Ollama wraps llama.cpp with automatic VRAM fitting, a model registry
(`ollama pull <tag>`), and its own native API — trading some throughput
for a lot of convenience.

## 2.1 Full docker-compose.yml

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

  ollama:
    image: ollama/ollama
    container_name: ollama
    ports:
      - "11434:11434"
    volumes:
      - ./data/ollama:/root/.ollama
    gpus: all
    environment:
      - OLLAMA_FLASH_ATTENTION=1       # required for quantized KV cache below to take effect
      - OLLAMA_KV_CACHE_TYPE=q8_0      # ~50% KV cache VRAM savings, minimal quality impact
      - OLLAMA_KEEP_ALIVE=5m           # unload idle models after 5min to free VRAM
      - OLLAMA_MAX_LOADED_MODELS=1     # only one model resident at a time (12GB card, multiple models)
    restart: unless-stopped

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    ports:
      - "3000:8080"
    volumes:
      - ./data/open-webui:/app/backend/data
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - ENABLE_RAG_WEB_SEARCH=true
      - RAG_WEB_SEARCH_ENGINE=searxng
      - SEARXNG_QUERY_URL=http://searxng:8080/search?q=<query>&format=json
      - RAG_WEB_SEARCH_RESULT_COUNT=4
      - RAG_WEB_SEARCH_CONCURRENT_REQUESTS=4
    depends_on:
      - ollama
      - searxng
    restart: unless-stopped
```

`gpus: all` — see Part 0.2. Confirm with
`docker exec -it ollama nvidia-smi` after `up`.

```bash
docker compose up -d
```

## 2.2 Pull the models

```bash
docker exec -it ollama ollama pull qwen2.5-coder:7b     # quick
docker exec -it ollama ollama pull qwen3:14b            # power / power-reasoning (same weights)
docker exec -it ollama ollama pull qwen3-coder:30b      # power-30b (optional, MoE, partial CPU offload)
```

Qwen3 is used for the tool-calling-critical models specifically because it
has native/reliable tool-calling support in Ollama — Qwen2.5-Coder does
not, and tends to dump tool calls as plain-text JSON instead of actually
invoking them.

Verify before trusting the workflow:
```bash
docker exec -it ollama ollama show qwen3:14b
```
Confirm `tools` appears under **Capabilities** (it will likely also show
`thinking` — Qwen3's reasoning mode, used by the `power-reasoning` variant
below). `qwen3-coder:30b` has no `thinking` capability — it's
instruct-only.

**Get the actual `--n-gpu-layers` number Ollama computed**, useful
reference even on this path (and directly reusable if you ever switch to
Part 1):
```bash
docker logs ollama 2>&1 | grep -i "offload"
```
Look for a line like `llm_load_tensors: offloaded 41/41 layers to GPU`.

## 2.3 Connect Open WebUI

Ollama's native connection is usually pre-wired via `OLLAMA_BASE_URL` in
the compose file above — confirm under **Admin Settings → Connections**
that it shows connected.

**Create the docs-first custom model manually** (not via JSON import — see
Part 1.6 for why):

**Workspace → Models → `+`**
- **Name**: `DevOps Assistant (docs-first)`
- **Base Model**: `qwen3:14b`
- **System Prompt**: paste the full prompt from **Appendix A**.
- **Advanced Params**: `temperature 0.15`, `top_p 0.9`,
  `repeat_penalty 1.1`, `num_ctx 16384`, `Function Calling: Native`.
- **Capabilities**: see the checklist in **Appendix A.1**.

**Second model — reasoning variant** (same weights, thinking mode
forced on, for questions needing multi-fact synthesis — e.g. "does
setting A override or add to setting B"):

**Workspace → Models → `+`**
- **Name**: `DevOps Assistant (docs-first, 14B-reasoning)`
- **Base Model**: `qwen3:14b`
- **System Prompt**: Appendix A's prompt, but starting with `/think` on
  its own first line, plus rule 10 from Appendix A.2.
- **Advanced Params**: `temperature 0.6`, `top_p 0.95`, `top_k 20`,
  `repeat_penalty 1`, `num_ctx 16384` (or higher — thinking traces are
  verbose), `Function Calling: Native`.

**Third model — bigger coder** (optional, heavier reasoning capacity,
slower due to CPU offload, some tool-calling flakiness on MoE routing —
use selectively, not as default):

**Workspace → Models → `+`**
- **Name**: `DevOps Assistant (docs-first, 30B)`
- **Base Model**: `qwen3-coder:30b`
- **System Prompt / Params**: same as the first model above.

## 2.4 Connect sgpt

```bash
pip install shell-gpt --break-system-packages
mkdir -p ~/.config/shell_gpt
cat > ~/.config/shell_gpt/.sgptrc << 'EOF'
API_BASE_URL=http://localhost:11434/v1
OPENAI_API_KEY=ollama
DEFAULT_MODEL=qwen2.5-coder:7b
CHAT_CACHE_LENGTH=100
CHAT_CACHE_PATH=/tmp/shell_gpt/chat_cache
CACHE_LENGTH=100
CACHE_PATH=/tmp/shell_gpt/cache
REQUEST_TIMEOUT=60
DEFAULT_COLOR=magenta
DISABLE_STREAMING=false
PRETTIFY_MARKDOWN=true
SHELL_INTERACTION=true
OS_NAME=auto
SHELL_NAME=auto
EOF
```
Same gotcha as Part 1.7 applies — `API_BASE_URL` must be in this file, not
just an environment variable, or sgpt silently falls through to OpenAI's
real endpoint and fails with a 401.
```bash
sgpt "explain this renovate.json error: <paste>"
```

## 2.5 Connect VS Code (Continue extension)

```yaml
name: Local DevOps Config
version: 0.0.1
schema: v1
models:
  - name: Local Quick (Ollama)
    provider: openai
    model: qwen2.5-coder:7b
    apiBase: http://localhost:11434/v1
    apiKey: ollama
    roles:
      - chat
      - edit
      - autocomplete

  - name: Local Power (Ollama)
    provider: openai
    model: qwen3:14b
    apiBase: http://localhost:11434/v1
    apiKey: ollama
    roles:
      - chat
      - edit
```
Ollama also exposes a native `ollama` provider type in Continue, but it
doesn't support the auth field consistently — using the `openai` provider
type against Ollama's OpenAI-compatible `/v1` endpoint (as above) is more
consistent and is the same pattern used in Part 1, so your config looks
almost identical regardless of which engine you're on.

## 2.6 Verify end-to-end

1. Ask an obscure question through `DevOps Assistant (docs-first)` and
   confirm a `[DOCS]`/`[WEB]` tag with a real URL — not a bare answer.
2. Check tokens/sec — see **Appendix D** for the expected range and how
   to spot silent CPU fallback.
3. Test the Renovate-style multi-hop question (Appendix D) against the
   reasoning variant if the default model stops short of a full answer.

---

# Appendix A — System prompt (used by both paths)

```
You are a DevOps assistant. You have a web search tool. You do NOT have a local/offline document store - all documentation lookups happen live via web search.

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

9. When a question involves how two configuration behaviors interact (e.g. whether one setting overrides or adds to another), explicitly state which it is and name the correct option to achieve the user's actual goal, before giving your final answer. Do not stop at restating a single retrieved fact if the practical implication requires combining it with another.
```

## A.1 — Capabilities checklist (Open WebUI, both paths)

Your Open WebUI version likely exposes a broad "agent OS" capability set
(Terminal, sub-agents, automations, channels, etc.) beyond what a docs-first
assistant needs. More enabled tools means more chances the model picks the
wrong one — trim aggressively:

**Web Search specifically appears in three separate places, and they are
not the same toggle:**
- **Capabilities → Web Search** — mostly a capability indicator/badge.
- **Default Features → Web Search** — the classic behavior: Open WebUI
  automatically runs a search before every message and injects results
  into context, independent of the model deciding anything.
- **Builtin Tools → Web Search** — registers `web_search` as an actual
  **callable function** for native tool-calling.

With `Function Calling: Native` set (as this whole guide uses), the model
needs a real callable tool — that only comes from **Builtin Tools**. If
only the first two are checked, native mode has nothing to call, and the
model will accurately say it can't access the internet rather than
hallucinating — check **all three**, not just the top two.

**Check:** Web Search (all three locations above), Citations, File
Upload, File Context, Status Updates, Chat History, Time & Calculation,
Files.

**Uncheck:** Terminal (real shell/code execution — meaningful risk, not
needed here), Sub-agents, Task Management, Notes, Channels, Automations,
Notifications, Calendar, Ask User, Code Interpreter (optional later),
Image Generation, Memory (keep lookups stateless/deterministic), Knowledge
Base (no local doc store — this would pull from stored docs instead of
live search), Vision (unless your base model actually supports it).

## A.2 — Reasoning-variant addendum (rule 10, and `/think`)

For the `power-reasoning` model in either path, start the system prompt
with `/think` on its own line before the rest of Appendix A's prompt
(documented Qwen3 behavior: it honors `/think`/`/no_think` in either the
system message or user turns, following the most recent instruction), and
append this as rule 10:

```
10. Before giving your final answer to a question that requires connecting more than one fact, explicitly write out: (a) each relevant fact you found, with its source, (b) how those facts interact or constrain each other, (c) the practical conclusion or recommendation that follows. Only then give the final answer.
```

---

# Appendix B — WSL / GPU troubleshooting

## B.1 — Silent CPU fallback (GPU idle, high CPU/RAM)

Symptom: `nvidia-smi` works standalone, but a model runs on CPU anyway.
Usually a **WSL2 GPU-passthrough race condition at boot** — WSL's GPU
paravirtualization layer (`/dev/dxg`) can still be settling when the
container starts and probes for CUDA, the probe fails, and it silently
falls back to CPU for that container's whole life.

Fast fix:
```bash
docker compose restart ollama    # or llama-swap
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
docker exec -it ollama curl http://localhost:11434/api/tags   # (or llama-swap equivalent)
docker exec -it open-webui curl http://ollama:11434/api/tags  # container-to-container
docker compose ps                          # all should show "Up", not "Restarting"/"Exited"
```
If Open WebUI shows configured models but they're not selectable, this is
almost always a stale connection to the engine, not a missing model — try
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

---

# Appendix C — Switching engines / disabling one cleanly

You can run both `ollama` and `llama-swap` containers simultaneously with
no port/path conflicts — the only real constraint is **VRAM**, since
both can't hold a model resident at once on a 12GB card. Both have
5-minute idle-unload configured (`OLLAMA_KEEP_ALIVE`, `ttl: 300`), so
sequential testing never collides; to force an immediate switch instead
of waiting out the TTL:
```bash
docker exec -it ollama ollama stop qwen3:14b
```

**To fully disable one** (e.g. after confirming llama-swap works and you
want to drop Ollama): don't just comment out the service block — Compose
won't stop an already-running container it no longer sees, and
`open-webui`'s `depends_on` will error if it references a removed service.

```bash
docker compose stop ollama
```
Then edit `docker-compose.yml`: remove the `ollama:` block, remove the
`- ollama` line from `open-webui`'s `depends_on:`, and remove the
`OLLAMA_BASE_URL` env var (harmless to leave, but shows a permanently
broken connection in Admin Settings otherwise). Apply with:
```bash
docker compose up -d --remove-orphans
```
`--remove-orphans` is what actually removes the now-unreferenced
container — a plain `up` leaves it running in the background.
`./data/ollama` (pulled models) is safe to leave on disk as a quick-revert
option, or delete later to reclaim space.

---

# Appendix D — Benchmarking

## D.1 — Speed check

Watch the engine's logs during a chat response:
```bash
docker logs -f ollama       # or: docker logs -f llama-swap
```
Look for a timing line (Ollama: `slot print_timing: ... tg = 39.52 t/s`;
llama-swap logs the same underlying llama.cpp timing). For `qwen3:14b`
(Q4_K_M, ~9GB) on a 12GB-class GPU, expect roughly **30–45 tokens/sec** on
GPU — memory-bandwidth math on a card like the RTX 4070 puts a rough
ceiling around 50–60 t/s, with real throughput landing at 60–70% of that
once attention/KV-cache overhead is accounted for. **Single digits
(roughly 3–10 t/s)** means silent CPU fallback — see Appendix B.1, not a
"just slow" situation.

Use this same prompt on both engines for a fair comparison (avoids tool
calling, which would swamp the signal with search latency):
> "Write a Python function that implements a binary search on a sorted
> list, with a docstring and type hints. Then explain how its time
> complexity is derived, in about 300 words."

Force `/no_think` for this test, run it 3 times, discard the first (cold
load skews it), average the rest.

## D.2 — Reasoning-quality check

Tests whether a model actually connects two facts into a conclusion,
rather than stopping at the first true statement:
> "In GitHub Actions, if a workflow has both a top-level `permissions`
> block and a job-level `permissions` block, which one takes effect for
> that job — does the job-level block add to the top-level one, or
> replace it entirely?"

Run this against both your default model and the `power-reasoning`
variant — a good answer states clearly whether it's additive or
overriding, names the mechanism, and gives the practical implication, not
just "here's what `permissions` does."

## D.3 — CPU-only baseline test

Useful for two things: getting an unambiguous "this is what silent GPU
fallback looks like" reference number for your own hardware, and checking
whether a model too big to fit in 12GB VRAM is at least usable purely in
your 64GB system RAM.

**Force CPU-only on llama-swap/llama.cpp** — explicit flag, no GPU-hiding
needed:
```bash
docker exec -it llama-swap llama-server -hf Qwen/Qwen3-14B-GGUF:Q4_K_M --port 9999 --n-gpu-layers 0
```

**Force CPU-only on Ollama** — no equivalent single flag, so hide the GPU
device from that one command instead (only affects this `exec` call, not
the container's overall config):
```bash
docker exec -e CUDA_VISIBLE_DEVICES=-1 -it ollama ollama run qwen3:14b "test prompt"
```

Run the same D.1 benchmark prompt with `/no_think`, and check:
```bash
docker logs -f llama-swap    # or: docker logs -f ollama
free -h                      # or: docker stats, for container-scoped RAM
```

Expect roughly **low single digits up to ~10 t/s** for a 14B model on
CPU, depending on your processor — a 5-15x slowdown from GPU is typical,
so this isn't meant to be usable for interactive chat, just a concrete
reference point. Memory footprint (~9GB for this model's Q4_K_M weights)
should sit comfortably inside 64GB, so RAM capacity isn't the constraint
here — generation speed is. Compare this number directly against your GPU
baseline from D.1 any time you're unsure whether offload actually
happened.
