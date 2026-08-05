# CI security posture

This repository builds untrusted upstream source as root, on runners that hold `contents: write` and `id-token: write` in the release lane.
The controls below exist because of that, not as boilerplate.

## The trust list

`.github/actions/authorize-actor` fails a job unless the triggering identity is explicitly trusted:

| Trusted                        | Why                                                            |
|--------------------------------|----------------------------------------------------------------|
| the repository owner           | the human who owns this repository                             |
| `dependabot[bot]`              | opens the pinned-SHA bumps the automerge lane exists to land   |
| `github-actions[bot]`          | the identity for scheduled runs and workflow-dispatched runs   |
| anyone in `.github/CODEOWNERS` | already trusted to review changes here, so trusted to run them |

`allow-dependabot: "false"` removes Dependabot for jobs that should never run on a bot's behalf — anything that publishes. Only `@login`
entries are read from CODEOWNERS; `@org/team` references need an API call and a token to resolve, so they are ignored rather than
half-honoured.

**This is defence in depth, not the primary control.** The primary control is the repository setting *Actions → General → Require approval
for all external contributors*, which stops the runner from ever starting. A workflow-level check necessarily runs after the runner has
started, so it cannot prevent compute abuse on its own. What it does buy: an unapproved actor cannot reach a privileged step, and the trust
list is reviewable in code rather than buried in a settings page.

Both are set. The repository is **public**, so anyone can open a pull request; the approval policy is what makes that safe, and its current
value is `all_external_contributors`. The default workflow token permission is `read`.

For `repository_dispatch` the *sender* is checked rather than the actor, because the payload arrives from another repository — the APT
control plane.

### Where the gate sits

The entry-point workflows call `authorize-actor` directly, and in `ci.yaml` **both** jobs call it — each runs `prepare-ci-env`, which
provisions tooling from the pull request's own `mise.ci.toml`, so each executes PR-controlled configuration.

`build-podman-packages.yaml` and `test-podman-packages.yaml` do not gate: they are `workflow_call` targets invoked by `release.yaml` and
`upstream-watch.yaml`, which have already gated by the time control reaches them. One consequence worth knowing rather than rediscovering:
`build-podman-packages.yaml` also carries a `workflow_dispatch` trigger, so a direct manual run of it is not gated by the trust list.
Dispatching a workflow already requires write access to the repository, so this is a narrow gap rather than an open door — but it is a gap.

## Tokens stay off disk

Every `actions/checkout` in this repository passes `persist-credentials: false`. No step pushes with git, and several go on to build
untrusted upstream source as root; leaving the token in `.git/config` would give that code something to read.

## Secrets are named, never inherited

`release.yaml` declares `APT_DISPATCH_TOKEN` explicitly in its `workflow_call` interface rather than relying on the caller's
`secrets: inherit`. `inherit` hands the called workflow *every* secret in the repository when it needs exactly one. Naming it keeps the
blast radius to the credential actually in use and makes the dependency visible in the workflow's own interface. It is declared
`required: false`, because a prerelease run never dispatches and has no need of the token at all.

`APT_DISPATCH_TOKEN` is the only secret this repository uses — see [package signing](signing.md) for why there is no key material here.

## Auto-merge is gated four ways

`dependabot-automerge.yaml` merges only when all of these hold:

1. the triggering CI run concluded successfully
2. the PR author is `dependabot[bot]`
3. every changed file is under `.github/workflows/`, `.github/actions/*/action.yaml`, or `.github/dependabot.yaml`
4. every added or removed content line is a pinned-SHA `uses:` bump and nothing else

Any deviation fails closed and leaves the PR for a human. Two details that are easy to get wrong and are handled deliberately:

- The pre-filter reads the actor off the **triggering run** (`github.event.workflow_run.actor.login`). On a `workflow_run`
  event `github.actor` is the actor of the dispatching run, which is not reliably `dependabot[bot]`, so a gate written against it silently
  never matches. The PR-author check is the real authority.
- The merge passes `--match-head-commit`. Without it, `--auto` merges whatever the branch head is once required checks pass, not the commit
  the content gates inspected — a time-of-check/time-of-use hole where a commit pushed after validation lands unreviewed.

The approving review the workflow records is honest rather than circular: the review that matters already happened in gates 2–4, and this
step records that verdict. It is needed because branch protection requires an approving review with
`require_last_push_approval` and there are no bypass actors — GitHub rejects an Actions-app bypass on a personal-account repository.

### A merged auto-merge does not run CI on `main`

The merge is performed by `github-actions[bot]` with the default token, and GitHub suppresses the resulting `push` event to prevent workflow
recursion — the same anti-recursion rule that stops `release: published` from firing for CI-created releases (see
[distribution](distribution.md)). So an auto-merged bump lands on `main` with **no CI run against `main`**.

This is tolerable rather than ideal: the required status checks ran against the PR head, and `--match-head-commit` guarantees the merged tree
is the one they inspected. But it means a green `main` will never come from an auto-merge, and a post-merge-only failure would go unnoticed.
Fixing it properly means merging with a PAT instead of `GITHUB_TOKEN`, which reintroduces exactly the durable secret this repository is
otherwise free of — so it is knowingly left alone.

## Branch and tag rulesets

Two rulesets, both `active`, neither with bypass actors:

**`main-protected`** (`refs/heads/main`) — pull requests required, 1 approving review, `require_last_push_approval`,
`dismiss_stale_reviews_on_push`, review-thread resolution, squash-only merges, linear history, and deletion plus force-push blocked. Required
status checks: **`Lint & test`** and **`Validate melange definitions`**.

**`tags-protected`** (`refs/tags/v*`) — deletion and force-push blocked, so a published release tag cannot be moved or removed.

Two things follow that are easy to trip over:

- **Nobody pushes to `main` directly**, including the owner. Every change goes through a pull request.
- **The required checks are literal strings** matching the `name:` of each `ci.yaml` job. Rename a job and every pull request becomes
  unmergeable, with the symptom being a required check that never reports rather than one that fails. Both job definitions carry a comment
  saying so.

Because there are no bypass actors and GitHub does not permit self-approval, a pull request opened by the sole maintainer cannot be approved
by that maintainer. Dependabot's are approved by the auto-merge lane; anything else needs a second reviewer, a temporary bypass actor, or a
required-review count of zero.

## Related

- [Release process](releases.md) — what the privileged lane actually does
- [Package signing](signing.md) — attestation as the control on released bytes
- [Repository layout](repository-layout.md) — which workflow holds which permissions
