# Changelog

## Unreleased

- Speed up single-stream decode with the checkpoint's MTP head (3 draft tokens). On this GB10, one stream moved from 8.4 tokens/s to about 17 tokens/s.
- Keep a long Qwen prompt inside the 32768-token window. OpenCode now declares the input limit that makes its compaction buffer apply, and LiteLLM lowers `max_tokens` when the prompt and the requested cap would overflow vLLM.
- Verify the admin password on every bootstrap, and stop treating a broken test or a changed `VLLM_MODEL` as success.
- Give the RAG database enough `/dev/shm` for its parallel worker settings, and make `match_rag_chunks` able to use its full-text index.
- Prepare the move from Gitea to the public `snaphop/snaphop-local-ai-stack`
  GitHub repository with an MIT license and contribution, security, and agent guides.
- Add GitHub Verify and Dependabot configuration with SHA-pinned actions.
- Remove embedded credentials and operator-specific addresses from imported history.
- Read the LiteLLM master key from the environment, require operator-provided
  database passwords, and bind the gateway and RAG database to loopback by default.
