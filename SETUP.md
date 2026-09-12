# Local DevOps AI Setup — Docker + Ollama + Open WebUI + SearXNG

Docs-first, non-hallucinating DevOps assistant. Answers are grounded in live
web search of official documentation first (tagged `[DOCS]`, with URL +
quote), falling back to general web search only when the docs don't cover
it (tagged `[WEB]`). No offline/local doc store. Quick model for `sgpt`
(CLI), powerful model for Open WebUI (GUI), both served by one Ollama
instance.

---

## 0. Folder layout

Everything lives next to this file / your `docker-compose.yml`:

```
your-project/
├── docker-compose.yml
└── data/
    ├── ollama/        (created automatically on first `up`)
    ├── open-webui/     (created automatically on first `up`)
    ├── searxng/        (created automatically on first `up`)
    ├── llama-cpp/models/  (optional, section 9 - HF model cache)
    └── llama-swap/        (optional, section 9 - create config.yaml
                             here *before* first `up`, see section 9)
```

---

## 1. docker-compose.yml

Save this as `docker-compose.yml` in your project folder:

```yaml
services:
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

`gpus: all` on the `ollama` service is the Compose 2.3+ shorthand for GPU
passthrough. An earlier version of this file used the
`deploy.resources.reservations.devices` syntax instead — that's officially
correct per the Compose spec, but is known to be silently ignored outside
Swarm mode on some Compose versions: it parses without error, but the
container never actually gets the GPU, and Ollama falls back to full CPU
inference with the GPU sitting idle (high CPU, growing system RAM, 0% GPU
usage — if you saw exactly that, this was why). `gpus: all` avoids that
ambiguity.

Verify GPU passthrough is actually working before moving on:

```bash
docker compose up -d
docker exec -it ollama nvidia-smi
```

This must show your GPU. If it doesn't, the issue is upstream of Compose —
re-check the NVIDIA Container Toolkit setup from earlier (`docker run
--rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi` should
still succeed independently of Ollama). If `nvidia-smi` works but Ollama
still runs on CPU, check `docker logs ollama` for GPU-detection errors.

**Ongoing sanity check — expected generation speed on GPU vs CPU fallback:**
Watch the `ollama` container logs during a chat response:
```bash
docker logs -f ollama
```
Look for a line like `slot print_timing: ... tg = 39.52 t/s`. For
`qwen3:14b` (Q4_K_M, ~9GB) on a 12GB-class GPU, expect roughly **30–45
tokens/sec** when correctly running on GPU — memory-bandwidth math on a
card like the RTX 4070 puts a rough ceiling around 50–60 t/s, and real
throughput typically lands at 60–70% of that once attention/KV-cache
overhead is accounted for. If you ever see this drop to **single digits
(roughly 3–10 t/s)**, that's the same silent-CPU-fallback symptom covered
above — re-run the `nvidia-smi` check rather than assuming it's just slow.

Notes:
- `SEARXNG_QUERY_URL` **must** include `&format=json` — without it, Open
  WebUI receives HTML back from SearXNG and silently fails to parse it.
- `RAG_WEB_SEARCH_CONCURRENT_REQUESTS` must **not** be `0` — that's a known
  silent-failure cause for this exact SearXNG + Open WebUI combo.
- `RAG_WEB_SEARCH_RESULT_COUNT` kept low (4) deliberately — more snippets in
  context increases the chance the model cross-wires which URL belongs to
  which claim, producing fabricated citations (see "Watch for fabricated
  citations specifically" in section 6 below).
- No top-level `volumes:` section needed — everything is a bind mount under
  `./data`, visible next to this file.

Bring it up:

```bash
docker compose up -d
```

---

## 2. Enable JSON output on SearXNG (one-time, required)

SearXNG only enables the HTML format by default — this key doesn't exist in
the generated file until you add it yourself.

```bash
cat ./data/searxng/settings.yml
```

Edit `./data/searxng/settings.yml` so it looks like this (add the missing
`limiter: false` line under `server:`, and the whole `search:` block if not
present):

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

Generate a real secret key (don't leave the placeholder if this instance
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

---

## 3. Pull the two models

```bash
docker exec -it ollama ollama pull qwen2.5-coder:7b     # quick -> sgpt (no tool calling needed)
docker exec -it ollama ollama pull qwen3:14b            # power -> Open WebUI (needs reliable tool calling)
```

Qwen3 is used for the power model specifically because it has native,
reliable tool-calling support in Ollama — Qwen2.5-Coder does not, and tends
to dump tool calls as plain-text JSON instead of actually invoking them.

Verify before trusting the workflow:

```bash
docker exec -it ollama ollama show qwen3:14b
```

Confirm `tools` appears under **Capabilities**. (It will likely also show
`thinking` — Qwen3's reasoning mode. Open WebUI renders `<think>` blocks as
collapsible, which is fine; if responses feel slow, append `/no_think` to a
prompt to skip it, or `/think` to force it for a genuinely hard question.)

Optional third model, `qwen3-coder:30b`, for questions needing deeper
multi-hop reasoning than `qwen3:14b` reliably provides — see section 7.

---

## 4. sgpt → quick model

```bash
pip install shell-gpt --break-system-packages
```

shell-gpt does **not** read `OPENAI_API_BASE` as an environment variable —
it needs the base URL set via its own config key, `API_BASE_URL`, in its
config file. Setting only env vars (as an earlier version of this guide
suggested) will silently fall through to OpenAI's real endpoint and fail
with a 401, since it tries your local placeholder key against the real API.

```bash
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

