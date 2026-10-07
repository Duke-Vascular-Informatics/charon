# Releasing (Zenodo-archived repos)

This workspace's template repos (`strategus-study-template`,
`synthea-omop-template`, `omop-report-template`, `omop-etl-template`,
`omop-report-toolkit`) and `charon` itself are archived on Zenodo: every
published GitHub release gets a version DOI, and all versions share one
concept DOI that always resolves to the latest. A release is therefore
permanent and citable — cut one when it is worth citing, not on every merge.

## Check what needs releasing

```bash
Rscript scripts/release_check.R                  # plan to stdout
Rscript scripts/release_check.R --out-dir plan   # also write plan + drafted release notes
```

`scripts/release_check.R` is **read-only**. For each repo it diffs the default
branch against the latest GitHub release, recommends `none` / `patch` /
`minor` / `major` (or "first release"), prints the evidence, flags metadata
drift (DESCRIPTION/CITATION version vs. tag, missing Zenodo webhook, tag not
archived on Zenodo), and prints an ordered plan with the exact commands.
Nothing is tagged or pushed by the tool. Repos come from `studies.yaml`
`templates:` plus an optional top-level `release_repos:` list, the `charon` /
`origin` git remotes, and `--repo OWNER/NAME`.

## What warrants a release

| Level | Typical triggers (what the tool looks for) |
|---|---|
| **major** | Anything that breaks an existing user: a removed/renamed script, workflow step or exported function; a removed submodule; a `type!:` / `BREAKING CHANGE` commit; a changed sync contract. A change of scope (e.g. `synthea-omop-template` becoming synthetic-data-only) is major. |
| **minor** | New capability that stays compatible: a `feat:` commit; a new script/workflow step/exported function; a new submodule. |
| **patch** | A fix or a functional change: a `fix:` commit; a modified code/infra file (not comment-only); a submodule pointer bump; substantial docs churn. |
| **none** | README/CITATION/CONTRIBUTORS/CI/instance-registry edits, comment-only code edits, small docs edits, DOI badges, funding text. |

For a `0.y.z` version semver reserves the minor number for breaking changes,
so the tool shifts major -> next minor and minor/patch -> next patch.

The tool encodes heuristics, not judgment: read the evidence, and overrule it
when it is wrong (e.g. a "modified code file" that is really a typo fix).
A practical test: *would I be uneasy telling someone to cite or clone the
existing tag?* If yes, release.

## Mechanics of a release (what the plan walks you through)

1. In a PR: bump `date-released` in `CITATION.cff` (and `version:` /
   `DESCRIPTION Version:` where those exist) to the release date and version.
   A stale `date-released` is the usual mistake.
2. Squash-merge the PR and reset your personal branch (see `CLAUDE.md`,
   "After a PR is merged").
3. `gh release create vX.Y.Z --target main ...` with edited notes. Never move
   or re-create an existing tag — Zenodo has already archived it.
4. Confirm the new version appears under the concept DOI (the Zenodo webhook
   shows one `202` and several harmless `409` duplicates), then record the new
   version DOI wherever you cite it.
5. Order matters: release template repos first, bump their submodule pointers
   in charon, then release charon.

A repo must be **enabled in Zenodo** (GitHub integration) before the release
you want archived — Zenodo only archives releases made after it is enabled.
