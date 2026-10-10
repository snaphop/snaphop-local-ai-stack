# Contributing

Open an issue at https://github.com/snaphop/snaphop-local-ai-stack/issues for bugs
or proposals. Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

Fork the repository, create a focused branch, and submit a pull request against
`master`. Include the problem, change, verification commands and results, and any
operator configuration or data migration required. Contributions use the MIT
license. Container images and model weights have separate upstream licenses.

## Local checks

Install Bash, Python 3, and Docker Compose 2.20 or newer, then run:

```sh
make check
```

These checks validate shell syntax, configuration, and the Compose service
contract using synthetic credentials. They do not start services or need a GPU.
GitHub Actions runs the same command.

## Hardware verification

See [README.md](README.md) for GPU prerequisites and environment configuration.
On a disposable stack you are authorized to use, run `make test`, `make test-rag`,
and optionally `make benchmark`. The RAG test writes and deletes test documents.
Include hardware, image versions, and results in the pull request; state plainly
when GPU inference was not tested. Never include credentials, real documents,
operator addresses, model weights, database dumps, or `.env` files.
