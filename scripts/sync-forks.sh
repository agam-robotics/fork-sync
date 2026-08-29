#!/usr/bin/env bash
#
# Fast-forward every fork in an organisation onto its upstream default branch.
#
# Deliberately uses the ref API rather than the "merge upstream" API: merging
# upstream will happily create a merge commit when a fork has drifted, and a
# fork whose default branch carries merge commits produces noisy upstream pull
# requests. This only ever moves a branch that is already a strict ancestor of
# upstream, so a fork either ends up identical to upstream or is left untouched
# and reported. Nothing here forces, resets or deletes.
#
# Only the default branch is synced. Topic branches (prod-*, PR branches) are
# never read or written.
#
# Environment:
#   ORG       organisation to scan                    (default: agam-robotics)
#   ONLY      space/comma list of repo names to restrict the run to
#   EXCLUDE   space/comma list of repo names to skip
#   DRY_RUN   "true" to report without writing        (default: false)
#
# Kept to bash 3.2 features so it runs on a stock macOS shell as well as on the
# runner.

set -euo pipefail

ORG="${ORG:-agam-robotics}"
DRY_RUN="${DRY_RUN:-false}"
RETRIES="${RETRIES:-3}"

# Space-padded haystacks, so a membership test is a plain substring match and
# there are no empty-array-under-set-u surprises.
pad() { printf ' %s ' "$(printf '%s' "$1" | tr ',' ' ' | xargs 2>/dev/null || true)"; }
ONLY_LIST=$(pad "${ONLY:-}")
SKIP_LIST=$(pad "${EXCLUDE:-}")

rows=""
row() { rows="${rows}| \`$1\` | $2 | $3 | $4 |
"; }

synced=0 uptodate=0 skipped=0 failed=0

# GitHub's API is reachable but not reliable; a single dropped connection must
# not cost the whole run, so every call gets a few attempts with backoff.
gh_api() {
    local attempt=1 errf out
    # stderr is kept off stdout so a gh warning can never corrupt the JSON.
    errf=$(mktemp)
    while :; do
        if out=$(gh api "$@" 2>"$errf"); then
            rm -f "$errf"
            printf '%s' "$out"
            return 0
        fi
        if [ "$attempt" -ge "$RETRIES" ]; then
            cat "$errf" >&2
            rm -f "$errf"
            return 1
        fi
        sleep $((attempt * 5))
        attempt=$((attempt + 1))
    done
}

# Returns 1 only for infrastructure failures. Anything the fork's own state
# causes (divergence, missing upstream) is reported and counted as skipped.
sync_one() {
    name=$1

    info=$(gh_api "repos/$ORG/$name") || return 1
    parent=$(printf '%s' "$info" | jq -r '.parent.full_name // empty')
    fork_branch=$(printf '%s' "$info" | jq -r '.default_branch')
    up_branch=$(printf '%s' "$info" | jq -r '.parent.default_branch // empty')

    if [ -z "$parent" ]; then
        # A repo keeps fork:true even if upstream is deleted or made private.
        echo "::warning::$name reports as a fork but has no reachable parent"
        row "$name" "\`$fork_branch\`" "–" "no reachable upstream"
        skipped=$((skipped + 1))
        return 0
    fi

    up_owner=${parent%%/*}
    fork_sha=$(gh_api "repos/$ORG/$name/git/ref/heads/$fork_branch" --jq '.object.sha') || return 1
    up_sha=$(gh_api "repos/$parent/git/ref/heads/$up_branch" --jq '.object.sha') || return 1
    short=$(printf '%s' "$up_sha" | cut -c1-7)

    if [ "$fork_sha" = "$up_sha" ]; then
        echo "ok    $name ($fork_branch) already at $short"
        row "$name" "\`$fork_branch\`" "\`$short\`" "up to date"
        uptodate=$((uptodate + 1))
        return 0
    fi

    cmp=$(gh_api "repos/$ORG/$name/compare/$ORG:$fork_branch...$up_owner:$up_branch") || return 1
    status=$(printf '%s' "$cmp" | jq -r '.status')
    ahead=$(printf '%s' "$cmp" | jq -r '.ahead_by')
    behind=$(printf '%s' "$cmp" | jq -r '.behind_by')

    case $status in
    identical)
        row "$name" "\`$fork_branch\`" "\`$short\`" "up to date"
        uptodate=$((uptodate + 1))
        ;;
    ahead)
        # Compare is oriented fork...upstream, so "ahead" means upstream leads
        # and the fork branch is a strict ancestor: safe to move without force.
        if [ "$DRY_RUN" = "true" ]; then
            echo "would  $name ($fork_branch) +$ahead -> $short"
            row "$name" "\`$fork_branch\`" "\`$short\`" "would fast-forward +$ahead"
            synced=$((synced + 1))
            return 0
        fi
        if gh_api -X PATCH "repos/$ORG/$name/git/refs/heads/$fork_branch" \
            -f sha="$up_sha" -F force=false >/dev/null; then
            echo "sync  $name ($fork_branch) +$ahead -> $short"
            row "$name" "\`$fork_branch\`" "\`$short\`" "fast-forwarded +$ahead"
            synced=$((synced + 1))
        else
            echo "::error::failed to update $ORG/$name:$fork_branch"
            row "$name" "\`$fork_branch\`" "–" "**update failed**"
            failed=$((failed + 1))
        fi
        ;;
    behind)
        echo "::warning::$name:$fork_branch is $behind ahead of $parent:$up_branch — left alone"
        row "$name" "\`$fork_branch\`" "–" "ahead of upstream by $behind"
        skipped=$((skipped + 1))
        ;;
    diverged)
        echo "::warning::$name:$fork_branch has diverged from $parent:$up_branch (+$ahead/-$behind) — left alone"
        row "$name" "\`$fork_branch\`" "–" "**diverged** +$ahead/-$behind"
        skipped=$((skipped + 1))
        ;;
    *)
        echo "::warning::$name:$fork_branch unexpected compare status '$status'"
        row "$name" "\`$fork_branch\`" "–" "status \`$status\`"
        skipped=$((skipped + 1))
        ;;
    esac
    return 0
}

forks=$(gh_api "orgs/$ORG/repos?type=all&per_page=100" --paginate \
    --jq '.[] | select(.fork and (.archived | not)) | .name' | sort)

if [ -z "$forks" ]; then
    echo "::error::could not list forks in $ORG"
    exit 1
fi

for name in $forks; do
    if [ "$ONLY_LIST" != "  " ] && [ "${ONLY_LIST#* $name }" = "$ONLY_LIST" ]; then
        continue
    fi
    if [ "${SKIP_LIST#* $name }" != "$SKIP_LIST" ]; then
        echo "skip  $name (excluded)"
        row "$name" "–" "–" "excluded"
        skipped=$((skipped + 1))
        continue
    fi

    # One flaky repo must not cost the rest of the run.
    if ! sync_one "$name"; then
        echo "::error::$name could not be reached after $RETRIES attempts"
        row "$name" "–" "–" "**unreachable**"
        failed=$((failed + 1))
    fi
done

{
    echo "## Fork sync — \`$ORG\`"
    echo
    [ "$DRY_RUN" = "true" ] && printf '_Dry run: nothing was written._\n\n'
    echo "| repo | branch | upstream head | result |"
    echo "|---|---|---|---|"
    printf '%s' "$rows"
    echo
    echo "synced **$synced** · up to date **$uptodate** · skipped **$skipped** · failed **$failed**"
} >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"

echo "synced=$synced uptodate=$uptodate skipped=$skipped failed=$failed"
[ "$failed" -eq 0 ]
