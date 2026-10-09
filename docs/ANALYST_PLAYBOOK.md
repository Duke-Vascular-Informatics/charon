# Analyst Playbook

The day-to-day companion to [`GETTING_STARTED.md`](GETTING_STARTED.md). Read the
[README](../README.md) and finish Getting Started first; this page assumes the
workspace, vocabulary and your study repos already exist.

- Full procedures: [`GETTING_STARTED.md`](GETTING_STARTED.md)
- Command snippets: [`COMMANDS.md`](COMMANDS.md)
- Governance and releases (maintainers): [`MAINTAINER_PLAYBOOK.md`](MAINTAINER_PLAYBOOK.md)

---

## Where do I start?

| Situation | Go to |
|---|---|
| New machine, nothing installed | Getting Started Steps 1–9 |
| Machine is set up, starting a new study | Getting Started Step 10 |
| Machine is set up, returning to an existing study | [A typical session](#a-typical-session) below |
| Need a synthetic dataset | [Need synthetic data?](#need-synthetic-data) |
| Need a concept ID | [Finding concept IDs](#finding-concept-ids) |
| Something is broken | [When something breaks](#when-something-breaks) |

---

## A typical session

1. **Start Docker Desktop**, open the workspace in VS Code, and reopen in the
   container. SQL Server starts with it.
2. **Update your branch** in every repo you will touch (your branch is named
   after your GitHub username):

   ```bash
   BRANCH=$(gh api user --jq .login)
   git checkout main && git pull origin main
   git checkout "$BRANCH" && git rebase main
   ```

   If the rebase shows "conflicts" in code that looks identical on both sides,
   your branch still holds commits from a PR that was squash-merged. Run
   `git rebase --abort` and use the post-merge reset procedure in
   [`CLAUDE.md`](../CLAUDE.md) instead.
3. **Work in your study repo**, following its `CHECKLIST.md`.
4. **Commit to your branch, push, and open a PR** into `main`. Fill in the PR's
   Handoff Notes: what you did, which concept IDs are `[vocab query]` vs
   `[pretraining]`, what you tested. Merge is squash-only.

## Finding concept IDs

Never type a concept ID from memory. Work down the tiers and stop at the first
hit (full detail in [`phenotype_library/README.md`](../phenotype_library/README.md)):

```bash
# Tier 1a — OHDSI Phenotype Library (peer reviewed)
Rscript phenotype_library/scripts/check_pl.R "<clinical term>"

# Tier 1b — your lab's label-prefixed ATLAS definitions (authoritative)
Rscript phenotype_library/scripts/check_dvi.R "<clinical term>"

# Tier 2 — concept sets already verified in this workspace
Rscript phenotype_library/scripts/lookup_catalog.R "<clinical term>"

# Tier 3 — live query against your loaded vocabulary (only if 1 and 2 miss)
cd synthea-omop-template && Rscript scripts/concept_lookup.R "<clinical term>" <Domain>
```

After a Tier 3 lookup, add the result to `phenotype_library/catalog.yaml` so the
next study skips it. Check that a candidate list does not already overlap a
catalog entry with `phenotype_library/scripts/check_overlap.R`.

`check_dvi.R` searches a cached snapshot of your ATLAS instance; if a definition
looks missing, `--refresh` re-sweeps the live instance. It is read-only.

## Need synthetic data?

Before generating anything, check whether a suitable dataset exists:

```bash
Rscript synthetic_data/scripts/lookup_dataset.R --disease "<term>"
```

There are three ways to reuse one, cheapest first: point at a schema already
populated on your machine; regenerate it from a Synthea module with no data
transfer; or download clinical tables someone exported (vocabulary tables are
never shared). See [`synthetic_data/README.md`](../synthetic_data/README.md).
Only if nothing fits do you create a `-synth` repo (Getting Started Step 11).

## Real CDM vs synthetic CDM

| | Synthetic (your dev container) | Real (secure environment) |
|---|---|---|
| Where | Local SQL Server, `omop_synth` | Your institution's CDM |
| Who sees the data | You | Only people with access at that site |
| What you do there | Write and test code | Run the bundle your analysis-core repo built |
| What leaves | Anything (no PHI) | Aggregate results only, after review |

Never copy data, row-level output, or credentials from a secure environment
into any repo in this workspace.

## When something breaks

1. Identify the layer:

   | Symptom | Likely layer | Look at |
   |---|---|---|
   | `connection refused` / `localhost:1433` | Container networking | Getting Started → Troubleshooting |
   | `Login failed for user 'SA'` | Password changed after the volume was created | [SETUP.md](SETUP.md#troubleshooting) |
   | Container build fails at package restore | GitHub rate limit — missing `GH_TOKEN` | `.env` |
   | Loader exits silently | Docker RAM too low | [Vocabulary troubleshooting](TROUBLESHOOTING_VOCAB_LOAD.md) |
   | ETL or Synthea failure | `-synth` repo workflow | [ETL troubleshooting](TROUBLESHOOTING_ETL.md) |
   | Strategus run fails oddly | Known template defect | `docs/STRATEGUS_CONVENTIONS.md` in your analysis-core repo |

2. Try one fix. If still stuck, ask for help and include the output of
   `git status`, your branch name, and the last 50 lines of the failing command.
3. In a `synthea-omop-template`-based repo, `Rscript scripts/create_support_bundle.R`
   packages this (with `study_params.yaml` redacted) for you.

## Tools only some repos have

These ship in `synthea-omop-template`, not in the workspace root or the
Strategus template, so they exist only in `-synth` repos:

- `Rscript scripts/check_setup.R` — pre-flight `[OK]/[WARN]/[FAIL]` report on
  placeholder values in `study_params.yaml`, whether the consuming studies in `consumers.yaml`
  are present and readable, and `REPLACE_ME` placeholders in the Synthea module.
- `Rscript scripts/find_todos.R` — lists every `# TODO [LABEL]:` marker.
- `bash scripts/hooks/install_git_hooks.sh` — installs pre-commit/pre-push
  hooks that run those checks. Bypass once with `SKIP_ANALYST_HOOKS=1 git commit ...`.

In VS Code you can also run common ones from **Terminal → Run Task**.

## Working with the AI assistant

- It reads [`CLAUDE.md`](../CLAUDE.md) automatically; that file is where the
  concept-ID, package and commenting rules come from.
- It runs `git` and `gh` as **you**, with your token. It shows you push and
  merge commands and will not push to `main`.
- It must tag every concept ID `[vocab query]` or `[pretraining]`. Reject any
  `[pretraining]` ID before it reaches a file.
- Model choice: Haiku for mechanical work, Sonnet for new analysis code and
  debugging, Opus for design decisions (`/model sonnet`).
- It will not read `.env` unless you ask — it holds live secrets.
