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
    └── searxng/        (created automatically on first `up`)
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
