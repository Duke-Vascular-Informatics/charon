# Synthetic Data Registry

Shared catalog of disease/procedure/outcome-specific synthetic OMOP CDM datasets
generated via Synthea across studies in this workspace. Lets a new analysis reuse
an existing population instead of standing up its own Synthea → OMOP ETL, and lets
students get a working dataset without a from-scratch generation run.

---

## Hard rule: vocabulary never moves

`omop_vocab` is Athena/UMLS-licensed and **not for redistribution** — see
`docs/SETUP.md` Step 7 (vocab load is "a one-time step per SQL Server instance") and
the root `.gitignore` (`omop_vocab/`, "Never commit vocabulary CSVs"). CPT4
specifically requires each person's own UMLS API key, and its EULA bars transferring
CPT4 content to any party not bound by the agreement.

**Nothing in this registry, and nothing exported by its scripts, ever contains
vocabulary table content** (`concept`, `concept_relationship`, `concept_ancestor`,
`concept_synonym`, `vocabulary`, `drug_strength`, `domain`, `concept_class`,
`relationship`). Only clinical fact tables — which carry bare `concept_id` integers,
not licensed terminology — are ever shared. `export_clinical_tables.R` enforces this
with a hardcoded denylist, not just a convention.

---

## Three ways to use a dataset, in order of cost

### 1. Same machine, already populated (fastest)

If you already have another study's synthetic CDM schema populated on **your own**
SQL Server instance, point at it directly instead of re-running Synthea:

- **Flat-template repos** (e.g. `my-study-desc`, built on `synthea-omop-template`): set
  `cdm_schema:` in `study_params.yaml` to the schema name — `config.R` already reads
  it straight through, no code change needed.
- **Strategus repos** (e.g. `my-study-prog`): build a read-only
  view-overlay schema with `Rscript synthetic_data/scripts/generate_overlay_schema.R
  --source <schema> --target <new_overlay_schema_name>`, then set
  `OMOP_CDM_SCHEMA_OVERRIDE=<new_overlay_schema_name>` in your `.env`.

This is a **same-machine-only** convenience — it works because your own SQL Server
already has the schema populated. Track what's populated locally in
`synthetic_data/local_schemas.yaml` (gitignored, per-machine — see below).

### 2. Cross machine, regenerate (zero data movement)

Anyone who clones a repo in this workspace can reproduce an equivalent dataset with
zero redistribution risk, because nothing but a module JSON path and generation
parameters ever leaves the source repo:

1. `Rscript synthetic_data/scripts/lookup_dataset.R --disease "<term>"` to find a
   registry entry.
2. Copy or reference its `synthea_module_path` file into your own repo's
   `synthea/modules/`.
3. Set matching `generation_params` (population, age_range, state) as Step 4 args.
4. Run your own repo's Steps 3–5 against your own SQL Server, after doing your own
   one-time Athena/UMLS vocab load per `docs/SETUP.md`.

### 3. Cross machine, download (fastest for someone else's clone)

If a registry entry has a non-null `download:` block, a maintainer has already
exported that dataset's **clinical tables only** and published them as a GitHub
Release asset on the source repo:

```bash
Rscript synthetic_data/scripts/import_clinical_tables.R --id pad_oler_ssi_val \
  --target-schema my_new_schema
```

This downloads the release asset, creates the target schema's clinical tables, and
bulk-loads the CSVs. You still need your own vocab loaded (per `docs/SETUP.md`)
before condition/drug/procedure names resolve — the download never includes vocab.

---

## Registering a new dataset

1. Add an entry to `registry.yaml` — at minimum `id`, `source_repo`,
   `synthea_module_path`, `generation_params`, `disease`/`procedure`/
   `outcomes_present`, `status`.
2. After running Step 6 (`workflow/06_quality_check_defined_phenotypes.R`) on the
   populated schema, copy its summary numbers into `last_generated.qc_summary`
   (`person_rows`, `condition_rows`, `mapped_condition_pct`, `condition_era_rows`,
   `drug_era_rows`) rather than inventing a separate stats step.
3. Record the schema name in your own (gitignored) `local_schemas.yaml` so same-machine
   reuse is documented instead of tribal knowledge.
4. List every consuming Strategus study in the `-synth` repo's `consumers.yaml` and in
   this entry's `used_by` (and `consumes_dataset` in `studies.yaml`). They must agree;
   see "Protecting consumers when you change a dataset" below.
5. Optionally publish a download export (see below) so others don't need to
   regenerate from scratch.

## Protecting consumers when you change a dataset

