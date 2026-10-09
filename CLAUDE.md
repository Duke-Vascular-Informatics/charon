# OMOP Study Template — AI Coding Assistant Instructions

This workspace is a reusable scaffold for observational studies on an OMOP CDM v5.4
SQL Server database. It supports cohort characterization, prognostic modelling, and causal
inference using the OHDSI HADES R toolstack. The codebase is intentionally self-contained
and offline-capable.

This repo (`omop-dev-workspace`) is this lab's own real, populated
workspace — a fully registered `WORKSPACE_ROSTER.md`, `studies.yaml`,
`contributors.yaml`, and phenotype catalog, kept private to this
organization. The generic conventions in this file are shared with a
separate, standalone public template repo, **`charon`** ("Containerized
HADES Analytics for Research in OHDSI Networks"), which other labs use to
stand up their own workspace from scratch. Infra fixes flow between the two
via `scripts/pull_charon_updates.sh` / `scripts/push_charon_updates.sh`, not
branch-switching — see `README.md`'s "Staying in sync with charon" section.
Everything in *this* file is generic and applies equally to both repos.

> **For AI coding assistants:** This file contains project-wide coding conventions and
> rules. Use it with GitHub Copilot, Claude Code, or any AI-assisted development tool.
> All instructions apply uniformly across all supported assistants.

---

## Claude Code Model Selection

The dev container defaults to **Haiku** (`claude-haiku-4-5-20251001`) to keep token
costs low. Haiku handles most routine work well. Switch models inside Claude Code
with the `/model` command when the task requires it.

### When to use each model

| Model | Switch with | Use for |
|-------|-------------|---------|
| **Haiku** (default) | `/model haiku` | File edits, git operations, concept lookups, simple Q&A, running scripts, reading error messages, CSV/config edits |
| **Sonnet** | `/model sonnet` | Writing new R analysis code, debugging complex errors, multi-file refactors, cohort SQL authoring, interpreting HADES package output, code review |
| **Opus** | `/model opus` | Study design decisions, complex statistical reasoning, large architectural changes, writing manuscript-quality text, tasks where Sonnet's output quality isn't sufficient |

### Signs you should upgrade from Haiku

- Haiku produces code that doesn't run or misses edge cases → try **Sonnet**
- Haiku misunderstands the clinical context or OHDSI conventions → try **Sonnet**
- Haiku gives shallow or generic answers to design questions → try **Sonnet**
- Sonnet's analysis or writing quality isn't meeting expectations → try **Opus**

### Signs you can stay on Haiku

- The task is mechanical (rename, move, copy, git commit, run a script)
- You're asking a straightforward question with a known answer
- You're editing CSV files or YAML configuration
- The output looks correct on the first try

---

## Project Context

Shared workspace infrastructure (across all studies):
- `phenotype_library/catalog.yaml` — verified concept sets shared across studies, plus a standalone `concept_sets:` registry (schema v1.5+). **Check here before running any vocabulary query.** See `phenotype_library/README.md` for the lookup workflow.
- `phenotype_library/scripts/check_pl.R` — search OHDSI Phenotype Library (Tier 1a)
- `phenotype_library/scripts/check_dvi.R` — search `[DVI]`-prefixed ATLAS cohorts/concept sets, **authoritative** for this workspace (Tier 1b)
- `phenotype_library/scripts/lookup_catalog.R` — search local catalog (Tier 2)
- `phenotype_library/scripts/check_overlap.R` — check whether a candidate concept list already overlaps an existing catalog entry before registering it as new
- `synthetic_data/registry.yaml` — catalog of reusable disease/procedure/outcome-specific synthetic OMOP CDM datasets. **Check here before running a new Synthea generation from scratch.** See `synthetic_data/README.md` for the three reuse tiers (same-machine, cross-machine regenerate, cross-machine download). Vocabulary tables are never redistributed through this mechanism — see `docs/SETUP.md` Step 7.
- `synthetic_data/scripts/lookup_dataset.R` — search the synthetic dataset registry

Study-specific content lives in the study repos, each created from one template.
**Know which kind of repo you are in before suggesting any change:**

| Repo | Template | What it is for |
|---|---|---|
| `<study>` (analysis-core) | `strategus-study-template` | **All analysis.** circe cohort JSON in `inst/cohorts/`, `CreateStrategusAnalysisSpecification.R`, `StrategusCodeToRun.R`, the extract layer. Follow its `CHECKLIST.md` and `docs/STRATEGUS_CONVENTIONS.md`. |
| `<study>-report` | `omop-report-template` | The manuscript only. Renders from result artifacts; **never connects to a database.** |
| `<study>-synth` | `synthea-omop-template` | **Analysis-specific synthetic data generation only** (Synthea module → ETL → QC, `workflow/01–06`). It contains no analysis; analysis belongs in the Strategus repo. |

`synthea-omop-template` is not an analysis template. Do not add analysis code,
report code or bundle-packaging to a `-synth` repo.

Inside a **`-synth` repo**:
- `consumers.yaml` — **the specification**: the Strategus studies that use the dataset. A `-synth` repo defines no cohorts, outcomes or covariates of its own; those come from the consuming studies' own cohort definitions (`inst/Cohorts.csv`, `inst/cohorts/*.json`), read directly.
- `synthea/modules/` — the Synthea disease/procedure module (the main thing you edit)
- `workflow/02` — lists the consuming studies' cohorts (target, outcome, covariate); no database
- `study_params.yaml` — identity, schema names and the database description (no cohort or concept settings)
- `config.R` — settings read from `study_params.yaml` (schemas, output folder, connection)

Infrastructure is pre-wired and should not be modified:
- `R/drivers.R`, `R/connection.R` — database helpers
- `R/consumer_qc.R`, `R/module_coverage.R` — consuming-study QC and module-coverage checks
- `setup/`, `.devcontainer/` — renv and Docker environment
- `workflow/01`, `03–06` — setup, Synthea generation, ETL and QC steps

In a `-synth` repo, **read `config.R` and `consumers.yaml` first** to understand the schema names
and which studies' cohorts the dataset must support before suggesting any code. In a Strategus repo, read its `CLAUDE.md`,
`CHECKLIST.md` and `inst/Cohorts.csv` instead.

---

## Language and Runtime

- All analysis code is written in **R**. Do not suggest Python, Julia, or any other language.
- **R, Java and Python versions are set per workspace**, to match the lab's secure analytics environment, via `R_VERSION`, `JAVA_VERSION` and `PYTHON_VERSION` in `.env` (defaults in `.devcontainer/Dockerfile`: R 4.5.2, Java 17, Python 3.12). Check `R --version`, `java -version` and `renv.lock`'s `R$Version` for the actual targets, and do not use syntax or packages unavailable in that R version.
- A JDK matching `JAVA_VERSION` is required for `DatabaseConnector` / `rJava`; `JAVA_HOME` is set by the dev container.
- Do not change these versions on your own initiative: they must mirror the secure environment. If asked to change them, follow `docs/GETTING_STARTED.md` Step 6.0 (including reconciling `renv.lock`).

---

## Rule 1 — Concept ID Transparency (MANDATORY)

### Lookup tiers — run in order before any new concept ID

**Tier 1a — OHDSI Phenotype Library** (check first, always)

Before deriving any concept set from scratch, check whether a peer-reviewed
published phenotype already exists:

```bash
Rscript phenotype_library/scripts/check_pl.R "<clinical term>"
# or browse: https://ohdsi.github.io/PhenotypeLibrary/articles/CohortDefinitionsInOhdsiPhenotypeLibrary.html
```

If a match is found, record `ohdsi_pl_id` and `ohdsi_pl_checked` in
`phenotype_library/catalog.yaml` and cite the phenotype in study documentation.
This is "check and cite if found" — a local definition MAY still differ from
a published PL phenotype.

**Tier 1b — label-tagged ATLAS cohorts/concept sets — AUTHORITATIVE**

Before using this tier, pick (or confirm) a standing, lab-specific label —
a short prefix like `[DVI]` or `[MYLAB]` — and apply it consistently to
every cohort/concept set your lab publishes on its chosen ATLAS instance
(this workspace's own choice of label and instance is recorded in
`phenotype_library/catalog.yaml`'s alignment header comment, not here, since
it's workspace-specific rather than a generic rule). Cohorts and concept
sets carrying that label are treated as authoritative for this workspace: a
local definition should converge to its tagged counterpart, and any
deliberate difference must be documented as an exception (`alignment_status`
field), not silently diverged from. This is a stronger rule than Tier 1a.

```bash
Rscript phenotype_library/scripts/check_dvi.R "<clinical term>"      # search the cached snapshot
Rscript phenotype_library/scripts/check_dvi.R --refresh              # re-sweep the live instance
Rscript phenotype_library/scripts/check_dvi.R --cohort-id <id> --save <path>
Rscript phenotype_library/scripts/check_dvi.R --concept-set-id <id> --save <path>
```

See `phenotype_library/catalog.yaml`'s alignment header comment for the full
field reference (`external_alignment`, `alignment_status`) and this
workspace's specific label/instance choice. This tooling is **read-only** —
nothing in this workspace writes to ATLAS by default. Any future push-back
to a tagged entry is a separate, explicit, one-off action taken only when
asked for by name, and must refuse any target whose name does not literally
start with the workspace's chosen label.

**Tier 2 — Local phenotype catalog** (check before running a vocab query)

Search the workspace catalog (both the legacy `entries:` list and the
`concept_sets:` registry) for concept sets already verified in a prior study,
and check whether a candidate concept list already overlaps one of them:

```bash
Rscript phenotype_library/scripts/lookup_catalog.R "<clinical term>"
Rscript phenotype_library/scripts/lookup_catalog.R --concept-id <integer>
Rscript phenotype_library/scripts/lookup_catalog.R --status pending
Rscript phenotype_library/scripts/check_overlap.R --concept-ids <id,id,...>
Rscript phenotype_library/scripts/check_overlap.R --atlas-json <path>       # e.g. a check_dvi.R --save output
```

If a `status: verified` entry matches, copy the concept IDs directly into
the cohort's concept set in the consuming study's `inst/cohorts/*.json` (or ATLAS). No live query needed. Add the current study
to the `used_by` list in `phenotype_library/catalog.yaml`.

**Tier 3 — Live vocabulary query** (only when Tiers 1 and 2 both miss)

```bash
# scripts/concept_lookup.R ships in synthea-omop-template: run it from inside a -synth repo (or `cd synthea-omop-template`)
Rscript scripts/concept_lookup.R "<clinical term>" [domain]
# or in Claude Code: /concept-lookup <clinical term> [domain]
```

After confirming the concept IDs, **add a new entry to `phenotype_library/catalog.yaml`**
so the next study does not need to repeat the query.

---

Every OMOP concept ID recommendation must be tagged with one of two labels:

- **[pretraining]** — derived from AI training data only. Treat as a starting hypothesis.
  You **must** accompany this tag with an explicit warning: *"This concept ID has not been
  verified against the live vocabulary. Run a vocabulary query before using it in code or CSV."*
- **[vocab query]** — confirmed by a live query against `omop_vocab` in this SQL Server
  instance. Safe to use for this vocabulary version.

**Hard rule:** Never write a concept ID into code, SQL, or a CSV file without first running
all three tiers of the lookup and labelling the result **[vocab query]**. Pretraining concept
IDs are vocabulary-version-dependent and have been observed to map to completely wrong concepts
(e.g., ancestor IDs cited in OHDSI documentation mapped to unrelated domains in this
vocabulary build).

### Vocabulary lookup workflow

Before committing any concept ID:

```sql
-- Step 1: Find candidate standard concepts
SELECT concept_id, concept_name, domain_id, vocabulary_id, standard_concept, invalid_reason
FROM omop_vocab.concept
WHERE concept_name LIKE '%your term%'
  AND standard_concept = 'S'
  AND invalid_reason IS NULL;

-- Step 2: Expand descendants via concept_ancestor
SELECT c.concept_id, c.concept_name, c.domain_id
FROM omop_vocab.concept_ancestor ca
JOIN omop_vocab.concept c ON c.concept_id = ca.descendant_concept_id
WHERE ca.ancestor_concept_id = <your_chosen_concept_id>
  AND c.standard_concept = 'S'
  AND c.invalid_reason IS NULL;
```

Two ways to run a vocabulary lookup:

**Standalone R script (terminal / batch):**
```bash
# scripts/concept_lookup.R ships in synthea-omop-template: run it from inside a -synth repo (or `cd synthea-omop-template`)
Rscript scripts/concept_lookup.R "<clinical term>" [domain]
# Examples:
Rscript scripts/concept_lookup.R "total hip replacement" Procedure
Rscript scripts/concept_lookup.R "venous thromboembolism" Condition
```

**Interactive (if using Claude Code):**
```
/concept-lookup <clinical term> [domain]
```

Both perform the same two-step query (name/synonym match, then descendant expansion)
and label results `[vocab query]`. The R script is the preferred method for all assistants
and is required when a database connection is not available in the chat environment.

---

## Rule 2 — Package Selection Priority

When selecting packages for any analysis task, apply this strict priority order:

1. **HADES packages first** — use the OHDSI Health Analytics Data-to-Evidence Suite
   (HADES) when a method is covered. Key HADES packages: `DatabaseConnector`, `SqlRender`,
   `FeatureExtraction`, `PatientLevelPrediction`, `CohortMethod`, `CohortDiagnostics`,
   `CohortGenerator`, `EvidenceSynthesis`, `SelfControlledCaseSeries`, `EmpiricalCalibration`.
   Consult the **Book of OHDSI** (https://ohdsi.github.io/TheBookOfOhdsi/) for the canonical
   approach before reaching for any other package.

2. **tidyverse packages second** — when the task falls outside the scope of HADES (data
   wrangling, visualization, string manipulation, I/O), prefer tidyverse packages: `dplyr`,
   `tidyr`, `ggplot2`, `readr`, `purrr`, `stringr`, `lubridate`, `forcats`.

3. **Project CRAN mirror only — scoped to packages a study loads at run time.** Any
   package in an analysis-core repo's `renv.lock` (the Strategus analysis) or a report
   repo's `renv.lock` must be available on the project CRAN mirror (configured via
   `CRAN_MIRROR` in `.env`; defaults to `https://cloud.r-project.org`). Do not suggest a
   GitHub-only, Bioconductor, or other non-CRAN source for one of these packages unless
   it is an OHDSI HADES package pinned in that repo's lockfile.

   Packages used only for code development, concept lookup, or testing — and never
   loaded by a study's analysis or report code — are exempt from this gate and may be
   installed from GitHub (e.g. `PhenotypeLibrary`, used by
   `phenotype_library/scripts/check_pl.R` for Rule 1 Tier 1 lookups). Install via
   `renv::install("OHDSI/<pkg>@<commit-sha>")` (pin to a commit, not a branch) and run
   `renv::snapshot()` afterward, same as any other package addition.

4. **Never suggest** `dbplyr`, `odbc`, `DBI` directly, or any Python/Julia dependency.

### HADES reference by study design

| Study design | Primary HADES packages |
|---|---|
| Cohort characterization | `FeatureExtraction`, `CohortDiagnostics` |
| Prognostic modelling | `PatientLevelPrediction`, `FeatureExtraction` |
| Causal inference | `CohortMethod`, `FeatureExtraction`, `EvidenceSynthesis` |
| SCCS | `SelfControlledCaseSeries`, `EmpiricalCalibration` |
| Data quality | `DataQualityDashboard` |

### Agreement / diagnostic-accuracy statistics

No HADES package covers inter-rater/inter-source agreement (e.g. Cohen's
kappa, concordance correlation) or diagnostic accuracy (sensitivity/
specificity/PPV/NPV) — these come up whenever a study compares two sources
for the same patients (chart abstraction vs. an OMOP-derived phenotype,
one risk score vs. another). Standardize on **`DescTools`**
(`CohenKappa()`, `CCC()`, and its broader general-statistics surface) for
this, adopted for a study's chart-abstraction-vs-OMOP comorbidity comparison
and intended for reuse rather than re-decided per study. `epiR` was
considered first (more clinical-epi-idiomatic naming) but rejected: it
transitively depends on `sf` (spatial/GIS), which needs system-level
libraries (`udunits2`, GDAL, GEOS) that failed to install in the dev
container and cannot be assumed present on a locked-down secure analysis
environment — confirmed by a failed install attempt, not assumed. `DescTools`
is pure R with no such system dependency.

### Package management

- Install via `renv::install()` — never bare `install.packages()`
- After adding a package: `renv::snapshot()`
- CRAN mirror: `options(repos = c(CRAN = Sys.getenv("CRAN_MIRROR", unset = "https://cloud.r-project.org")))`

---

## Rule 3 — Verbose Comments (OHDSI GitHub Style)

All code must include verbose inline comments following the conventions used in OHDSI
GitHub repositories (e.g., HADES package source code, Book of OHDSI example scripts).

**Required commenting style:**

- **File header**: every R script opens with a block comment identifying purpose, inputs,
  outputs, and any important assumptions or prerequisites.
- **Section headers**: use `# ============` banners for major sections (matching the
  sections of the script's own header, e.g. the numbered steps in a `workflow/` script).
- **Function-level**: document what each function does, its parameters, return value, and
  side effects before the function definition.
- **Non-obvious logic**: comment every non-trivial SQL join, window function, or
  HADES configuration argument explaining *why*, not just *what*.
- **Concept IDs inline**: every hardcoded concept ID must have a trailing comment
  identifying the concept name and its source label, e.g.:
  ```r
  procedure_concept_id = 4301351  # [vocab query] SNOMED: Coronary artery bypass graft
  ancestor_concept_id  = 0        # [REPLACE] TODO: insert verified ancestor concept ID
  ```
- **TODO blocks**: use `# TODO [LABEL]:` tags (matching the project convention) so they
  are findable by `Rscript scripts/find_todos.R` (cross-platform).

**Do not**:
- Leave concept IDs with no comment explaining what they represent.
- Write "magic number" SQL filters without explaining the clinical rationale.
- Skip comments in SQL files — SQL comments (`--`) are as important as R comments.

---

## Architecture

**`-synth` repos (`synthea-omop-template`):**
- `config.R` — single source of truth; always read via `get_validation_config()`.
- This repo does not instantiate cohorts (the old `R/cohorts.R` was removed). Cohorts are
  instantiated by Strategus in the analysis-core repo; `consumers.yaml` lists the Strategus
  studies that use the dataset, and their cohorts drive three checks: `workflow/02` lists
  them, `workflow/03` checks the Synthea module (custom + built-in) can produce them
  (`--enforce_coverage=true` to stop on a gap), and `workflow/06` checks the final data.
- All outputs go to `config$output_folder`. Do not hardcode output paths.

**Analysis-core repos (`strategus-study-template`):** cohorts are circe JSON, the
analysis is the Strategus specification, and the repo's own `docs/STRATEGUS_CONVENTIONS.md`
lists workarounds that must not be reverted. Result artifacts go to its `output/`, which
the report repo reads.

**Report repos (`omop-report-template`):** no database access of any kind. A query a
report needs belongs in the analysis-core repo's `R/extract_report_inputs.R`.

---

## Database

- DBMS: **SQL Server** (connection details from `get_validation_config()`).
- Vocabulary schema: `omop_vocab` (shared across studies).
- CDM schema, results schema, and cohort table are all set in `config.R`.
- Use `DatabaseConnector::connect(connection_details)` / `disconnect()` — never leave
  connections open across functions.
- Use `SqlRender::render()` + `SqlRender::translate(sql, "sql server")` for all SQL.

---

## Template Customization Assistance

### Strategus analysis-core and report repos

Work through the repo's own `CHECKLIST.md` (Path A for a new repo). It is the source of
truth for that template; do not substitute the `-synth` checks below.

### `-synth` repos: automated pre-flight check

`scripts/check_setup.R` ships in `synthea-omop-template` (not in the workspace root), so
run it from inside the `-synth` repo:

```bash
Rscript scripts/check_setup.R
```

It scans `study_params.yaml`, `consumers.yaml` (the consuming studies must be present and readable) and the Synthea module without a database connection and prints a sectioned [OK] / [WARN] / [FAIL] checklist. Exit code 0 = ready
to generate data; exit code 1 = items require attention.

**Note:** Claude Code users can also use `/check-setup` skill if available.

### `-synth` repos: manual checklist (when assisting interactively)

When a user asks for setup help and hasn't run the script, perform these checks inline:

1. Read `study_params.yaml` and identify fields still at their default placeholder values
   (`"my_study"`, `"cdm_my_study"`, `"my_cdm_v5.4"`, `"My Study Database"`).
2. Read `consumers.yaml`: it must list at least one consuming Strategus study, and
   `dataset_id` must not be `"my_study_synth_dataset"`.
3. For each consumer, confirm its repo is cloned (sibling of this repo, or `repo_dir`), that
   `inst/Cohorts.csv` and every `inst/cohorts/<id>.json` exist, and that the target and outcome
   ids can be read from `CreateStrategusAnalysisSpecification.R` (or are set in `consumers.yaml`).
4. Check `synthea/modules/*.json` (other than `study_template.json`) for `REPLACE_ME` placeholders.
   (Generation parameters such as population and age range are arguments to `workflow/04`, not settings.)
5. Summarize what is complete and what still needs filling in before generating data,
   using the same [OK] / [WARN] / [FAIL] format as `scripts/check_setup.R`.

---

## Security and Safety

- Never hardcode credentials; all connection parameters come from `get_validation_config()`.
- Do not add calls to external URLs beyond the JDBC driver download in `R/drivers.R`.
- Do not write PHI or PII to disk — output files should contain only aggregate statistics.
- Outputs go to `config$output_folder`, which is gitignored.
- **Do not read `.env` unless the user explicitly asks for it.** `.env` holds live
  secrets (`ANTHROPIC_API_KEY`, `GH_TOKEN`, `ZOTERO_API_KEY`, `MSSQL_SA_PASSWORD`, etc.).
  Reading it pulls those values into the model's context and any session transcript,
  which is the wrong default for AI-assisted development. `.claude/settings.json`
  enforces this with `permissions.ask` rules on `.env` reads (Read tool and common
  Bash viewers like `cat`/`head`/`less`), so attempts will surface a confirmation
  prompt rather than silently succeed. Use `.env.example` (placeholders only, safe to
  read freely) when you need to know what variables exist. Note: this gate covers
  *file reads* — once values are exported as environment variables inside the
  devcontainer, `printenv`/`env` will still surface them, so don't dump those either.

---

## OSF Protocol Hosting (Open Science Framework)

Per-study OSF projects host and version study protocol documents. State lives in
`osf/osf_projects.csv` (study → OSF GUID) and `osf/osf_files.csv` (protocol file →
study); `Rscript osf/osf_sync.R` creates missing projects and uploads/versions
files (re-run after any protocol revision; `--dry-run` previews).

**Privacy rule (MANDATORY): all OSF projects and protocol drafts stay PRIVATE until
explicitly approved for public release.**

- `osf/osf_sync.R` always creates projects with `public = FALSE` and never
  changes visibility. Do not modify this behavior or add any code that makes a
  project public, mints a DOI, or submits a registration via the API.
- Making a project public, minting a DOI, and submitting a preregistration are
  **manual steps on osf.io**, taken only after the study team approves the
  protocol for release. AI assistants must never perform or automate these,
  and must not suggest them as a default next step — flag a draft as
  "ready for review" instead.
- IRB documents (`irbs-protocols/`) may contain institutional or personnel
  detail; before any project is made public, review its file list and remove
  or replace non-public documents.
- See `WORKSPACE_ROSTER.md` for any repo-specific public-release coordination
  requirements (e.g. a federated network study needing sign-off from an
  external partner).

---

## Workspace Layout and Repository Structure

See `WORKSPACE_ROSTER.md` for the current list of repos in this workspace,
their GitHub remotes, and any repo-specific rules (dual push targets,
submodule-pointer bumps, retiring/superseding relationships, etc.). That
file is instance data, not generic template scaffolding — it differs
between the `main` branch (this lab's real, populated roster) and the
`template` branch (a single placeholder entry). Replace it with your own
repos when starting a new workspace from this template; a
`WORKSPACE_ROSTER.md.example` with one illustrative entry is included as a
starting point.

---

## Version Control

### Branch strategy

Each collaborator works on a **personal working branch named after their GitHub username**
(e.g., `jsmith`). `main` is protected and receives changes only through pull requests.
Collaborators should treat `main` as stable.

- **Never push directly to `main`.**
- **Never push to another collaborator's branch.** Your branch is yours alone. If you
  see a branch named after a GitHub username that is not the result of
  `gh api user --jq .login` in the current environment (e.g., a hypothetical
  collaborator `jdoe`), do not check it out, commit to it, or push to it — use
  your own branch instead. This applies even to a branch matching the
  workspace's own maintainer/owner — always verify by running the `gh api
  user` check above rather than treating any specific username as a
  standing exception.
- **Identify your working branch** — it equals your GitHub username:
  ```bash
  BRANCH=$(gh api user --jq .login)   # prints your GitHub username = your branch name
  git branch --show-current            # confirm you are on that branch
  ```
  If `git branch --show-current` does not match your GitHub username, switch now:
  ```bash
  git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH"
  ```
- Always commit and push to your working branch, then open a PR to merge into `main`.
- Do not delete your working branch after merging — it is a permanent working branch.

### Keeping your branch current

Infrastructure, shared phenotype definitions, and Dockerfile fixes are merged into
`main` regularly. **Pull updates frequently** — at minimum before starting any new
work session — to avoid building on stale code or a broken container image:

```bash
BRANCH=$(gh api user --jq .login)
git checkout main && git pull origin main
git checkout "$BRANCH" && git rebase main
git push origin "$BRANCH"
```

Run this in every repo you are actively working in (workspace root and study repos).

**If the rebase produces conflicts where the "conflicting" code is actually
identical or near-identical**, your branch almost certainly still holds commits
from a PR that was already squash-merged. Abort the rebase (`git rebase --abort`)
and use the fix in "After a PR is merged into main" below instead of resolving
the conflict by hand.

### After a PR is merged into main

These repos merge PRs with **squash merge only** (see "Opening and merging PRs"
below). A squash merge rewrites all your commits into one new commit on `main`
under a different hash — so **do not rebase** your working branch onto `main`
after your own PR merges. Rebase tries to replay your original commits on top of
a `main` that already contains their combined diff under a different commit,
which produces spurious conflicts (real `<<<<<<<` markers around code that isn't
actually in conflict).

Instead, confirm the squash captured everything, then reset your branch to match:

```bash
BRANCH=$(gh api user --jq .login)
git fetch origin
git diff origin/main "$BRANCH" --stat   # must be empty — confirms nothing was lost
git checkout "$BRANCH"
git reset --mixed origin/main
git push --force-with-lease origin "$BRANCH"
```

If that diff is not empty, stop and figure out what's different before
resetting — don't force-push over work that never actually landed on `main`.

Run these steps in every repo where the PR was merged before continuing work.

### Opening and merging PRs

Use `gh` (GitHub CLI, available on host and inside the devcontainer):

```bash
BRANCH=$(gh api user --jq .login)

# Create PR
gh pr create --base main --head "$BRANCH" --title "<title>" --body "<body>"

# Merge (squash only — merge commits are disabled on these repos)
gh pr merge <number> --squash --admin
```

The `--admin` flag is required to bypass the CODEOWNERS review requirement when merging
your own PRs. Never pass `--delete-branch` — your working branch is permanent and is
protected from deletion on GitHub. **Never use `--admin` to merge someone else's PR** —
that bypasses the review requirement they need; only use it to bypass CODEOWNERS on your
own PRs.

**PR body — use the repo's `.github/pull_request_template.md` if one exists** (`gh pr
create` picks it up automatically when `--body` is omitted). Fill in the **Handoff
Notes** section with the same summary you would otherwise send by email at the end of a
session: what was done, concept ID verification status (`[pretraining]` vs.
`[vocab query]`, per Rule 1), what was tested/validated, and any open questions or TODOs
for the reviewer. This keeps the handoff attached to the reviewable diff instead of a
side channel, and gives the mentor/reviewer a single place to see provenance before
approving.

### Committing changes

After completing any code change, stage, commit, and push the affected files:

1. Confirm which repository the changed files belong to (see layout table above).
2. Stage only the relevant changed files — do not blanket-stage untracked files.
3. Write a concise conventional commit message: `<type>: <short description>`
   — types: `feat`, `fix`, `refactor`, `docs`, `chore`, `test`.
4. Push to your working branch (`gh api user --jq .login`) using the correct remote.