If `~/.config/shell_gpt/.sgptrc` already exists with different content,
check it first (`cat ~/.config/shell_gpt/.sgptrc`) rather than overwriting
blindly — just make sure `API_BASE_URL` and `DEFAULT_MODEL` are set as
above.

```bash
sgpt "explain this renovate.json error: <paste>"
```

Note: `sgpt` is stateless and doesn't get the system prompt or web-search
setup below — it's a plain, fast Q&A path for quick lookups. Use Open WebUI
when you want the docs-first/web-fallback behavior with citations.

shell-gpt's own maintainers note it's *"not optimized for local models and
may not work as expected"* — if you hit odd formatting or streaming
glitches beyond the auth issue above, that's a known limitation of the
tool itself.

---

## 5. Open WebUI → power model (manual creation)

**Create the model by hand, not via JSON import.** Open WebUI's import
expects an exact, undocumented schema — a hand-built JSON file can silently
produce zero imported models. Manual creation is guaranteed to match
whatever your installed version actually expects.

**Workspace → Models → `+`**

- **Name**: `DevOps Assistant (docs-first)`
- **Base Model**: `qwen3:14b`
- **System Prompt** — paste exactly:

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

- **Advanced Params**:
  - `temperature`: `0.15`
  - `top_p`: `0.9`
  - `repeat_penalty`: `1.1`
  - `num_ctx`: `16384` — tool schemas consume significant context; `8192`
    has been reported as too tight for reliable tool calling
  - `Function Calling`: `Native`
- Save, then set it as your default model for chat.

### Capabilities checkboxes

Your Open WebUI version exposes a large "agent OS" capability set (Open
Terminal, sub-agents, automations, channels, etc.) beyond what a simple
docs-first assistant needs. More enabled tools means more chances for the
model to pick the wrong one instead of the one you actually need — trim
aggressively:

**Check:**
| Item | Why |
|---|---|
| Web Search (Capabilities + Default Features) | The whole point of this setup |
| Citations | Surfaces source URLs, complements the `[DOCS]`/`[WEB]` tags |
| File Upload + File Context | Paste logs/configs in for it to read |
| Status Updates, Chat History, Time & Calculation, Files | Harmless utility, no real attack surface |

**Uncheck:**
| Item | Why |
|---|---|
| **Terminal** | Real shell/code execution on a live compute substrate — not needed for Q&A, meaningful risk if left on |
| Sub-agents | Adds autonomous parallel delegation — extra tool-selection complexity for no benefit here |
| Task Management, Notes, Channels, Automations, Notifications, Calendar, Ask User | Scheduling/collaboration feature set, unrelated to search-and-answer |
| Code Interpreter | Optional later; leave off for now to reduce tool competition while validating reliability |
| Image Generation | Not relevant |
| Memory | Keep lookups deterministic and stateless, not colored by remembered context |
| Knowledge Base | No local doc store anymore — this would pull from stored docs instead of live search, working against the system prompt |
| Vision | `qwen3:14b` has no vision capability — leave off |

### Admin Settings → Web Search

- Confirm **Query URL** ends in `&format=json`.
- Confirm **Concurrent Requests** is not `0`.
- Confirm SearXNG shows as connected.

---

## 6. End-to-end verification

