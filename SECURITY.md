# Security Policy

## Reporting a vulnerability

Report suspected vulnerabilities privately to security@snaphop.com. Never open
public issues or pull requests containing vulnerability details. Include the
commit, affected services, impact, and reproduction steps with synthetic data
and sensitive values redacted. Never include credentials or database content.

## Supported versions

Security fixes target the current `master` branch. No older release is supported.

## Security boundaries

- Secrets must come from an operator-managed environment or local, ignored `.env`.
  Examples must contain placeholders only. Never commit or log credentials.
- The unauthenticated vLLM backend and the RAG database bind to loopback by default.
  Exposing services to a LAN requires explicit operator configuration, firewall
  controls, and appropriate authentication. Use TLS when traffic leaves the host.
- LiteLLM master credentials grant administrative API access. Use scoped virtual
  keys for applications and protect the operator's admin credentials.
- Database volumes, model caches, and retrieved documents belong to the operator.
  Tests must use synthetic data on disposable instances. `make clean-all` deletes
  database volumes and must never run without explicit authorization.
- CI uses GitHub-hosted runners, read-only permissions, SHA-pinned actions, and
  synthetic configuration. Untrusted pull requests must never receive secrets.
- Host administration, GPU runtime changes, deployment, model downloads, and
  release publication require explicit authorization. A merge deploys nothing.

Container images and model weights are external dependencies with separate
licenses and security policies. Review their provenance and versions before
running them. The existing LiteLLM `main-latest` image and other floating tags
are compatibility limitations; this migration does not attest to their contents.

## Migration credentials

Embedded credentials were removed from every imported Git revision for the
GitHub migration. Treat credentials present in the former Gitea repository as
exposed and rotate them in the operator-managed environment before reuse.
Removing a credential from Git history does not revoke it.
