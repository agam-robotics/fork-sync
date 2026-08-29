# fork-sync

Fast-forwards every fork in `agam-robotics` onto its upstream default branch,
every six hours.

## Behaviour

- Forks are discovered at run time; a new one is picked up automatically.
- Default branch only. Topic branches are never read or written.
- Updates the ref with `PATCH /git/refs`, `force: false`, and only when the
  fork's default branch is a strict ancestor of upstream.
- A diverged fork is reported and left alone. No force push, reset or delete.
- `STATUS.md` holds the head of each fork, committed when it changes.

Run by hand from the Actions tab: `only` limits the run to named repos,
`dry_run` reports without writing.

## Setup

`FORK_SYNC_TOKEN` — classic PAT, scopes `repo` and `workflow`. `workflow` is
required: upstream commits touch `.github/workflows/`, and a token without it
is refused.

```sh
gh secret set FORK_SYNC_TOKEN -R agam-robotics/fork-sync
gh workflow run sync-forks.yml -R agam-robotics/fork-sync -f dry_run=true
```

Exclude a fork without editing the workflow:

```sh
gh variable set SYNC_EXCLUDE -R agam-robotics/fork-sync --body "edgetx usb-ids"
```

## Local use

Plain `bash` + `gh` + `jq`, kept to bash 3.2 so it runs on stock macOS.

```sh
DRY_RUN=true ./scripts/sync-forks.sh
ONLY=inav ./scripts/sync-forks.sh
```

## Notes

- Not `POST /merge-upstream`: that creates a merge commit when a fork has
  drifted, and merge commits on the default branch leak into every PR branched
  from it.
- Separate repo because scheduled workflows only run from a repo's default
  branch — putting this inside a fork would diverge the branch it has to keep
  clean.
- `STATUS.md` carries no timestamp, so it changes only when a fork moves. That
  keeps the repo active enough to avoid the 60-day scheduled-workflow cutoff
  without committing four times a day.
- Tags are not synced.

Replaces the [Pull](https://github.com/apps/pull) app, which ran on
`PX4-Autopilot` only.
