# SnapHop Local AI Stack

A production-grade, reproducible local AI inference and API gateway stack optimized for the **NVIDIA DGX Spark** (NVIDIA GB10 Blackwell GPU, 121 GB unified memory, ARM64).

---

## Architecture Overview

```
+-------------------------------------------------------------------------+
|                              Local Network                              |
|   (LAN: 127.0.0.1 / Tailscale: 100.64.0.1 / Localhost: 127.0.0.1)  |
+------------------------------------+------------------------------------+
                                     |
                                     v Port 4000
+-------------------------------------------------------------------------+
|                        LiteLLM Proxy Gateway                            |
|             (ghcr.io/berriai/litellm, 4 worker processes)               |
|                                                                         |
|  - OpenAI API (/v1/chat/completions)                                    |
|  - Anthropic API (/v1/messages)                                         |
|  - Admin Web UI (/ui)                                                   |
|  - Virtual Keys, Rate Limiting, & Usage Tracking                        |
+-------------------+---------------------------------+-------------------+
                    |                                 |
                    v (Internal Docker Network `llm`) v
+------------------------------------+   +--------------------------------+
|       PostgreSQL 16 Database       |   |          vLLM Engine           |
|          (`litellm-db`)            |   |             (`vllm`)           |
|                                    |   |                                |
|  - User & Admin Accounts           |   |  - Model: Qwen3.8-27B-FP8      |
|  - Virtual API Keys                |   |  - Blackwell sm_121 Native     |
|  - Persistent Volume `litellm-data`|   |  - AOT Compile & FlashInfer    |
+------------------------------------+   |  - Port: 8000 (Internal)       |
                                         +--------------------------------+
```

---

## Quickstart

### 1. Prerequisites
- Docker & Docker Compose (`docker compose version` >= 2.20)
- NVIDIA Container Toolkit (`nvidia-ctk`)
- NVIDIA Driver 580+ (CUDA 13.0 host / CUDA 13.4 Forward Compatibility)

### 2. Configure Environment
Copy the example environment file:
```bash
cp .env.example .env
```
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
| `make benchmark` | Run vLLM benchmark suite (e.g. `make benchmark PROMPTS=20`) |
| `make teardown` | Stop stack and remove orphan containers |
| `make clean-all` | **Caution**: Stops stack and deletes the persistent database volume |

---

## API Usage

LiteLLM exposes standard OpenAI and Anthropic endpoints on port `4000`.

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
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:4000/v1",
    api_key="REPLACE_WITH_UNIQUE_SECRET"
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
  - It creates the initial `proxy_admin` account defined in `.env` (`LITELLM_ADMIN_EMAIL` and `LITELLM_ADMIN_PASSWORD`).
  - You can also manually provision or reset an admin user at any time:
    ```bash
    make bootstrap-admin EMAIL=admin@example.com PASSWORD=SecretPassword123!
    ```
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

| Flag | Value | Rationale |
| :--- | :--- | :--- |
| `--gpu-memory-utilization` | `0.72` | Allocates ~54.5 GiB KV cache (~776,874 tokens) while leaving >22 GiB system RAM free |
| `--max-num-seqs` | `64` | Removes 16-request concurrency bottleneck, enabling up to 64 parallel decode streams |
| `--max-num-batched-tokens` | `8192` | 4x larger prefill batch size maximizing Blackwell Tensor Core compute efficiency |
| `--async-scheduling` | Enabled | Overlaps CPU host scheduler steps with GPU kernel execution |
| `--num_workers` | `4` | Scales LiteLLM gateway across ARM64 host cores |

### Benchmark Results (30 Concurrent Requests)
- **Request Throughput**: 1.12 req/s (2.4x higher than 16-seq baseline)
- **Total Token Throughput**: **644.55 tokens/sec**
- **Peak Output Throughput**: **180.00 tokens/sec**
- **Success Rate**: 100% (0 errors across all 30 parallel requests)

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
│   └── litellm_config.yaml   # LiteLLM routing rules, aliases, and security
└── scripts/
    ├── bootstrap_admin.sh    # Idempotent admin account bootstrapper
    ├── test_inference.sh     # Comprehensive inference verification script
    └── benchmark.sh          # vLLM serving benchmark runner
```
