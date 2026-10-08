# AI Coding Instructions

> **This project's coding conventions are defined in `CLAUDE.md` at the project root.**
> These rules apply uniformly to **all AI coding assistants**:
> GitHub Copilot, Claude Code, or any other supported tool.
>
> **Before beginning:** Read `CLAUDE.md` to understand project conventions for R code,
> OMOP concept IDs, package selection, commenting style, and database connectivity.

---

## Security and Safety (MANDATORY)

- **Never hardcode credentials.** All connection parameters come from `get_validation_config()` which reads from `config.R` / `study_params.yaml`. Never write server names, passwords, or tokens into code.
- **Do not read `.env` unless the user explicitly asks for it.** `.env` holds live secrets (`ANTHROPIC_API_KEY`, `GH_TOKEN`, `ZOTERO_API_KEY`, `MSSQL_SA_PASSWORD`, etc.). Reading it pulls secrets into the model context. Use `.env.example` (placeholders only) when you need to know what variables exist.
- **Do not write PHI or PII to disk.** Output files must contain only aggregate statistics. Person-level rows (if ever needed) must be de-identified before writing.
- **Do not add external URL calls** beyond the JDBC driver download already wired in `R/drivers.R`.
- **Outputs go to `config$output_folder`** — this directory is gitignored. Never hardcode output paths.
- **Do not dump environment variables.** Inside the devcontainer, `printenv` or `env` bypasses the `.env` file-read gate and will surface live secrets in terminal output.

---

## Workspace Layout and Repository Structure

See `WORKSPACE_ROSTER.md` for the current list of repos in this workspace,
their GitHub remotes, and any repo-specific rules (dual push targets,
submodule-pointer bumps, retiring/superseding relationships, etc.). That
file is instance data, not generic template scaffolding — it differs
between this lab's own workspace (fully registered) and the `charon`
template (a single placeholder entry). Replace it with your own repos when
starting a new workspace from this template.

---

## Version Control and Branch Strategy

- Each collaborator works on a **personal working branch named after their GitHub username** (e.g., `jsmith`). `main` is protected — receives changes only through pull requests.
- **Never push directly to `main`.**
- **Never push to another collaborator's branch.** If you see a branch named after someone else (e.g., `agarcia`), do not check it out, commit to it, or push to it.
- **Pull updates at the start of every work session** — infrastructure, Dockerfile, and shared phenotype definitions are updated frequently on `main`. Rebase your branch onto updated `main` before starting new work.
- **Identify the working branch** — it equals the current user's GitHub username:
  ```bash
  BRANCH=$(gh api user --jq .login)   # working branch = GitHub username
  git branch --show-current           # confirm you are on that branch
  ```
- Always commit and push to the working branch, then open a PR:
  ```bash
  BRANCH=$(gh api user --jq .login)
  gh pr create --base main --head "$BRANCH" --title "<title>" --body "<body>"
  ```
- Merge with **squash only** — merge commits are disabled:
  ```bash
  gh pr merge <number> --squash --admin
  ```
  The `--admin` flag is required to bypass the CODEOWNERS review requirement on your own PRs. **Never use `--admin` to merge someone else's PR** — that bypasses the review requirement they need. **Never pass `--delete-branch`** — the working branch is permanent.
- **PR body** — use the repo's `.github/pull_request_template.md` if one exists (`gh pr create` picks it up automatically when `--body` is omitted). Fill in the **Handoff Notes** section with what was done, concept ID verification status (`[pretraining]` vs. `[vocab query]`), what was tested/validated, and any open questions or TODOs for the reviewer.
- **After a PR merges**, rebase the working branch onto updated `main`:
  ```bash
  BRANCH=$(gh api user --jq .login)
  git fetch origin
  git checkout "$BRANCH" && git rebase origin/main
  git push origin "$BRANCH"
  ```
  Use `rebase` (not `reset --hard`) — `reset --hard` silently discards any commits not yet in `main`.

- **Commit message format** — use conventional commits: `<type>: <short imperative description>`
  - Types: `feat` | `fix` | `refactor` | `docs` | `chore` | `test`
  - Body: one to three sentences on *why*, not *what*.
  - Trailer: `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`

---

## Template Customization — Pre-flight Check

Know the repo type first. Strategus analysis-core and report repos have their own `CHECKLIST.md` — use it. The check below is for `-synth` repos (`synthea-omop-template`), which are for synthetic data generation only; analysis lives in the Strategus repo.

When a user asks for setup help in a `-synth` repo, run the automated check first (the script ships in that repo, not the workspace root):

```bash
Rscript scripts/check_setup.R
```

This scans `study_params.yaml`, cohort SQL files, and covariate CSVs without a database connection and prints `[OK]` / `[WARN]` / `[FAIL]` for each item. Exit code 0 = ready to generate data.

If the script is not available, check these items manually:

1. Read `study_params.yaml` — flag fields still at placeholder values: `"my_study"`, `"cdm_my_study"`, `"my_study_results"`, `"my_study_cohort"`, concept IDs = `0`.
2. Read the cohort SQL files referenced in `target.sql_file`, `outcome.sql_file`, `comparator.sql_file` — flag any `concept_id = 0`.
3. Check `covariates/covariates.csv` for placeholder rows (`covariate_id` matching `covariate_1`, `covariate_2`, etc.).
4. Check `covariates/covariate_concepts.csv` for `concept_id = 0` rows.
5. Confirm the generation parameters (population, age range, seed) are set.

Report using `[OK]` / `[WARN]` / `[FAIL]` format consistent with `scripts/check_setup.R`.

---

## OSF Protocol Hosting (Open Science Framework)

Per-study OSF projects host and version study protocol documents. State lives in `osf/osf_projects.csv` (study → OSF GUID) and `osf/osf_files.csv` (protocol file → study); `Rscript osf/osf_sync.R` creates missing projects and uploads/versions files.

**Privacy rule (MANDATORY): all OSF projects and protocol drafts stay PRIVATE until explicitly approved for public release.**

- `osf/osf_sync.R` always creates projects with `public = FALSE` and never changes visibility. Do not modify this behavior or add any code that makes a project public, mints a DOI, or submits a registration via the API.
- Making a project public, minting a DOI, and submitting a preregistration are **manual steps on osf.io**, taken only after the study team approves the protocol for release. Never perform or automate these, and never suggest them as a default next step — flag a draft as "ready for review" instead.
- See `WORKSPACE_ROSTER.md` for any repo-specific public-release coordination requirements (e.g. a federated network study needing sign-off from an external partner).
