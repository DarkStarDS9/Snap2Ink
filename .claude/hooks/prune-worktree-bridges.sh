#!/bin/sh
# Prunes stale Claude Code worktree sessions (.claude/worktrees/*) and alerts on any that turn
# out to be genuine orphans or to contain uncommitted work.
#
# A session normally ends with its work landing on the default branch (merge, squash, or
# cherry-pick) and the session getting archived — but archiving doesn't remove the worktree
# or its branch, so they accumulate silently across every session ever run. This only prunes
# a worktree/branch once its commits are confirmed already present in the default branch, and
# anything still `locked` is a live session and is never touched.
#
# "Landed" is checked three ways, because a single mechanical test misses real landings:
#   1. git-cherry patch-id equivalence — catches plain cherry-picks, survives rebasing.
#      NEVER use `git log A..B` / `git rev-list A..B` here: those are SHA-based and report
#      every cherry-picked branch as unlanded forever. Landing is usually done by cherry-pick
#      in these repos, so a SHA-based check produces constant false positives and gets ignored.
#   2. exact commit-subject match anywhere in the default branch's history — catches a landing
#      that reused the session's own commit message under a different SHA (parent context
#      differed enough to break patch-id matching, which turned out to be the common case here).
#   3. reverse-apply check — build a throwaway index from the default branch's current tree and
#      try to reverse-apply the branch's own diff against it, without touching the working
#      directory. If the removal applies cleanly, those exact lines are already present in the
#      default branch, however they got there (squash merge, hand-applied, etc).
# A branch that fails all three is a real, unreviewed orphan and is left untouched.
#
# SEPARATELY, and independently of all of that: a worktree whose working tree is dirty holds
# work that was never committed at all, which no commit-based test can see. Such a worktree is
# NEVER removed, however "landed" its branch looks, and is reported instead. This is not
# hypothetical — on 2026-08-02 a worktree holding four modified, uncommitted files (real fixes,
# already flashed to hardware) passed all three landed tests, because its branch tip was itself
# already on the trunk. A `git worktree remove --force` would have destroyed them.
#
# New findings (per the state file at .claude/hooks/.known-orphans, itself gitignored) are
# printed as stdout lines, which SessionStart surfaces into the session transcript. That's the
# only channel: desktop notifications don't reach the user in practice, so this deliberately
# does not try them — a finding that isn't read in a live session wouldn't get seen either way.
#
# Runs as a SessionStart hook, in every worktree. Sessions here almost always start inside
# .claude/worktrees/* (a bridge worktree), never in the main worktree, so repo_root is resolved
# via the shared .git dir (same across all worktrees of a repo) rather than
# `git rev-parse --show-toplevel`, which returns the *current* worktree's root — anchoring on
# that would silently no-op this whole script in the common case. Pruning a sibling mid-flight
# is guarded separately, below, by skipping anything `locked` — which includes whichever
# worktree is running this hook right now.

set -eu

git_common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
repo_root=$(dirname "$git_common_dir")
cd "$repo_root" 2>/dev/null || exit 0
[ -d ".claude/worktrees" ] || exit 0

default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
if [ -z "$default_branch" ]; then
    # No origin remote (Snap2Ink has none) — fall back to whichever trunk this repo actually
    # has, rather than a hardcoded guess that silently no-ops the whole hook. `develop` is
    # deliberately absent: in the firmware fork it is a pristine upstream mirror, never a trunk.
    for candidate in companion main master; do
        if git rev-parse --verify "$candidate" >/dev/null 2>&1; then
            default_branch=$candidate
            break
        fi
    done
fi
[ -n "$default_branch" ] || exit 0
git rev-parse --verify "$default_branch" >/dev/null 2>&1 || exit 0

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

