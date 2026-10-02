#!/usr/bin/env bash
# =============================================================================
# scripts/push_charon_updates.sh
#
# PURPOSE
# -------
# Contributes an infra fix made in this lab workspace back upstream to the
# `charon` template repo, as a brand-new commit on a fresh charon branch —
# never by pushing this repo's own commits (charon has no shared git history
# with this workspace by design, and its commit history must stay free of
# lab-specific messages/content). Uses a `git worktree` checked out from
# charon/main so the two repos' histories never need to merge.
#
# WHAT IT DOES
# ------------
#   1. Verifies the `charon` remote exists and fetches it.
#   2. Creates a temporary worktree rooted at charon/main on a new branch.
#   3. Copies the CURRENT content of every scripts/charon_manifest.txt path
#      from this workspace into that worktree, overwriting what's there.
#   4. Stages only the manifest paths, commits with the message you supply
#      via -m, and pushes the new branch to charon.
#   5. Prints the `gh pr create` command to open a PR in charon — does not
#      run it automatically (opening a PR needs your judgment on title/body,
#      and this script is not scoped to assume `gh`'s default repo context).
#   6. Removes the temporary worktree.
#
# USAGE
# -----
#   scripts/push_charon_updates.sh -m "fix: correct devcontainer ARM64 mount"
#   scripts/push_charon_updates.sh -m "..." -b my-branch-name
#
# REQUIRES: a clean working tree in THIS repo (so you're pushing a known,
# committed state), and a `charon` remote with push access:
#   git remote add charon https://github.com/Duke-Vascular-Informatics/charon.git
# =============================================================================

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

COMMIT_MSG=""
BRANCH="infra/$(date +%Y%m%d%H%M%S)"

while getopts "m:b:" opt; do
  case "$opt" in
    m) COMMIT_MSG="$OPTARG" ;;
    b) BRANCH="$OPTARG" ;;
    *) echo "usage: $0 -m \"<commit message>\" [-b <branch-name>]" >&2; exit 1 ;;
  esac
done

if [[ -z "$COMMIT_MSG" ]]; then
  echo "error: -m \"<commit message>\" is required (charon's history must not carry" >&2
  echo "       this lab's own commit messages — write one appropriate for charon)." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is not clean. Commit or stash your changes first." >&2
  exit 1
fi

if ! git remote get-url charon >/dev/null 2>&1; then
  echo "error: no 'charon' remote configured. Add it first:" >&2
  echo "  git remote add charon https://github.com/Duke-Vascular-Informatics/charon.git" >&2
  exit 1
fi

MANIFEST="scripts/charon_manifest.txt"
if [[ ! -f "$MANIFEST" ]]; then
  echo "error: $MANIFEST not found." >&2
  exit 1
fi

git fetch charon --quiet

mapfile -t MANIFEST_PATHS < <(grep -vE '^\s*(#|$)' "$MANIFEST")

WORKTREE_DIR="$(mktemp -d)/charon-push"
cleanup() { git worktree remove "$WORKTREE_DIR" --force >/dev/null 2>&1 || true; }
trap cleanup EXIT

git worktree add --quiet "$WORKTREE_DIR" -b "$BRANCH" charon/main

for path in "${MANIFEST_PATHS[@]}"; do
  [[ -e "$path" ]] || { echo "warning: $path does not exist locally, skipping." >&2; continue; }
  mkdir -p "$(dirname "$WORKTREE_DIR/$path")"
  rm -rf "${WORKTREE_DIR:?}/$path"
  cp -a "$path" "$WORKTREE_DIR/$path"
done

(
  cd "$WORKTREE_DIR"
  git add -- "${MANIFEST_PATHS[@]}"
  if git diff --cached --quiet; then
    echo "No differences from charon/main for any manifest path — nothing to push."
    exit 0
  fi
  git commit -m "$COMMIT_MSG"
  git push charon "$BRANCH"
  echo ""
  echo "Pushed. Open a PR with:"
  echo "  gh pr create --repo Duke-Vascular-Informatics/charon --base main --head \"$BRANCH\" \\"
  echo "    --title \"$COMMIT_MSG\" --body \"<describe the fix>\""
)
