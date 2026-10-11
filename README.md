# SnapHop Local AI Stack

A reproducible local AI inference and API gateway stack optimized for the **NVIDIA DGX Spark** (NVIDIA GB10 Blackwell GPU, 121 GB unified memory, ARM64).

[![Verify](https://github.com/snaphop/snaphop-local-ai-stack/actions/workflows/verify.yml/badge.svg)](https://github.com/snaphop/snaphop-local-ai-stack/actions/workflows/verify.yml)

Licensed under [MIT](LICENSE). See [CONTRIBUTING.md](CONTRIBUTING.md) and
[SECURITY.md](SECURITY.md). Images and model weights retain their upstream licenses.

---

## Architecture Overview

```
+-----------------------------------------------------------------------------------+
|                                  Local Network                                    |
|       (Localhost: 127.0.0.1; external access is operator-configured)        |
+-----------------------------------------+-----------------------------------------+
                                          |
                      +-------------------+-------------------+
                      |                                       |
                      v Port 4000                             v Port 5433
+-------------------------------------------+   +-----------------------------------+
|           LiteLLM Proxy Gateway           |   |       PostgreSQL 18 RAG DB        |
| (ghcr.io/berriai/litellm, 8 workers)      |   |        (`rag-db`, pgvector 0.8.7) |
|                                           |   |                                   |
| - OpenAI API (/v1/chat/completions)       |   | - pgvector HNSW ANN Index         |
| - Anthropic API (/v1/messages)            |   | - Knowledge Base & Document Chunks|
| - Admin Web UI (/ui)                      |   | - Volume: rag-data                |
+----+-------------------+-------------+----+   +-----------------+-----------------+
     |                   |             |                          |
     |                   |             | (Internal Docker `llm`)  |
     v                   v             +--------------------------+
+-----------------+ +-----------------+ +-------------------------------------------+
|  PostgreSQL 16  | |  Redis 7 Cache  | |                vLLM Engine                |
|  (`litellm-db`) | |    (`redis`)    | |                  (`vllm`)                 |
|                 | |                 | |                                           |
| - LiteLLM State | | - Distributed   | | - Qwen3.8-27B-FP8 (Blackwell sm_121)      |
| - Virtual Keys  | |   Rate Limiting | | - High-Throughput Inference Engine        |
| - Volume: data  | | - State Sync    | | - Port: 8000 (loopback)                   |
+-----------------+ +-----------------+ +-------------------------------------------+
```

---

## Quickstart

### 1. Prerequisites
- Docker & Docker Compose (`docker compose version` >= 2.20)
- NVIDIA Container Toolkit (`nvidia-ctk`)
- NVIDIA Driver 580+ (CUDA 13.0 host / CUDA 13.4 Forward Compatibility)

### 2. Configure Environment
Clone the public repository and copy the example environment file:
```bash
git clone https://github.com/snaphop/snaphop-local-ai-stack.git
cd snaphop-local-ai-stack
cp .env.example .env
```
Set unique `LITELLM_MASTER_KEY`, `POSTGRES_PASSWORD`, `RAG_DB_PASSWORD`, and
`LITELLM_ADMIN_PASSWORD` values in `.env` before starting. A master key must use
LiteLLM's `sk-` prefix; generate one locally with `printf 'sk-'; openssl rand -hex 32`.
The admin password must be at least 12 characters and include an uppercase letter,
a lowercase letter, a digit, and a special character. `.env` values are literal:
`$` and quotes are not expanded. Use URL-safe database passwords because they are
embedded in the database URL. `.env` is ignored by Git; keep it private. No working
passwords are supplied.

Services bind to loopback by default. Set `LITELLM_BIND_ADDRESS` or
`RAG_DB_BIND_ADDRESS` only if you intend external access and have configured
appropriate authentication, firewall rules, and TLS. The unauthenticated vLLM
backend stays on loopback.

Ensure your Hugging Face token is set if required for downloading gated weights:
```bash
# Edit .env or export HF_TOKEN
export HF_TOKEN="hf_..."
```

### 3. Launch Stack
Start all services in the background:
```bash
make up
# Or: docker compose up -d
```
On first start, vLLM will download/load model weights from `~/.cache/huggingface` and warm up the CUDA graphs and FlashInfer kernels (~80-120s).

### 4. Check Status
```bash
make status
# Shows container status and GPU memory/utilization
```

---

## Teardown & Lifecycle Commands

The stack can be controlled using simple `make` commands:

| Command | Description |
| :--- | :--- |
| `make up` | Start or rebuild the entire stack in the background |
| `make down` | Stop all containers gracefully without losing data |
| `make restart` | Restart all running containers |
| `make status` | View container health (`docker compose ps`) and GPU metrics (`nvidia-smi`) |
| `make logs` | Stream logs from all containers |
| `make logs-vllm` | Stream vLLM engine logs |
| `make logs-litellm` | Stream LiteLLM gateway logs |
| `make test` | Run automated inference test suite against both OpenAI & Anthropic endpoints |
| `make test-rag` | Run PostgreSQL 18 pgvector RAG test suite |
| `make benchmark` | Run vLLM benchmark suite (e.g. `make benchmark PROMPTS=20`) |
| `make teardown` | Stop stack and remove orphan containers |
| `make clean-all` | **Caution**: Stops stack and deletes persistent database volumes (`litellm-data`, `rag-data`) |

---

## API Usage

LiteLLM exposes standard OpenAI and Anthropic endpoints on port `4000`.
Create a scoped virtual key in the admin UI and set `LITELLM_API_KEY` in your
client environment before running these examples.

### 1. OpenAI-Compatible Chat Completion
```bash
curl -X POST http://127.0.0.1:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_API_KEY}" \
  -d '{
    "model": "qwen",
    "messages": [
      {"role": "user", "content": "What is 123 * 456? Answer only the number."}
    ],
    "temperature": 0.7,
    "max_tokens": 50
  }'
```

### 2. Streaming Responses
```bash
curl -N -X POST http://127.0.0.1:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LITELLM_API_KEY}" \
  -d '{
    "model": "qwen",
    "messages": [
      {"role": "user", "content": "Count from 1 to 5 slowly."}
    ],
    "stream": true
  }'
```

### 3. Anthropic Messages Format
```bash
curl -X POST http://127.0.0.1:4000/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${LITELLM_API_KEY}" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "qwen",
    "max_tokens": 50,
    "messages": [
      {"role": "user", "content": "Hello via Anthropic protocol!"}
    ]
  }'
```

### 4. Python OpenAI Client Example
```python
import os
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:4000/v1",
    api_key=os.environ["LITELLM_API_KEY"]
)

response = client.chat.completions.create(
    model="qwen",
    messages=[{"role": "user", "content": "Hello!"}],
    max_tokens=100
)
print(response.choices[0].message.content)
```

---

## Admin Web UI & Security

- **URL**: `http://127.0.0.1:4000/ui` (or `http://localhost:4000/ui`)
- **Authentication**:
  - `disable_env_credential_login: true` is configured in `config/litellm_config.yaml`.
  - The shared master key cannot be used to sign into the UI via the web form.
  - Sign in using your registered admin email and password.
- **Initial Admin Bootstrapping**:
  - On a fresh setup or after database recreation, `make up` automatically runs `./scripts/bootstrap_admin.sh` via the administrative REST API.
  - It creates the initial `proxy_admin` account defined in `.env` (`LITELLM_ADMIN_EMAIL` and `LITELLM_ADMIN_PASSWORD`) and checks that this password can sign in. A later run does that check again. If the sign-in fails, bootstrap sets the `.env` password once more.
  - The first UI sign-in must choose a new password. LiteLLM flags passwords set through the admin API.
  - Put the password in `.env`. To override it without Make interpreting `$`, export it in the environment: `EMAIL='operator@example.com' PASSWORD='...' make bootstrap-admin`.
- **Adding Users**:
  - Navigate to the **Users** tab (`/ui/users`).
  - Click **`+ Invite User`**.
  - Enter the user email and assign role (`Admin` or `Internal User`).
  - Copy the invitation link to set the user's password.
- **Virtual Keys**:
  - Go to the **Virtual Keys** tab to create scoped API keys with rate limits, spend caps, or team assignments.

---

## Blackwell Performance Optimizations

The stack incorporates the following hardware-tailored flags:

| Flag / Setting | Value | Rationale |
| :--- | :--- | :--- |
| `--gpu-memory-utilization` | `0.76` | Allocates ~59.6 GiB KV cache (~849,237 tokens, 25.9x parallel 32k context) while leaving >16 GiB system RAM free |
| `CUDA_DEVICE_MAX_CONNECTIONS` | `1` | Limits the process to one concurrent CUDA device connection |
| `--max-num-seqs` | `64` | Removes concurrency bottleneck, enabling up to 64 parallel decode streams |
| `--max-num-batched-tokens` | `8192` | 4x larger prefill batch size maximizing Blackwell Tensor Core compute efficiency |
| `--async-scheduling` | Enabled | Overlaps CPU host scheduler steps with GPU kernel execution |
| `--num_workers` (LiteLLM) | `8` | Scales across the 20 ARM64 CPU cores (10 Cortex-X925 + 10 Cortex-A725) for high-concurrency gateway throughput |
| PostgreSQL 18 Buffer Tuning | `shared_buffers=2GB`, `maintenance_work_mem=1GB`, `shm_size=2GB` | Parallel index builds allocate dynamic shared memory in `/dev/shm`; Docker's 64MB default is too small for 8 workers |
| Redis In-Memory Limits | `1GB` maxmemory, `allkeys-lru` | High-throughput distributed rate limiting and state sync with 1024 socket backlog |

### Benchmark Results (30 Concurrent Requests)
- **Request Throughput**: 1.12 req/s (2.4x higher than 16-seq baseline)
- **Total Token Throughput**: **644.55 tokens/sec**
- **Peak Output Throughput**: **180.00 tokens/sec**
- **Success Rate**: 100% (0 errors across all 30 parallel requests)

---

## PostgreSQL 18 pgvector RAG Service

A dedicated vector database container (`rag-db`) running official **PostgreSQL 18.6** and **pgvector 0.8.7** is included for Retrieval-Augmented Generation workflows.

- **Image**: `pgvector/pgvector:pg18`
- **Host Port**: `5433` (`127.0.0.1:5433->5432`)
- **Internal Network**: `rag-db:5432` on bridge network `llm`
- **Database / User / Password**: `rag` / `rag` / operator-provided `RAG_DB_PASSWORD` in `.env`
- **Persistent Volume**: `rag-data` (mapped at `/var/lib/postgresql`)
- **Auto-Initialization**: [`config/init-rag.sql`](config/init-rag.sql) sets up:
  - `vector` extension (v0.8.7) & `pgcrypto` for UUID generation
  - `rag_documents`: parent documents and metadata
  - `rag_chunks`: text chunks with 1536-dimensional embeddings
  - HNSW Index (`rag_chunks_embedding_hnsw_idx`) using cosine similarity (`vector_cosine_ops`)
  - GIN Full-Text Index (`rag_chunks_content_tsv_idx`) for the optional lexical term
  - Helper SQL function: `match_rag_chunks(query_embedding, match_threshold, match_count, query_text)`. Without `query_text` the score is cosine similarity. With it, the score adds English `ts_rank` from the GIN index.
  - The init script runs when the `rag-data` volume is first created. On an existing volume, apply `config/init-rag.sql` again to replace `match_rag_chunks`.

### Testing the RAG Pipeline
Run the automated end-to-end RAG verification test:
```bash
make test-rag
```
This test:
1. Validates PostgreSQL 18 and pgvector extension health.
2. Seeds test knowledge documents into `rag_documents` and `rag_chunks`.
3. Checks that the HNSW index exists and calls `match_rag_chunks` with a query vector that is not a stored embedding.
4. Feeds the retrieved chunk context into LiteLLM (`qwen`), validating that the model synthesizes a grounded answer.

---

## Project Structure

```
snaphop-local-ai-stack/
├── .env.example              # Documented environment variable template
├── .env                      # Active local secrets & configuration (git-ignored)
├── .gitignore                # Git ignore rules for secrets and temporary files
├── docker-compose.yml        # Multi-container orchestration definition
├── Makefile                  # Lifecycle management shortcuts
├── README.md                 # Complete documentation & usage guide
├── config/
│   ├── init-rag.sql          # PostgreSQL 18 pgvector schema & HNSW index init
│   └── litellm_config.yaml   # LiteLLM routing rules, aliases, and security
└── scripts/
    ├── load_env.sh           # Literal .env loader shared by the scripts
    ├── bootstrap_admin.sh    # Admin account bootstrap and sign-in check
    ├── test_inference.sh     # Comprehensive inference verification script
    ├── test_rag.sh           # PostgreSQL 18 pgvector RAG test suite
    └── benchmark.sh          # vLLM serving benchmark runner
```

## Verification and project history

Run `make check` for static checks without a GPU or running services. GitHub
Verify runs this same command. `make test` and `make test-rag` require an
operator-configured, disposable GPU stack; the RAG test modifies test records.

The project moved from Gitea to GitHub. Imported revisions retain their authors,
dates, messages, and ordering, with embedded credentials and operator-specific
addresses replaced throughout history. This changes their commit IDs. Credentials
previously committed to Gitea must be rotated before reuse. See
[docs/migration.md](docs/migration.md) for migration scope.
