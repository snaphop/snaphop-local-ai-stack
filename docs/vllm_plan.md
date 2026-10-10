# Plan: Local vLLM inference on this machine

## Machine facts (verified)
- **NVIDIA DGX Spark-class box**: GPU = NVIDIA GB10 (Blackwell, sm_121), **aarch64** (Cortex-X925/A725, 20 cores), Ubuntu 24.04, kernel 7.0 nvidia.
- **121 GB unified CPU/GPU memory** (nvidia-smi shows memory "Not Supported"; use `free -h`). 15 GB swap, 2.5 TB disk free.
- Driver 580.178.04, CUDA 13.0 (`/usr/local/cuda`, nvcc 13.0). Python 3.12.3, miniconda present, `uv` NOT installed.
- Docker 29.6.2 works for user (in `docker` group). `nvidia-container-toolkit` 1.20.1 **is installed**, but `/etc/docker/daemon.json` has no nvidia runtime and `docker info` lists only `runc`, so the Docker GPU config step (Step 1) is needed. Passwordless sudo works. Running containers: `postgresql-pgvector`, `watchtower` (Open WebUI is pulled but not running). Docker live-restore is off, so restarting docker restarts those containers.
- `HF_TOKEN` is already set in the environment. **Never write it into files, logs or commands. Reference `$HF_TOKEN` only.**
- vllm/torch are not installed. No HF cache yet.

## Key constraints
1. GB10 is sm_121 on aarch64. A plain `pip install vllm` often pulls wheels without proper sm_121 or aarch64+CUDA 13 support. Prefer the **official NVIDIA NGC vLLM container**, which is built for DGX Spark. Use a pip/uv install only as a fallback.
2. Memory is unified. Set `--gpu-memory-utilization` conservatively (0.6–0.8). Going too high can starve the OS and freeze the box. Other things on the host (open-webui) share this memory.
3. Memory bandwidth (~273 GB/s) is the decode bottleneck, so quantized models (FP8/NVFP4/AWQ) run much faster than BF16.

## Step 0: Pre-flight
```bash
nvidia-smi; free -h; df -h ~; docker ps
docker run --rm --gpus all nvcr.io/nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi
```
If the last command fails with a runtime error, fix the NVIDIA container toolkit (Step 1). If it works, skip to Step 2.

## Step 1: Enable GPU in Docker (only if needed)
```bash
# toolkit is already installed (1.20.1); no apt install needed
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker info | grep -i runtimes                     # expect "nvidia"
```
`nvidia-ctk` merges into `/etc/docker/daemon.json` (it has custom log, dns and bip settings), so back it up first: `sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak`, and confirm those keys survive. Restarting docker briefly restarts `postgresql-pgvector` and `watchtower`. Warn the user, and do it only when nothing depends on pgvector. If `--gpus all` still fails afterwards, the alternative is `--runtime=nvidia` on `docker run`.

## Step 2: Choose the vLLM image (Path A, preferred)
1. Look up the current DGX Spark vLLM guidance and pick the image tag: <https://build.nvidia.com/spark> (vLLM playbook) and the NGC catalog `nvcr.io/nvidia/vllm`. Tags look like `nvcr.io/nvidia/vllm:26.04-py3` or newer. Use the newest tag that supports GB10. Pin it by tag and don't use `latest`. **Qwen3.8 uses the new `Qwen3_5ForConditionalGeneration` architecture (hybrid linear + full attention), so confirm the image's vLLM is recent enough** (`docker run --rm <image> vllm --version`, then compare it with the minimum version in the vLLM recipe <https://recipes.vllm.ai/Qwen/Qwen3.8-27B>). If the NGC image is too old, use a newer NGC tag, or the community Spark build `eugr/spark-vllm-docker` (clone and follow its README). Ask the user before using a non-NVIDIA image.
2. `docker pull nvcr.io/nvidia/vllm:<tag>`. The image is large (~10+ GB). If the pull needs NGC login, ask the user for an NGC key. Don't guess.

