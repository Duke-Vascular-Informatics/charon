#!/usr/bin/env bash
# =============================================================================
# scripts/pull_charon_updates.sh
#
# PURPOSE
# -------
# Pulls shared-infra fixes made upstream in the `charon` template repo into
# this lab workspace, without merging the two repos' unrelated git histories.
# Reads scripts/charon_manifest.txt and, for each path, checks out that
# path's content from charon/main — exactly as it exists there — into this
# repo's working tree and index.
#
# WHEN TO RUN
# -----------
# Periodically, or when you know an infra fix landed on charon (devcontainer
# change, a workspace-root script fix, a generic doc correction). NOT for
# this lab's own data changes (new study, new contributor) — those never
# come from charon.
#
# WHAT IT DOES
# ------------
#   1. Verifies the `charon` remote exists (errors with setup instructions
#      if not) and fetches it.
#   2. For each path in scripts/charon_manifest.txt, runs
#      `git checkout charon/main -- <path>`.
#   3. Commits the result if anything changed. Does NOT push — this only
#      updates your local branch.
#   4. If scripts/sync_contributors.R was itself among the paths that
#      changed, reminds you to re-run it.
#
# CAVEAT: `git checkout <ref> -- <path>` only adds/overwrites files that
# exist at <path> in <ref>; it will NOT delete a file that was removed
# upstream. After a pull, spot-check `git diff charon/main -- <dir>` for any
# directory-level manifest entry if you suspect something was deleted
# upstream.
#
# USAGE
# -----
#   scripts/pull_charon_updates.sh
#
# REQUIRES: a clean working tree, and a `charon` remote:
#   git remote add charon https://github.com/Duke-Vascular-Informatics/charon.git
# =============================================================================

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

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

FAILED=()
CHANGED_SYNC_SCRIPT=0

for path in "${MANIFEST_PATHS[@]}"; do
  if git checkout charon/main -- "$path" 2>/dev/null; then
    if [[ "$path" == "scripts/sync_contributors.R" || "$path" == "scripts" ]]; then
      CHANGED_SYNC_SCRIPT=1
    fi
  else
    FAILED+=("$path")
  fi
done

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "warning: the following manifest paths do not exist on charon/main and were skipped:" >&2
  printf '  %s\n' "${FAILED[@]}" >&2
fi

if git diff --cached --quiet; then
  echo "Already up to date with charon/main for all manifest paths."
  exit 0
fi

CHARON_SHA="$(git rev-parse --short charon/main)"
git commit -m "chore: sync shared infra from charon@${CHARON_SHA}"

echo ""
echo "Committed. Review with: git show --stat HEAD"
if [[ "$CHANGED_SYNC_SCRIPT" -eq 1 ]]; then
  echo "scripts/sync_contributors.R changed — consider re-running:"
  echo "  Rscript scripts/sync_contributors.R --dry-run"
fi
