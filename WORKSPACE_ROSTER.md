# Workspace Roster — Repos and Repo-Specific Rules

This file is instance data, not generic template scaffolding — it lists
your lab's own repos, their GitHub remotes, and any repo-specific quirks.
Replace the placeholder content below with your own repos.

`CLAUDE.md` covers the generic, reusable conventions (branch strategy,
concept-ID rules, package selection, etc.) that apply regardless of which
repos are in your roster; this file covers only the roster itself.

## Workspace Layout and Repository Structure

The workspace root contains shared infrastructure plus several independent
study repositories. Each subfolder is its own git repository with its own
remotes. **Never run git commands from one repo against files belonging to
another.**

| Folder | Type | GitHub remote |
|--------|------|---------------|
| `/` (workspace root) | git repo | `my-org/my-omop-dev-workspace` |
| `synthea-omop-template/` | git submodule | `Duke-Vascular-Informatics/synthea-omop-template` |
| `omop-etl-template/` | git submodule | `Duke-Vascular-Informatics/omop-etl-template` |
| `strategus-study-template/` | git submodule | `Duke-Vascular-Informatics/strategus-study-template` (scaffold for bucket-2 analysis-core repos; supersedes `synthea-omop-template` for new studies) |
| `omop-report-template/` | git submodule | `Duke-Vascular-Informatics/omop-report-template` (scaffold for bucket-3b `<study>-report` repos) |
| `my-study-desc/` | git repo | `my-org/my-study-desc` (placeholder study — replace with your own repos) |

**Push rule — applies to every repo in this table:** always push to **your
own working branch** (`$BRANCH` = `$(gh api user --jq .login)`), never
directly to `main` and never to another collaborator's branch. Then open a
PR to merge into `main`. See `CLAUDE.md`'s "Branch strategy" section.

**Important rules (example pattern — replace with your own):**

- `synthea-omop-template/`, `omop-etl-template/`, `strategus-study-template/`,
  and `omop-report-template/` are git submodules. After committing inside any
  of them, also update the submodule pointer in the root repo with a commit
  there.
- If a study needs its own outcome-specific synthetic dataset that doesn't
  belong in any existing study's own data, consider a dedicated
  `<study>-synth` repo (scaffolded from `synthea-omop-template`, Steps 1-6
  only, registered in `synthetic_data/registry.yaml`) rather than bolting an
  unrelated outcome's module onto an existing study repo. Adopt or adapt
  this pattern as your roster grows.
- A public release of a repo built on a federated/multi-site network study
  may need coordination with external partner sites before going public —
  note any such repo-specific requirement here (see `CLAUDE.md`'s OSF
  Protocol Hosting section for the general public-release rule this adds
  to).
