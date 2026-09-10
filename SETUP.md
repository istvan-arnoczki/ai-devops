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
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
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

export OPENAI_API_BASE=http://localhost:11434/v1
export OPENAI_API_KEY=ollama
export SGPT_DEFAULT_MODEL=qwen2.5-coder:7b
```

Add these exports to `~/.bashrc` (or your WSL shell profile) so they
persist.

```bash
sgpt "explain this renovate.json error: <paste>"
```

Note: `sgpt` is stateless and doesn't get the system prompt or web-search
setup below — it's a plain, fast Q&A path for quick lookups. Use Open WebUI
when you want the docs-first/web-fallback behavior with citations.

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

Add to the `ollama` service's `environment:` in `docker-compose.yml`:

```yaml
    environment:
      - OLLAMA_KV_CACHE_TYPE=q8_0     # shrinks KV cache memory, helps fit more on GPU
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

