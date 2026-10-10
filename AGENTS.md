# AGENTS.md

Canonical guidance for agents working on SnapHop Local AI Stack. Tool-specific
instruction files defer here.

## Project

This is a Docker Compose stack for local NVIDIA DGX Spark / GB10 inference:
vLLM, LiteLLM, PostgreSQL, Redis, and a PostgreSQL pgvector RAG database.
The canonical repository is https://github.com/snaphop/snaphop-local-ai-stack.
The default branch is `master`; the project is licensed under MIT.

## Workflow

Inspect `git status --short` and read `SECURITY.md` before changing code.
Preserve unrecognized work. Keep configuration, scripts, and README contracts
consistent. Use explicit paths when staging. Run `make check` before handoff;
GitHub Verify runs the same checks without a GPU, secrets, or running services.
Run `make test` and `make test-rag` only on an explicitly authorized disposable
GPU stack. The RAG test writes and deletes test documents. Record which checks
ran and which hardware checks were unavailable.

## Boundaries

Never commit `.env`, API keys, passwords, model caches, database content, or
host-specific operational data. Configuration examples use placeholders.
Never print secrets in logs, diffs, or errors. Compose must obtain credentials
from the operator's environment; never add a working default password.
Keep vLLM and database ports on loopback by default. LAN access is an explicit
operator configuration choice. Do not launch containers, download model weights,
change host configuration, publish releases, or delete volumes unless authorized.
`make clean-all` destroys database volumes.

## CI and dependencies

Use GitHub-hosted runners, read-only permissions, and SHA-pinned actions.
CI must not receive operational secrets or download model weights. Keep dependency
updates separate from unrelated changes; document image or model compatibility
changes and verify them on the target hardware when available.
