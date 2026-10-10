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
  - Model weights + base: ~28.5 GiB
  - KV Cache allocation: ~54.49 GiB (~776,874 tokens KV cache size, max concurrency 23.71x for 32,768 ctx)
  - Total process memory: ~87.6 GiB (leaving >22 GiB available unified system memory for OS, caches, & host services)

## Container Launch Command
```bash
docker run -d --name vllm --gpus all --ipc=host --restart always \
  --dns 1.1.1.1 --dns 8.8.8.8 \
  --ulimit memlock=-1 --ulimit stack=67108864 \
  -p 127.0.0.1:8000:8000 \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  -v ~/.cache/vllm:/root/.cache/vllm \
  -e HF_TOKEN="$HF_TOKEN" \
  nvcr.io/nvidia/vllm:26.09-py3 \
  vllm serve Qwen/Qwen3.8-27B-FP8 \
    --gpu-memory-utilization 0.72 \
    --max-model-len 32768 \
    --max-num-seqs 64 \
    --max-num-batched-tokens 8192 \
    --async-scheduling \
    --enable-auto-tool-choice \
    --tool-call-parser qwen3_coder \
    --reasoning-parser qwen3
```

> **Performance Optimizations Applied**:
> - **KV Cache Expansion (`--gpu-memory-utilization 0.72`)**: Increases token cache capacity to 776,874 tokens (+39% larger than 0.6 baseline).
> - **Batch Concurrency (`--max-num-seqs 64`)**: Eliminates the 16-request queue bottleneck, enabling up to 64 requests to decode concurrently.
> - **Prefill Acceleration (`--max-num-batched-tokens 8192`)**: Uses 4x larger prefill token batches for higher Blackwell Tensor Core utilization.
> - **Asynchronous Scheduling (`--async-scheduling`)**: Overlaps CPU scheduler iterations with GPU kernel execution.
> - **LiteLLM Multi-Worker Scaling (`--num_workers 4`)**: Distributes gateway request parsing and streaming across host ARM64 cores.

## Verification & High-Concurrency Benchmarks
- **Models Endpoint**: `GET http://127.0.0.1:8000/v1/models` returns `Qwen/Qwen3.8-27B-FP8`.
- **Serving Benchmark (30 Concurrent Requests)**:
  - Request throughput: **1.12 req/s** (2.4x higher than 16-seq baseline)
  - Total token throughput: **644.55 tokens/sec**
  - Peak output token throughput: **180.00 tokens/sec**
  - Success rate: **100%** (0 failed requests)

## LiteLLM Gateway
- **Proxy Container**: `litellm` (`ghcr.io/berriai/litellm:main-latest`)
- **Database Container**: `litellm-db` (`postgres:16-alpine`, volume: `litellm-data`)
- **Port**: `4000` (LAN accessible via `127.0.0.1:4000` or Tailscale `100.64.0.1:4000`)
- **Master API Key**: `REPLACE_WITH_UNIQUE_SECRET`
- **Supported Model Aliases**:
  - `Qwen/Qwen3.8-27B-FP8` -> local `Qwen/Qwen3.8-27B-FP8`
  - `qwen` -> local `Qwen/Qwen3.8-27B-FP8`
  - `qwen3.8-27b` -> local `Qwen/Qwen3.8-27B-FP8`
- **Supported Protocols**:
  - OpenAI format: `http://<IP>:4000/v1/chat/completions` (Header: `Authorization: Bearer <key>`)
  - Anthropic Messages format: `http://<IP>:4000/v1/messages` (Header: `x-api-key: <key>`)
  - Admin Web UI: `http://<IP>:4000/ui` (Persistent user accounts & virtual key management enabled)
- **Security & Admin UI Auth**:
  - `disable_env_credential_login: true`: Master key and static env credentials cannot be used to log into the Web UI.
  - Users sign in using registered database credentials (`admin@example.com`).
  - `master_key` is retained solely for administrative API / programmatic requests.
  - **Fresh Setup Bootstrap**: To resolve the LiteLLM lockout risk on a brand new setup (where no DB users exist yet and env-credential login is off), `scripts/bootstrap_admin.sh` (or `make bootstrap-admin`) uses the administrative REST API with `master_key` to automatically provision the initial `proxy_admin` account defined in `.env`.

