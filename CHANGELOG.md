# Changelog

## Unreleased

- Verify the admin password on every bootstrap, and stop treating a broken test or a changed `VLLM_MODEL` as success.
- Give the RAG database enough `/dev/shm` for its parallel worker settings, and make `match_rag_chunks` able to use its full-text index.
- Prepare the move from Gitea to the public `snaphop/snaphop-local-ai-stack`
  GitHub repository with an MIT license and contribution, security, and agent guides.
- Add GitHub Verify and Dependabot configuration with SHA-pinned actions.
- Remove embedded credentials and operator-specific addresses from imported history.
- Read the LiteLLM master key from the environment, require operator-provided
  database passwords, and bind the gateway and RAG database to loopback by default.
