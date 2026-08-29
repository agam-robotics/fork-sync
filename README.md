# fork-sync

Keeps every fork in the `agam-robotics` organisation level with its upstream,
on a six-hourly schedule.

Replaces the [Pull](https://github.com/apps/pull) app (`pull[bot]`), which was
installed on `PX4-Autopilot` only and left the other six forks to drift.

## What it does

Every six hours (`17 */6 * * *`, i.e. 00:17, 06:17, 12:17, 18:17 UTC) it walks
every non-archived fork in the org and fast-forwards each one's **default
branch** onto the upstream default branch.

| | |
|---|---|
| Forks covered | discovered at run time — a new fork is picked up automatically |
| Branches touched | the default branch only |
| Method | `PATCH /git/refs` with `force: false` |
| On divergence | left untouched, reported as a warning |
| Record kept | `STATUS.md`, committed when a fork moves |

Run it by hand from the **Actions** tab (*Sync forks from upstream* → *Run
workflow*), where `only` restricts the run to named repos and `dry_run` reports
without writing.

## Why not `merge-upstream`

GitHub's "sync fork" API (`POST /repos/{owner}/{repo}/merge-upstream`, the same
thing the green *Sync fork* button calls) creates a **merge commit** when the
fork has picked up commits of its own. These forks exist to raise pull requests
against upstream, and a default branch carrying merge commits leaks them into
every PR branched from it.

So this moves the ref directly and only ever in the safe direction. A fork is
compared against upstream first, and the ref is moved only when the fork's
default branch is a **strict ancestor** of upstream's — the fast-forward case,
where no commit can be lost. Anything else (diverged, or ahead of upstream)
is left exactly as it is and reported. There is no force push, no reset and no
branch deletion anywhere in this repo.

That means a fork whose default branch has drifted stops being synced until a
human looks at it. That is the intended behaviour: silent recovery would mean
either losing a commit or creating the merge commit above.

## Why it lives in its own repo

Scheduled workflows only run from a repository's default branch. Putting the
workflow inside each fork would therefore put a commit on the very branch that
has to stay identical to upstream — the fork would diverge, and by the rule
above it would then stop syncing itself. One repo driving all the forks from
outside keeps them pristine.

## Setup

The job writes to other repositories, which `GITHUB_TOKEN` cannot do. It needs
a PAT in the `FORK_SYNC_TOKEN` secret.

1. Create a **classic** PAT at
   <https://github.com/settings/tokens/new> with the **`repo`** and
   **`workflow`** scopes.

   `workflow` is not optional: upstream commits routinely touch
   `.github/workflows/`, and a token without that scope is refused when the ref
   it is moving contains such a change.

   A fine-grained PAT works too — *Contents: read and write* plus *Workflows:
   read and write* on the forks — but it needs an org owner to approve it.

2. Store it:

   ```sh
   gh secret set FORK_SYNC_TOKEN -R agam-robotics/fork-sync
   ```

3. Confirm with a dry run:

   ```sh
   gh workflow run sync-forks.yml -R agam-robotics/fork-sync -f dry_run=true
   ```

The PAT's owner needs push access to the forks, and the run shows up in each
fork's history as that person. Set an expiry reminder — the job starts failing
the day the token expires.

## Excluding a fork

Set a repository variable rather than editing the workflow:

```sh
gh variable set SYNC_EXCLUDE -R agam-robotics/fork-sync --body "edgetx usb-ids"
```

## Running locally

The script is plain `bash` + `gh` + `jq`, and stays within bash 3.2 so it runs
on a stock macOS shell:

```sh
DRY_RUN=true ./scripts/sync-forks.sh
ONLY=inav ./scripts/sync-forks.sh
```

## Scope

Tags are not synced; neither are non-default branches. Both are deliberate —
tag syncing would need force semantics to be useful, and the topic branches in
these forks (`prod-megh7-*`, PR branches) are ours and must not be touched.

## Why the repo is public, and what STATUS.md is for

The organisation is on the free plan, where a private repository's scheduled
workflow never gets a hosted runner — the first run sat queued indefinitely with
no runner assigned. Public repositories get unlimited free runners. Nothing here
is sensitive: the PAT lives in a repository secret, not in the code, and the
seven forks are public already.

The one cost of being public is that **scheduled workflows are disabled after 60
days without repository activity**, and a job that only writes to other repos
would trip that and stop silently. So each run writes `STATUS.md` — the current
head of every fork — and commits it when it changes.

`STATUS.md` carries no timestamp on purpose. It changes only when a fork
actually moves, which makes the commit log a real record of upstream activity
instead of four no-op commits a day. With ArduPilot, PX4 and EdgeTX all
committing most days, the repo stays comfortably active.

If GitHub ever does disable the schedule, the Actions tab offers a button to
re-enable it.
