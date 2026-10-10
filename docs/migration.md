# GitHub migration

The destination is https://github.com/snaphop/snaphop-local-ai-stack, public,
with an MIT license and `master` as its default branch, matching the conventions
of https://github.com/snaphop/snaphop-agent-vm.

The Gitea source had seven commits on one branch and no tags, issues, pull requests,
or releases at inspection. All seven revisions were exported and imported into
a separate repository after replacing embedded credentials and operator-specific
addresses in every revision. Authors, dates, messages, and parent ordering are
preserved, but commit IDs necessarily change. The source checkout and Gitea
history are preserved. Do not mirror or merge the unsanitized source history into
GitHub. Former credentials must be rotated by the operator before reuse.

The GitHub setup includes a license and notice, contribution and security guides,
canonical agent guidance, changelog, pull request template, Verify workflow, and
weekly Dependabot updates. Verify runs `make check` on a GitHub-hosted runner with
read-only permissions and a SHA-pinned checkout action. Hardware inference and
RAG tests remain explicit local operations. This repository distributes Compose
configuration and scripts, so no Go binary release workflow is copied from the
reference project. Merging does not deploy or publish a release.

GitHub is the intended canonical destination after publication. The Gitea
repository has not been deleted or archived by this migration.