is_landed() {
    branch=$1

    cherry_out=$(git cherry "$default_branch" "$branch" 2>/dev/null) || cherry_out=""
    if [ -n "$cherry_out" ] && ! printf '%s\n' "$cherry_out" | grep -q '^+'; then
        return 0
    fi

    subj=$(git log -1 --format=%s "$branch" 2>/dev/null) || return 1
    if git log --format=%s "$default_branch" 2>/dev/null | grep -qxF "$subj"; then
        return 0
    fi

    mergebase=$(git merge-base "$default_branch" "$branch" 2>/dev/null) || return 1
    diff_out=$(git diff "$mergebase" "$branch" -- 2>/dev/null) || return 1
    if [ -z "$diff_out" ]; then
        return 0
    fi

    tmpidx=$(mktemp -u "$workdir/idx.XXXXXX")
    GIT_INDEX_FILE="$tmpidx" git read-tree "$default_branch" 2>/dev/null || { rm -f "$tmpidx"; return 1; }
    if printf '%s\n' "$diff_out" | GIT_INDEX_FILE="$tmpidx" git apply --check -R --cached 2>/dev/null; then
        rm -f "$tmpidx"
        return 0
    fi
    rm -f "$tmpidx"
    return 1
}

# One state-machine pass over porcelain output: for each worktree entry, record path\tbranch\tlocked.
# -A/-B line counting is fragile against the optional locked/prunable lines, so track state explicitly.
# substr() rather than $2 so a path containing spaces survives.
: > "$workdir/live.tsv"
git worktree list --porcelain | awk -v out="$workdir/live.tsv" '
  /^worktree / { if (path != "") print path "\t" branch "\t" locked >> out; path=substr($0, 10); branch=""; locked=0; next }
  /^branch /   { b=substr($0, 8); sub("^refs/heads/", "", b); branch=b; next }
  /^locked/    { locked=1; next }
  END          { if (path != "") print path "\t" branch "\t" locked >> out }
'

pruned=0
: > "$workdir/findings.txt"

while IFS="$(printf '\t')" read -r wtpath branch locked; do
    case "$branch" in worktree-bridge-cse_*|worktree-agent-*) ;; *) continue ;; esac
    if [ "$locked" = "1" ]; then
        continue
    fi

    # Uncommitted work beats every commit-based test below. Tracked modifications are the loud
    # case; untracked-only still blocks removal, because removal would delete new files outright.
    dirt=$(git -C "$wtpath" status --porcelain 2>/dev/null || true)
    tracked_dirt=$(printf '%s\n' "$dirt" | grep -v '^??' | grep -v '^[[:space:]]*$' || true)
    if [ -n "$tracked_dirt" ]; then
        n=$(printf '%s\n' "$tracked_dirt" | wc -l | tr -d ' ')
        printf 'UNCOMMITTED\t%s\t%s file(s) modified, never committed\n' "$wtpath" "$n" >> "$workdir/findings.txt"
        continue
    fi
    if [ -n "$dirt" ]; then
        printf 'UNTRACKED\t%s\t%s\n' "$wtpath" "untracked files present; not removed" >> "$workdir/findings.txt"
        continue
    fi

    if is_landed "$branch"; then
        # `git worktree remove` refuses outright on a repo with submodules ("working trees
        # containing submodules cannot be moved or removed") and --force does NOT override it.
        # SpokenFeeds and xteink-companion-ble still vendor the firmware as a submodule (Snap2Ink
        # no longer does, since it moved to the versioned CompanionKit package), so this fails
        # there — which silently left multi-gigabyte worktrees piling up forever.
        rm_out=$(git worktree remove "$wtpath" 2>&1) || true
        if [ -d "$wtpath" ]; then
            # Fall back to deleting the directory ourselves. Safe *only* because everything
            # above has already been established for this worktree: not locked, branch landed
            # by all three tests, and working tree completely clean — no tracked modifications
            # and no untracked files. The only thing left to lose is gitignored build output,
            # which is precisely what should go. Hard-guard the path against the repo's own
            # worktrees dir first: $wtpath comes from `git worktree list`, but an rm -rf that
            # ever ran on something else would be unrecoverable.
            case "$wtpath" in
                "$repo_root"/.claude/worktrees/?*)
                    rm -rf "$wtpath"
                    git worktree prune >/dev/null 2>&1 || true
                    ;;
                *)
                    printf 'STALE\t%s\t%s\n' "$wtpath" "landed, but sits outside .claude/worktrees — not auto-removing: $(printf '%s' "$rm_out" | tr '\n' ' ')" >> "$workdir/findings.txt"
                    continue
                    ;;
            esac
        fi
        if [ -d "$wtpath" ]; then
            printf 'STALE\t%s\t%s\n' "$wtpath" "landed, but could not be removed: $(printf '%s' "$rm_out" | tr '\n' ' ')" >> "$workdir/findings.txt"
        elif git branch -D "$branch" >/dev/null 2>&1; then
            pruned=$((pruned + 1))
        fi
    else
        printf 'ORPHAN\t%s\t%s\n' "$branch" "$(git log -1 --format=%s "$branch" 2>/dev/null)" >> "$workdir/findings.txt"
    fi
