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
list is reviewable in code rather than buried in a settings page. Both are set.

For `repository_dispatch` the *sender* is checked rather than the actor, because the payload arrives from another repository — the APT
control plane.

### Where the gate sits

The seven entry-point workflows call `authorize-actor` directly. `build-podman-packages.yaml` and
`test-podman-packages.yaml` do not: they are `workflow_call` targets invoked by `release.yaml` and `upstream-watch.yaml`, which have already
gated by the time control reaches them. Two consequences worth knowing rather than rediscovering:

- `build-podman-packages.yaml` also carries a `workflow_dispatch` trigger, so a direct manual run of it is not gated by the trust list.
  Dispatching a workflow already requires write access to the repository, so this is a narrow gap rather than an open door — but it is a
  gap.
- In `ci.yaml` the gate is on the `lint` job. The `melange-definitions` job runs `prepare-ci-env` without it, and that provisions tooling
  from the pull request's own `mise.ci.toml`.

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

## Related

- [Release process](releases.md) — what the privileged lane actually does
- [Package signing](signing.md) — attestation as the control on released bytes
- [Repository layout](repository-layout.md) — which workflow holds which permissions