A `-synth` repo tracks the Strategus studies that use its dataset in `consumers.yaml`.
Its `workflow/06` (also `scripts/consumer_cohort_qc.R`) renders each consumer's cohorts
from their circe JSON, as Strategus does, instantiates them against the synthetic CDM,
and checks subject counts per role: target, outcome people who are also in the target,
and each covariate cohort (in Strategus, every cohort that is neither target nor outcome).
Run it with `--enforce_thresholds=true` **before** regenerating or editing a dataset that
has consumers, so you find a broken link in the `-synth` repo instead of in the study.

It checks that cohorts are populated at the subject level; it does not re-run time-at-risk
windows. The consumers are siblings of the `-synth` repo in the workspace, so clone each
one before running it.

## Extending a dataset across analytic use cases — use `versions:`

Introduced 2026-08-06. Two registry shapes are supported, and which one you use
depends on whether other studies depend on the data.

**`last_generated:`** — the original single-build shape, used by most datasets.
Regeneration **replaces the data in place**. Fine while a dataset has one
consumer, or none that has published results.

**`versions:`** — for a dataset that will grow as use cases accumulate.
Regeneration creates a **new version in a new physical schema** instead of
mutating one that consumers are pinned to.

```yaml
versions:
  - version: v1
    status: verified
    physical_schema: omop_synth_my_dataset   # v1 grandfathered, no suffix
    date: 2026-08-02
    pinned_consumers: [my-study-a, my-study-b]
    qc_summary: { ... }
  - version: v2
    status: planned
    physical_schema: omop_synth_my_dataset_v2
    pinned_consumers: [my-study-c]
    targets: { ... }              # what the new signal must look like
    acceptance_criteria: [ ... ]  # what would prove it works
```

**Why this is nearly free:** consumers never bind to the physical schema
directly — they reach it through a read-only view overlay, and
`generate_overlay_schema.R` already takes an arbitrary `--source <schema>`.
Repointing a consumer at another version is an overlay rebuild, not a code
change.

**The rule: never mutate a version that has pinned consumers.** To extend:

1. Generate into a **new** physical schema — Step 5 pins the ETL target via
   `target_cdm_schema_base`.
2. Add a `versions:` block with its own `qc_summary`. Leave existing blocks alone.
3. Migrate consumers **one at a time**: rebuild that consumer's overlay against
   the new schema, then re-check its cohort counts before considering it migrated
   (`Rscript scripts/consumer_cohort_qc.R --enforce_thresholds=true --cdm_schema=<new schema>`
   in the `-synth` repo does this check for every listed consumer).

`lookup_dataset.R` reads both shapes and prints which consumers are pinned to
each version, plus a warning when a dataset is unversioned and therefore mutated
in place.

### Renaming a dataset

Record the old id in **`former_ids:`** (a list; `former_id:` singular is still
read). Old ids resolve in `lookup_dataset.R` searches and in
`import_clinical_tables.R`, which warns and continues — so a rename does not break
consumers that hold the id in committed code. Prefer ids that name the
**population** rather than an outcome: `pad_amp_ed` and `pad_amp_dispo` both went
stale as outcomes were added, which is why the dataset is now just `pad_amp`.

## Publishing a download export

```bash
# 1. Export clinical tables only (devcontainer; hardcoded denylist blocks vocab tables)
Rscript synthetic_data/scripts/export_clinical_tables.R --id pad_oler_ssi_val --dry-run
Rscript synthetic_data/scripts/export_clinical_tables.R --id pad_oler_ssi_val

# 2. The script prints the exact `gh release create` / `gh release upload` command —
#    review it, then run it yourself (publishing a public release is your call, not
#    something this script does automatically).

# 3. Fill in the entry's `download:` block in registry.yaml with the release tag,
#    asset name, and tables_included list the script printed.
```

## Files

| File | Tracked? | Purpose |
|---|---|---|
| `registry.yaml` | yes | Portable recipe + download catalog — safe to share, never contains vocab or raw data |
| `local_schemas.yaml` | **no** (gitignored, like `datasets.yaml`) | Per-machine cache of what's actually populated on your own SQL Server, and any view-overlay schemas built from it |
| `scripts/lookup_dataset.R` | yes | Search `registry.yaml` by disease/procedure/study, annotated with local availability |
| `scripts/generate_overlay_schema.R` | yes | Same-machine only: builds a read-only view-overlay schema for `OMOP_CDM_SCHEMA_OVERRIDE` |
| `scripts/export_clinical_tables.R` | yes | Clinical-tables-only export for publishing a download (devcontainer) |
| `scripts/import_clinical_tables.R` | yes | Downloads and bulk-loads a published export (devcontainer) |