## Step 3: Serve a first model
Start with the quantized variant, then try larger ones.
```bash
mkdir -p ~/workspace/vllm && cd ~/workspace/vllm
docker run -d --name vllm --gpus all --ipc=host --restart unless-stopped \
  -p 127.0.0.1:8000:8000 \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  -e HF_TOKEN="$HF_TOKEN" \
  nvcr.io/nvidia/vllm:<tag> \
  vllm serve Qwen/Qwen3.8-27B-FP8 \
    --gpu-memory-utilization 0.6 --max-model-len 32768 --max-num-seqs 16
docker logs -f vllm      # wait for "Application startup complete"
```
**Model: Qwen3.8 27B** (Alibaba Qwen). Verified on the HF Hub. Pick a variant:
- `Qwen/Qwen3.8-27B-FP8`: **chosen by the user.** Official FP8 (fine-grained, block size 128), about 31 GB on disk. Use this one.
- `nvidia/Qwen3.8-27B-NVFP4`: optional faster alternative (about 21 GB on disk). Only try it if the user asks.
- `Qwen/Qwen3.8-27B`: official BF16, about 56 GB. It fits, but decode will be slow (a few tokens/s). Use it for quality baselines only.
- Ignore the GGUF, MLX, "Uncensored", "abliterated" and other community fine-tunes. `incoai/Qwen3.8-27B-DFlash2` looks like a speculative-decoding drafter, which is an optional later experiment.

It is a dense 27.8B-parameter model with native 262K context and a vision encoder. Only 1 in 4 layers uses full attention, so the KV cache is small and `--max-model-len` can be raised well past 32768 if memory allows. If the container errors with an unknown architecture, move to a newer image tag. Read the model card (<https://huggingface.co/Qwen/Qwen3.8-27B-FP8>) and the vLLM recipe for the recommended flags, such as the reasoning parser, tool-call parser (`--enable-auto-tool-choice`) and sampling settings, and add them. If the model has a vision encoder and you only need text, `--limit-mm-per-prompt '{"image":0}'` saves memory.

- Bind to `127.0.0.1` only. Don't expose the port to the LAN unless the user asks. If they do, add `--api-key`.
- If OOM or a kernel/arch error occurs: lower `--max-model-len` and `--gpu-memory-utilization`, add `--enforce-eager` to rule out CUDA-graph/compile problems, and check `docker logs`.

## Step 4: Verify
```bash
curl -s localhost:8000/v1/models
curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3.8-27B-FP8","messages":[{"role":"user","content":"Say hi in 5 words"}],"max_tokens":32}'
```
Also check the output is coherent, `nvidia-smi` and `free -h` show the expected memory use, and the logs report sensible tokens/s.

## Step 5: Benchmark and scale up (optional)
- Quick throughput: `vllm bench serve --model <m> --dataset-name random --num-prompts 50` (run inside the container with `docker exec`).
- Larger models: with 121 GB you can fit ~70B-class at 4-bit or ~30B-class at FP8. Prefer FP8/NVFP4/AWQ checkpoints from HF. Gated models (e.g. Llama) need license acceptance on the HF account.
- Record what worked (model, flags, tokens/s) in `~/workspace/vllm/NOTES.md`.

## Step 6: Integrate / operate
- Open WebUI is already pulled. Because vLLM is published on `127.0.0.1` only, a container can't reach it through `host.docker.internal`. Put both containers on one user-defined network (`docker network create llm`, then add `--network llm` to both) and point Open WebUI at `http://vllm:8000/v1`. Either way, do not publish the port on `0.0.0.0` unless the user asks. The key can be any string if no `--api-key` is set.
- Manage: `docker stop|start|logs vllm`. To swap models, `docker rm -f vllm` and re-run with a new model. Only one large model at a time because memory is shared.
- Optional: put the run command in `~/workspace/vllm/docker-compose.yml` for reproducibility.

## Path B (fallback): native install without Docker
Use only if the container path is blocked.
```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
uv venv ~/workspace/vllm/.venv --python 3.12 && source ~/workspace/vllm/.venv/bin/activate
# Follow the vLLM docs for aarch64 + CUDA 13 wheels (e.g. a cu130 extra index). Verify the exact command in the docs first.
uv pip install vllm --torch-backend=auto
python -c "import torch;print(torch.cuda.is_available(), torch.cuda.get_device_capability())"   # expect True (12, 1)
vllm serve Qwen/Qwen3.8-27B-FP8 --gpu-memory-utilization 0.6 --max-model-len 32768
```
If the torch/vLLM wheels lack sm_121 kernels, stop and report back. Don't try a long source build without asking.

## Agent guardrails
- Don't print or persist `$HF_TOKEN`.
- Ask before using sudo or changing system config (Step 1) and before downloading models over ~50 GB.
- Don't kill other containers (open-webui, pgvector). Check `free -h` before launching and keep ≥20 GB free for the OS.
- Success criteria: `/v1/chat/completions` returns a sensible completion from a locally served model, bound to localhost, with the exact launch command saved in NOTES.md.
