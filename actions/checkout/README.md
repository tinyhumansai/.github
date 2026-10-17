# Checkout with selective submodules

`actions/checkout` with `submodules: recursive` clones every submodule, one
at a time. For a repository that vendors OpenHuman, that is roughly 70 clones
and a minute of every job, wiki submodules included, though no build reads
them.

This action checks the repository out with `actions/checkout` (submodules off)
and then adds the submodules itself:

- **shallow**: `submodule-depth`, 1 by default;
- **in parallel**: every parent of a level updates at once, each cloning
  `jobs` submodules at a time;
- **selectively**: a submodule whose path matches `exclude-submodules` is left
  as an empty directory, and nothing beneath it is visited.

Only indexed gitlinks are updated. Stale `.gitmodules` declarations without a
matching gitlink are ignored, including declarations in nested submodules.

```yaml
- uses: tinyhumansai/.github/actions/checkout@<sha>
  with:
    exclude-submodules: |
      wiki
      vendor/openhuman/app
```

A pattern is a bash glob over the submodule's path from the repository root,
where `*` also matches `/`. A pattern without a `/` matches the last path
component at any depth, so the default `wiki` leaves out every submodule
named `wiki`.

Measured from a laptop on openhuman's 51 nested submodules:
`git submodule update --init --recursive --depth 1` took 163s, and this
action's script took 62s (46 cloned, 5 wikis skipped).

## Credentials

`token` (default `github.token`) is sent to github.com as an HTTP header via
`GIT_CONFIG_*` environment variables that only the submodule step sees. It is
never written to a git config. `persist-credentials` defaults to `false`,
unlike `actions/checkout`, because CI jobs that build repository code should
not keep a token in `.git/config`.

## Trusted-base fork pull requests

`allow-unsafe-pr-checkout` defaults to `false` and forwards directly to the
pinned `actions/checkout` action. A workflow triggered by `pull_request_target`
or `workflow_run` that intentionally checks out a fork PR must explicitly set
it to `true` after its own trust checks authorize that PR's code and runner
access. The composite action does not decide whether a contributor is trusted.

For example, after a trusted-base workflow verifies both the PR author and the
triggering actor are permitted to use its private runner:

```yaml
- uses: tinyhumansai/.github/actions/checkout@<sha>
  with:
    ref: refs/pull/${{ github.event.pull_request.number }}/merge
    allow-unsafe-pr-checkout: true
    persist-credentials: false
```

Keep that opt-in behind the caller's membership and runner-routing gate.
Ordinary checkout callers can omit it and retain the upstream refusal guard.

## Container jobs

In a `container:` job git runs as root over a workspace the runner's user
owns, and refuses it as unsafe. The submodule step sets `safe.directory=*`
for its own git calls, the same way, through the environment. Later steps
that run git in the workspace need
`git config --global --add safe.directory "$GITHUB_WORKSPACE"` themselves.

The tests are in `scripts/test-checkout-submodules.py`.