Ask something obscure enough that the model can't already know it (a
recently-changed Renovate config key, a specific GCP flag, etc.) and check
the response:

- ✅ `[DOCS]` or `[WEB]` tag, a real URL, and a quoted snippet → working.
- ⚠️ Raw JSON/XML text dumped into the reply → tool-call format mismatch,
  see troubleshooting below.
- ❌ A confident answer with no tag and no URL → it's answering from
  training data instead of searching; do not trust unverified answers like
  this.

### If it's not firing reliably

1. Re-check `ollama show qwen3:14b` for `tools` under Capabilities.
2. Re-check the Query URL and Concurrent Requests settings above — both
   are documented silent-failure causes for this exact stack.
3. Fall back to manually toggling web search per-message in the chat UI
   until the automatic tool-calling path is confirmed reliable.

### Watch for fabricated citations specifically

Even with rule 8 in the system prompt and web search working correctly, a
model can still produce a URL that looks legitimate but was never actually
in the search results — it's predicting a plausible path on a known domain
rather than reproducing the real one, especially for well-known doc sites
it saw heavily during training. Smaller/quantized local models do this more
than large frontier models; it doesn't fully go away with prompting alone.

**Don't trust the URL as written in the response text.** Check Open WebUI's
citations panel (the source cards/footnotes under a response) instead —
that's generated programmatically from the actual raw search results, not
typed by the model, so it's ground truth. If the panel's URL differs from
what the model wrote inline, that confirms a fabricated citation. Treat
every `[DOCS]`/`[WEB]` URL as something to click and verify, not a
guarantee, regardless of how well-tuned this setup is.

---

## 7. Optional: bigger model for tougher reasoning (qwen3-coder:30b)

`qwen3:14b` is reliable but has limited capacity for multi-hop reasoning —
e.g. questions that require combining two retrieved facts to reach a
practical conclusion (see the Renovate `fileMatch`/`ignorePaths` case).
`qwen3-coder:30b` is a mixture-of-experts model (30.5B total params, ~3.3B
active per token) with more reasoning capacity, at the cost of speed and
some tool-calling reliability. Add it as a **second** model alongside
`qwen3:14b`, not a replacement — switch to it specifically for questions
the smaller model handles shallowly.

### Pull it

```bash
docker exec -it ollama ollama pull qwen3-coder:30b
```

Q4_K_M weights are ~19GB. With 12GB VRAM, Ollama automatically offloads the
remainder to system RAM (you have 64GB, plenty of headroom) — expect
noticeably slower generation than the fully-in-VRAM `qwen3:14b`, bottlenecked
by PCIe bandwidth for the offloaded portion. Benchmark it once running; exact
tokens/sec depends on your specific GPU.

### Tune Ollama for the offload scenario

`OLLAMA_KV_CACHE_TYPE=q8_0` is already set globally in section 1 — no
change needed there. Add one more env var specific to this offload
scenario, to the `ollama` service's `environment:` in `docker-compose.yml`:

```yaml
      - OLLAMA_NUM_PARALLEL=1         # single-user setup - don't split VRAM across requests
```

Apply with `docker compose up -d`.

### Verify tool-calling support

```bash
docker exec -it ollama ollama show qwen3-coder:30b
```

Confirm `tools` under Capabilities.

**Known caveat**: this model's MoE routing occasionally fails to fire a
tool call correctly even when tool-calling is supported — reported as more
likely than on the larger 480B version, plausibly because the smaller
expert pool sometimes routes to the wrong expert for a given prompt. If a
query doesn't trigger search when it should, rephrasing it often resolves
it. This is why it's a second model, not your default.

### Add it as a second model in Open WebUI

**Workspace → Models → `+`**

- **Name**: `DevOps Assistant (docs-first, 30B)`
- **Base Model**: `qwen3-coder:30b`
- **System Prompt**: identical to the `qwen3:14b` model above (the full
  prompt with rules 1–9, including the verbatim-URL rule and the
  multi-hop synthesis rule).
- **Advanced Params**: same as before — `temperature 0.15`, `top_p 0.9`,
  `repeat_penalty 1.1`, `num_ctx 16384`, `Function Calling: Native`.
- Same capability checkboxes as section 5 (Web Search, Citations, File
  Upload/Context on; Terminal, Sub-agents, Automations, etc. off).

Both models will now appear in the chat model dropdown — use `qwen3:14b`
by default, and switch to the 30B model for questions that need deeper
synthesis across multiple retrieved facts.

