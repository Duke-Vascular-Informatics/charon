# Commands Index (Canonical)

Use this file as the single source of truth for executable commands used across setup,
validation, analysis, and packaging.

When a command changes:
1. Update this file first.
2. Update `GETTING_STARTED.md` step text if needed.
3. Keep other docs linked here instead of duplicating command blocks.

---

## Core Commands

| Task | Command | Canonical Step |
|------|---------|----------------|
| Set Git identity (one-time) | `git config --global user.name "Your Name"` | [Step 2](GETTING_STARTED.md#step-2-install-git-5-minutes) |
| Clone the workspace repo | `git clone https://github.com/<your-org>/<your-workspace-repo>.git` | [Step 5](GETTING_STARTED.md#step-5-clone-the-workspace-repository-2-minutes) |
| Verify the dev container environment | `echo $IN_DEV_CONTAINER && R --version && echo $MSSQL_HOST && docker ps` | [Step 7](GETTING_STARTED.md#step-7-verify-your-environment-2-minutes) |
| Authenticate git for your AI assistant | `gh auth login --with-token <<< "$GH_TOKEN"` | [Step 7](GETTING_STARTED.md#step-7-verify-your-environment-2-minutes) |
| Rebuild CPT-4 codes (optional, requires UMLS key) | `bash cpt.sh YOUR_API_KEY_HERE` | [Step 8](GETTING_STARTED.md#step-8-download-omop-vocabulary-files-3060-minutes-one-time) |
| Load OMOP vocabulary schema | `Rscript infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template` | [Step 9](GETTING_STARTED.md#step-9-load-omop-vocabulary-into-sql-server-3060-minutes-one-time) |
| Clone your analysis-core study repo | `git clone https://github.com/<your-org>/<your-study>.git` | [Step 10](GETTING_STARTED.md#step-10-create-your-study-repositories-10-minutes) |
| Create your working branch | `BRANCH=$(gh api user --jq .login) && git checkout -b "$BRANCH" && git push -u origin "$BRANCH"` | [Step 10](GETTING_STARTED.md#step-10-create-your-study-repositories-10-minutes) |
| Clone your report repo | `git clone https://github.com/<your-org>/<your-study>-report.git` | [Step 10](GETTING_STARTED.md#step-10-create-your-study-repositories-10-minutes) |
| Environment setup (`-synth` repo) | `Rscript workflow/01_setup_synthea_etl_qc_env.R` | [Step 11](GETTING_STARTED.md#step-11-run-the-study-workflow-23-hours-total) |
| List the cohorts a `-synth` dataset must support (from `consumers.yaml`; `-synth` repo) | `Rscript workflow/02_define_omop_cohort_outcome_covariates.R` | [Step 11](GETTING_STARTED.md#step-11-run-the-study-workflow-23-hours-total) |
| Validate Synthea module | `Rscript workflow/03_generate_synthea_module_artifacts.R` | [Step 11](GETTING_STARTED.md#step-11-run-the-study-workflow-23-hours-total) |
| Generate Synthea CSV (bash) | `bash workflow/04_generate_synthea_csv.sh` | [Step 11](GETTING_STARTED.md#step-11-run-the-study-workflow-23-hours-total) |
| Generate Synthea CSV (PowerShell) | `powershell -ExecutionPolicy Bypass -File workflow/04_generate_synthea_csv.ps1` | [Step 11](GETTING_STARTED.md#step-11-run-the-study-workflow-23-hours-total) |
| Run ETL | `Rscript workflow/05_etl_csv_to_omop.R` | [Step 11](GETTING_STARTED.md#step-11-run-the-study-workflow-23-hours-total) |
| Run QC checks | `Rscript workflow/06_quality_check_defined_phenotypes.R` | [Step 11](GETTING_STARTED.md#step-11-run-the-study-workflow-23-hours-total) |
| Generate the manuscript report (`omop-report-template`) | `Rscript GenerateReport.R` | [Step 10.5](GETTING_STARTED.md#step-10-create-your-study-repositories-10-minutes) |
| Validate customization status (`-synth` repo) | `Rscript scripts/check_setup.R` | [Analyst Playbook](ANALYST_PLAYBOOK.md) |
| Look up OMOP concepts (run inside `synthea-omop-template/` or a `-synth` repo) | `Rscript scripts/concept_lookup.R "<clinical term>" <Domain>` | [Analyst Playbook](ANALYST_PLAYBOOK.md) |
| Create support bundle (`-synth` repo) | `Rscript scripts/create_support_bundle.R` | [Analyst Playbook](ANALYST_PLAYBOOK.md) |

The numbered `workflow/01–06` commands above belong to **`-synth` repos**
(`synthea-omop-template`), which only generate synthetic data. The analysis runs in a
`strategus-study-template` repo and the report in an `omop-report-template` repo; neither
has a `workflow/` folder — see each template's own `CHECKLIST.md` for its commands.

---

## Guardrails

- Do not use `Rscript` to run `.sh` or `.ps1` files.
- Keep command examples consistent with this file and `GETTING_STARTED.md`.
- If a command appears in more than one doc, link here instead of duplicating the snippet.
