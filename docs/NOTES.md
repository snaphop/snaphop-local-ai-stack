# Local vLLM Inference Deployment Notes

## System Configuration
- **Hardware**: NVIDIA DGX Spark-class system
  - GPU: 1x NVIDIA GB10 (Blackwell, sm_121)
  - CPU: aarch64 (Cortex-X925/A725, 20 cores)
  - Memory: 121 GB unified CPU/GPU memory
  - OS: Ubuntu 24.04, Kernel 7.0 nvidia
  - Driver: 580.178.04, CUDA 13.0 host / CUDA 13.4 Forward Compatibility in container
- **Container Image**: `nvcr.io/nvidia/vllm:26.09-py3`
  - vLLM version: `0.29.0+5013de39`
  - Architecture support: `Qwen3_5ForConditionalGeneration` native support confirmed

## Deployed Model
- **Model**: `Qwen/Qwen3.8-27B-FP8` (Alibaba Qwen, 27.8B parameters, FP8 fine-grained block size 128)
- **Disk Footprint**: ~28.75 GiB safetensors checkpoint shards in `~/.cache/huggingface`
- **Memory Footprint**:
  - Model weights + base: ~30.74 GiB
  - KV Cache allocation: ~59.56 GiB (~849,237 tokens KV cache size, max concurrency 25.92x for 32,768 ctx)
  - Total process memory: ~91.5 GiB (leaving >16 GiB available unified system memory for PostgreSQL buffers, Redis, OS, & host services)

## Container Launch Command
```bash
docker run -d --name vllm --gpus all --ipc=host --restart always \
  --dns 1.1.1.1 --dns 8.8.8.8 \
  --ulimit memlock=-1 --ulimit stack=67108864 --ulimit nofile=65536:65536 \
  -p 127.0.0.1:8000:8000 \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  -v ~/.cache/vllm:/root/.cache/vllm \
  -e HF_TOKEN="$HF_TOKEN" \
  -e CUDA_DEVICE_MAX_CONNECTIONS=1 \
  nvcr.io/nvidia/vllm:26.09-py3 \
  vllm serve Qwen/Qwen3.8-27B-FP8 \
    --gpu-memory-utilization 0.76 \
    --max-model-len 32768 \
    --max-num-seqs 64 \
    --max-num-batched-tokens 8192 \
    --async-scheduling \
    --enable-prefix-caching \
    --speculative-config '{"method":"mtp","num_speculative_tokens":3}' \
    --enable-auto-tool-choice \
    --tool-call-parser qwen3_coder \
    --reasoning-parser qwen3
```

> **Performance Optimizations Applied**:
> - **KV Cache Expansion (`--gpu-memory-utilization 0.76`)**: Allocates ~59.56 GiB KV cache (849,237 tokens capacity, 25.92x concurrency at 32k context).
> - **CUDA Device Connections (`CUDA_DEVICE_MAX_CONNECTIONS=1`)**: Limits the process to one concurrent CUDA device connection. Overlap of scheduling and kernels is `--async-scheduling`.
> - **Batch Concurrency (`--max-num-seqs 64`)**: Eliminates the 16-request queue bottleneck, enabling up to 64 requests to decode concurrently.
> - **Prefill Acceleration (`--max-num-batched-tokens 8192`)**: Uses 4x larger prefill token batches for higher Blackwell Tensor Core utilization.
> - **Asynchronous Scheduling (`--async-scheduling`)**: Overlaps CPU scheduler iterations with GPU kernel execution.
> - **Prefix caching (`--enable-prefix-caching`)**: Reuses a shared prompt prefix. This image already enabled it for the hybrid model; the flag keeps that explicit.
> - **MTP speculative decoding (`num_speculative_tokens` 3)**: The FP8 checkpoint has one MTP layer (`mtp_num_hidden_layers: 1`). vLLM reruns that layer to draft 3 tokens and keeps a draft only when the target model would have emitted it. On this host, one stream moved from 8.4 tokens/s to about 17 tokens/s, with a mean acceptance length of about 3.0 and a draft acceptance rate of about 65%. `VLLM_SPECULATIVE_TOKENS=8` is the edit-heavy alternative reported for this GPU; it was not remeasured here.
> - **LiteLLM Multi-Worker Scaling (`--num_workers 8`)**: Scales across the 20 ARM64 cores (10 Cortex-X925 + 10 Cortex-A725).
> - **PostgreSQL 18 Vector Tuning**: 2GB `shared_buffers`, 1GB `maintenance_work_mem`, 64MB `work_mem`, 8 parallel workers, and a 2GB `/dev/shm` so those workers can allocate dynamic shared memory.
> - **Redis 7 In-Memory Caching**: 1GB maxmemory with LRU eviction and 1024 connection backlog.