---

## 8. Optional: reasoning-tuned variant of the 14B model (thinking mode)

`qwen3-coder:30b` has no thinking mode at all — `qwen3:14b` does, and
you've likely never turned it on. This is the more direct fix for
multi-hop reasoning gaps (e.g. the Renovate `fileMatch`/`ignorePaths`
case) than the 30B model: no new pull, stays fully in VRAM, and Qwen3's
thinking mode is purpose-built for exactly this kind of "combine two
facts into a conclusion" task. Add it as a **third** model alongside your
existing `qwen3:14b` and `qwen3-coder:30b` — use it specifically for
questions that need synthesis, keep the fast model as your default.

No pull needed — same `qwen3:14b` weights, different system prompt and
sampling profile.

### Add it as a third model in Open WebUI

**Workspace → Models → `+`**

- **Name**: `DevOps Assistant (docs-first, 14B-reasoning)`
- **Base Model**: `qwen3:14b`
- **System Prompt** — start with `/think` to force thinking mode every
  turn (documented behavior: Qwen3 honors `/think`/`/no_think` placed in
  either the system message or user turns, following the most recent
  instruction), followed by the same rules 1–9 as your other models, plus
  a new rule 10 that shapes what appears in the *visible* answer after
  the model's internal reasoning:

```
/think

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

10. Before giving your final answer to a question that requires connecting more than one fact, explicitly write out: (a) each relevant fact you found, with its source, (b) how those facts interact or constrain each other, (c) the practical conclusion or recommendation that follows. Only then give the final answer.
```

- **Advanced Params** — use Qwen's own recommended sampling profile for
  thinking mode, not the low-temperature profile from your other models
  (low temperature actively degrades thinking-mode output — Qwen's
  guidance warns it causes repetition or getting stuck):
  - `temperature`: `0.6`
  - `top_p`: `0.95`
  - `top_k`: `20`
  - `repeat_penalty`: `1`
  - `num_ctx`: `16384` (or higher if you have headroom — thinking traces
    are verbose)
  - `num_predict` / max tokens: raise this above whatever your other
    models use, or leave unlimited — a capped budget can cut the response
    off mid-reasoning before it ever reaches the visible answer.
  - `Function Calling`: `Native`
- Same capability checkboxes as section 5.

### Why this profile differs from your other two models

Your `qwen3:14b` fast-default and `qwen3-coder:30b` models are both tuned
low-temperature (`0.15`) for citation determinism — appropriate for
straightforward lookups where you want the same reliable answer every
time. This third model trades that off deliberately: higher temperature
and thinking mode both add variability and latency, in exchange for
actually working through multi-fact problems instead of stopping at the
first true statement. Use it selectively, not as your default.

You'll now have three models in the dropdown:
- `qwen3:14b` — fast default, low-temperature, no thinking.
- `qwen3-coder:30b` — heavier, better raw code quality, no thinking mode.
- `qwen3:14b` (reasoning variant) — same weights as the default, but
  thinking-mode on with Qwen's recommended sampling, for questions that
  need facts connected rather than just retrieved.

---

## 9. Optional: switch inference engine to llama.cpp + llama-swap (~15-30% faster)

Ollama is a Go wrapper around llama.cpp — it embeds the same engine but
adds an HTTP/process-management layer on top, which measurably costs
throughput and VRAM headroom (commonly reported around 15-30% slower,
~20% more VRAM used, versus running llama.cpp directly). This section
swaps the `ollama` service for raw `llama.cpp` servers, managed by
**llama-swap** — a small proxy that replicates Ollama's convenient
"auto-load on request, auto-unload after idle, swap between models"
behavior on top of llama.cpp, since llama.cpp's own server only ever
holds one model at a time.