done < "$workdir/live.tsv"

# Branches whose worktree dir is already gone (removed by hand, session cleanup, etc).
git branch --list 'worktree-bridge-cse_*' --format='%(refname:short)' > "$workdir/all_branches.txt"
git branch --list 'worktree-agent-*' --format='%(refname:short)' >> "$workdir/all_branches.txt"
cut -f2 "$workdir/live.tsv" > "$workdir/live_branches.txt"
sort "$workdir/all_branches.txt" > "$workdir/all_branches_sorted.txt"
sort "$workdir/live_branches.txt" > "$workdir/live_branches_sorted.txt"
comm -23 "$workdir/all_branches_sorted.txt" "$workdir/live_branches_sorted.txt" > "$workdir/orphan_branches.txt"

while IFS= read -r branch; do
    if [ -z "$branch" ]; then
        continue
    fi
    if is_landed "$branch"; then
        if git branch -D "$branch" >/dev/null 2>&1; then
            pruned=$((pruned + 1))
        fi
    else
        printf 'ORPHAN\t%s\t%s\n' "$branch" "$(git log -1 --format=%s "$branch" 2>/dev/null)" >> "$workdir/findings.txt"
    fi
done < "$workdir/orphan_branches.txt"

if [ "$pruned" -gt 0 ]; then
    echo "prune-worktree-bridges: removed $pruned landed session worktree(s)/branch(es)"
fi

state_file=".claude/hooks/.known-orphans"
sort -u "$workdir/findings.txt" > "$workdir/findings_sorted.txt"
[ -f "$state_file" ] || : > "$state_file"
sort "$state_file" > "$workdir/known_sorted.txt"
comm -23 "$workdir/findings_sorted.txt" "$workdir/known_sorted.txt" > "$workdir/new_findings.txt"

if [ -s "$workdir/new_findings.txt" ]; then
    count=$(wc -l < "$workdir/new_findings.txt" | tr -d ' ')
    echo "prune-worktree-bridges: $count new unlanded session finding(s) on $default_branch — nothing was deleted:"
    while IFS="$(printf '\t')" read -r kind what detail; do
        case "$kind" in
            UNCOMMITTED) echo "  - UNCOMMITTED WORK in $what — $detail" ;;
            UNTRACKED)   echo "  - untracked files in $what — $detail" ;;
            STALE)       echo "  - stale (safe to delete by hand) $what — $detail" ;;
            ORPHAN)      echo "  - unlanded branch $what: $detail" ;;
        esac
    done < "$workdir/new_findings.txt"
    echo "  Review each: land it on $default_branch, or discard it explicitly."
fi

cp "$workdir/findings_sorted.txt" "$state_file"
exit 0