## Verification & High-Concurrency Benchmarks
- **Models Endpoint**: `GET http://127.0.0.1:8000/v1/models` returns `Qwen/Qwen3.8-27B-FP8`.
- **Single-stream decode (MTP, 3 draft tokens, 256 output tokens)**: about 17 tokens/s, up from 8.4 tokens/s with speculative decoding off. Engine metrics: mean acceptance length about 3.0, draft acceptance about 65%.
- **Serving Benchmark (30 Concurrent Requests, before MTP)**:
  - Request throughput: **1.12 req/s** (2.4x higher than 16-seq baseline)
  - Total token throughput: **644.55 tokens/sec**
  - Peak output token throughput: **180.00 tokens/sec**
  - Success rate: **100%** (0 failed requests)

## LiteLLM Gateway
- **Proxy Container**: `litellm` (`ghcr.io/berriai/litellm:main-latest`)
- **Database Container**: `litellm-db` (`postgres:16-alpine`, volume: `litellm-data`)
- **Cache & Coordination**: `redis` (`redis:7-alpine`, multi-worker rate limiting & distributed state)
- **Port**: `4000` on loopback by default (`127.0.0.1:4000`). Set `LITELLM_BIND_ADDRESS` to publish on another address.
- **Master API Key**: operator-provided `LITELLM_MASTER_KEY`
- **Supported Model Aliases** (all route to `VLLM_MODEL`; the default is `Qwen/Qwen3.8-27B-FP8`):
  - `VLLM_MODEL` -> `openai/$VLLM_MODEL` on the local vLLM server
  - `qwen` -> the same local model
  - `qwen3.8-27b` -> the same local model
- **Supported Protocols**:
  - OpenAI format: `http://<IP>:4000/v1/chat/completions` (Header: `Authorization: Bearer <key>`)
  - Anthropic Messages format: `http://<IP>:4000/v1/messages` (Header: `x-api-key: <key>`)
  - Admin Web UI: `http://<IP>:4000/ui` (Persistent user accounts & virtual key management enabled)
- **Security & Admin UI Auth**:
  - `disable_env_credential_login: true`: Master key and static env credentials cannot be used to log into the Web UI.
  - Users sign in using registered database credentials (`admin@example.com`).
  - `master_key` is retained solely for administrative API / programmatic requests.
  - **Fresh Setup Bootstrap**: To resolve the LiteLLM lockout risk on a brand new setup (where no DB users exist yet and env-credential login is off), `scripts/bootstrap_admin.sh` (or `make bootstrap-admin`) uses the administrative REST API with `master_key` to automatically provision the initial `proxy_admin` account defined in `.env`.

## PostgreSQL 18 pgvector RAG Service
- **Container**: `rag-db` (`pgvector/pgvector:pg18`)
- **Versions**: PostgreSQL 18.6, pgvector v0.8.7
- **Ports**: `5433` (Host accessible `localhost:5433`), `5432` (Internal Docker network `llm`)
- **Volume**: `rag-data` (PostgreSQL 18 data cluster at `/var/lib/postgresql`)
- **Schema**:
  - `rag_documents`: Parent documents, title, source, metadata JSONB
  - `rag_chunks`: Chunks with `vector(1536)` embeddings
  - HNSW index: `rag_chunks_embedding_hnsw_idx` on cosine distance (`vector_cosine_ops`, `m=16`, `ef_construction=64`)
  - GIN index: `rag_chunks_content_tsv_idx` for hybrid full-text search
- **Verification**: `make test-rag` (`scripts/test_rag.sh`)