**This is additive, not destructive.** Keep the `ollama` service defined
in `docker-compose.yml` (just stop it, don't delete it) until you've
confirmed llama-swap works end-to-end — GPU offload, tool-calling, and
speed all need re-verifying on the new stack, and you want an easy
fallback if something doesn't translate cleanly.

**The real cost you're taking on**: unlike Ollama, llama.cpp does not
automatically calculate how many model layers fit in your VRAM. You set
`--n-gpu-layers` yourself, per model, and find the right number by trial
and error (start high, back off if it OOMs). For your 14B/7B models this
is a one-time five-minute exercise since they fit entirely in 12GB. For
the 30B model doing partial CPU offload, it's a more deliberate tuning
process — see the note in that model's config below.

### Installing llama.cpp itself

**Short answer: no separate install step for the Docker path below.** The
`ghcr.io/mostlygeek/llama-swap:unified-cuda13` image already contains a
CUDA-compiled `llama-server` binary — llama-swap's whole job is spawning
and managing that binary per model. Once the container is up, confirm
it's actually there and CUDA-enabled:

```bash
docker exec -it llama-swap llama-server --version
docker exec -it llama-swap llama-server --help | grep -i cuda
```

If you only want the Docker-managed path, skip straight to "Add the
llama-swap service" below — there's nothing else to install.

**Optional: a native (non-Docker) build**, if you want direct access to
llama.cpp's own CLI tools — `llama-bench` for precise, repeatable
`--n-gpu-layers` tuning outside the request/response cycle,
`llama-quantize` for producing your own GGUF quantizations, or
`llama-cli` for quick one-off tests without going through llama-swap at
all. This is a heavier prerequisite than anything else in this guide: it
needs the actual CUDA *toolkit* (`nvcc` and headers) installed inside
WSL, not just the driver on Windows that everything else here has relied
on.

```bash
# CUDA toolkit inside WSL (separate from the Windows driver you already have)
wget https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt-get update
sudo apt-get install -y cuda-toolkit-13-0   # match the version to your driver's reported CUDA version

# build tools
sudo apt-get install -y git cmake build-essential

git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j$(nproc)

# binaries land in build/bin/ - e.g. build/bin/llama-server, build/bin/llama-bench
./build/bin/llama-server --version
```

Concrete use for the tuning problem mentioned above — sweep
`--n-gpu-layers` methodically instead of guessing, using a downloaded
GGUF file directly:
```bash
./build/bin/llama-bench -m /path/to/model.gguf -ngl 20,30,40,99
```
This runs a quick benchmark at each layer count in one command and
reports tokens/sec for each — the highest layer count that doesn't OOM
and still reports a sane number is your answer, and you carry that number
back into `config.yaml`'s `--n-gpu-layers` for the equivalent model in
the containerized setup.

Verify the CUDA toolkit version in that `apt-get install` line matches
what your driver actually reports (`nvidia-smi` in WSL) before running
it — installing a mismatched toolkit version is a common source of build
failures that look unrelated to CUDA at first glance.

A native build is a separate binary from what's inside the Docker image —
useful for ad-hoc testing and tuning (particularly `llama-bench` for
finding the right `--n-gpu-layers` number methodically instead of manual
trial and error), but it doesn't replace the containerized llama-swap
setup below for actually serving Open WebUI and `sgpt`; keep both if you
build this, rather than trying to wire the native binary into the
container stack.

### Add the llama-swap service

Add this service to your existing `docker-compose.yml` (alongside, not
replacing, the `ollama` service — stop `ollama` once you've validated
this works):

```yaml
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
```

Notes:
- The `unified-cuda13` tag matches the CUDA 13.x runtime your `nvidia-smi`
  output showed earlier. If your driver reports a CUDA 12.x runtime
  instead, check `https://github.com/mostlygeek/llama-swap` for the
  matching `unified-cuda12` (or equivalent) tag before pulling.
- `gpus: all` — same fix as section 1, for the same reason. Confirm with
  `docker exec -it llama-swap nvidia-smi` after `up`, exactly as before.
- Model files download automatically from Hugging Face into
  `./data/llama-cpp/models` on first use per model (see `-hf` flag below)
  — no separate manual download step, but the first request to a new
  model will be slow while it downloads.
- Port `8090` is deliberately different from Ollama's `11434` so both can
  run side by side during validation.

**Create the config file on the host *before* running `docker compose up`
for this service — this matters, not just a style preference.** Docker
bind-mounts a source path that doesn't exist yet as a *directory*, not a
file. If `./data/llama-swap/config.yaml` doesn't already exist as an
actual file when the container first starts, you'll end up with a
directory of that name instead, and nothing you write afterward will
land in the place llama-swap actually reads from — the failure mode is
usually "can't save the file" or the container silently reading an empty
config. Always create the file first:

```bash
mkdir -p ./data/llama-swap
touch ./data/llama-swap/config.yaml
```

### Create the config file

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

Important caveats on this file, be honest with yourself about these
before trusting it blindly:

- **Verify the `-hf` repo/quant strings before relying on them.** These
  are the most likely-correct Hugging Face repo names for these models
  (official Qwen org GGUF releases), but I can't guarantee the exact
  repo/tag naming hasn't shifted. Test each one standalone first:
  ```bash
  docker exec -it llama-swap llama-server -hf Qwen/Qwen3-14B-GGUF:Q4_K_M --port 9999
  ```
  If the repo/quant string is wrong, this fails loudly with a clear
  download error — not a silent breakage — so it's safe to test. Adjust
  the string to match what you find on `huggingface.co` if it doesn't
  resolve (search the model name + "GGUF"; official Qwen org, or
  well-known quantizers like `bartowski` or `unsloth`, are reliable
  sources).
- **`--jinja` is required** for proper chat-template/tool-call formatting
  on these models — without it, tool calling for the web-search flow is
  likely to break or degrade, mirroring the Qwen2.5-Coder tool-format
  issues from earlier in this guide.
- **`--flash-attn` needs an explicit value** (`on`/`off`/`auto`) on this
  build — passing it as a bare boolean flag makes `llama-server` exit
  immediately with an argument-parsing error, before it ever attempts to
  load the model. If you ever see `process exited: code=1` in
  `docker logs llama-swap` with almost no elapsed time (versus a slow
  failure, which usually means a download/timeout issue instead), run
  the exact command from the log manually to see `llama-server`'s actual
  error text — flag syntax has shifted across llama.cpp versions before
  and may again.
- **`--n-gpu-layers 20` on `power-30b` is a starting guess, not a
  verified number.** Unlike Ollama, llama.cpp won't automatically back
  off if this doesn't fit — it'll error or OOM. Tune it:
  1. Start it manually (`docker exec -it llama-swap llama-server -hf
     Qwen/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_M --port 9999
     --n-gpu-layers 99`) and watch for an out-of-memory error.
  2. If it OOMs, lower `--n-gpu-layers` in steps of ~5-10 and retry.
  3. Once it loads without error, watch `nvidia-smi` during a real
     generation to confirm VRAM usage sits comfortably under 12GB with
     some headroom, then lock that number into `config.yaml`.
- **Thinking mode** is still controlled the same way as Ollama — `/think`
  / `/no_think` in the prompt or system message — there's no separate
  llama.cpp CLI flag for it; the `--temp`/`--top-p`/`--top-k` flags on
  `power-reasoning` just match Qwen's recommended sampling profile from
  section 8.

Apply:
```bash
docker compose up -d llama-swap
```

### Point Open WebUI at it

llama-swap speaks the **OpenAI-compatible API**, not Ollama's native API
— so this isn't a case of swapping `OLLAMA_BASE_URL` for a new host, it's
a different connection type entirely in Open WebUI. Do this through the
UI rather than env vars, for the same reason manual model creation beat
JSON import earlier — it's the version-stable path:

**Admin Settings → Connections → Add Connection → OpenAI API**
- **Base URL**: `http://llama-swap:8080/v1`
- **API Key**: any non-empty placeholder (e.g. `sk-local-no-auth`) —
  llama-swap doesn't enforce one, but Open WebUI's OpenAI-connection form
  typically requires a non-empty value.
- Save, then confirm the `quick`, `power`, `power-reasoning`, and
  `power-30b` model names appear as selectable models.

Your existing custom models (`DevOps Assistant (docs-first)`, etc.) were
built on Ollama base models — recreate them the same manual way as
section 5, just pointing the **Base Model** field at the new OpenAI
connection's `power` (or `power-reasoning`) model instead of `qwen3:14b`.

### Point sgpt at it

```bash
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

### Verify it's actually faster (don't just assume the headline number)

Re-run the exact same tokens/sec check from section 1, against the same
model, so you're comparing like-for-like on your own hardware rather than
trusting the general 15-30% figure:

```bash
docker logs -f llama-swap
```

Ask the same kind of question you benchmarked Ollama with earlier and
compare the `t/s` figure directly against your earlier `39.52 t/s`
baseline on `qwen3:14b`.

### Once confirmed working

```bash
docker compose stop ollama
```

Keep the `ollama` service definition in the compose file for a while
longer rather than deleting it outright — cheap insurance while you run
the new stack for real, in case something (tool-calling reliability,
a specific model's behavior) doesn't hold up the same way under
llama.cpp as it did under Ollama.
