# Phenotype Library

Shared concept set and phenotype catalog for all OMOP observational studies in
this workspace. Eliminates redundant vocabulary queries across studies and provides
a single source of truth for verified OMOP concept IDs.

---

## Lookup Tiers — Mandatory Before Any Concept ID

Before writing any concept ID into a study's `cohorts/`, `covariates/`, or SQL:

```
Tier 1a → Check OHDSI Phenotype Library
Tier 1b → Check your lab's label-prefixed ATLAS cohorts/concept sets (AUTHORITATIVE for this workspace)
Tier 2  → Check this catalog (entries: and concept_sets:), and check for overlap with a candidate list
Tier 3  → Run a live vocabulary query (only if Tiers 1 and 2 miss)
```

### Tier 1a — OHDSI Phenotype Library

The OHDSI PL contains peer-reviewed, community-validated cohort definitions.
If a published phenotype exists, prefer it over deriving your own.

**Browse online:**
```
https://ohdsi.github.io/PhenotypeLibrary/articles/CohortDefinitionsInOhdsiPhenotypeLibrary.html
```

**Search from the terminal:**
```bash
Rscript phenotype_library/scripts/check_pl.R "<clinical term>"

# Examples:
Rscript phenotype_library/scripts/check_pl.R "surgical site infection"
Rscript phenotype_library/scripts/check_pl.R "peripheral arterial disease"
Rscript phenotype_library/scripts/check_pl.R "heart failure"
```

If a match is found, record `ohdsi_pl_id` and `ohdsi_pl_checked` in `catalog.yaml`
and cite the phenotype in study documentation. This tier is "check and cite if
found" — a local definition MAY still differ from a published PL phenotype.

### Tier 1b — Label-Prefixed ATLAS Cohorts/Concept Sets — AUTHORITATIVE

Pick (or confirm) a standing, lab-specific label — a short prefix like
`[DVI]` or `[MYLAB]` — and apply it consistently to every cohort/concept set
your lab publishes on its chosen ATLAS instance (the public OHDSI demo
instance, atlas-demo.ohdsi.org, or your own private instance). The scripts
below use `[DVI]` as a literal example value — set `ATLAS_LABEL_PREFIX` at
the top of each one to your own lab's choice, and record that choice (plus
which ATLAS instance) in `catalog.yaml`'s alignment header comment.

Cohorts and concept sets carrying your label are **authoritative** for this
workspace — stronger than Tier 1a. A local phenotype or concept set should
converge to its tagged counterpart; any deliberate difference must be
recorded via the `alignment_status` field (see the alignment comment block
near the top of `catalog.yaml`), not silently diverged from.

```bash
# Search the local cached snapshot (fast, no network call):
Rscript phenotype_library/scripts/check_dvi.R "<clinical term>"
Rscript phenotype_library/scripts/check_dvi.R --list

# Re-sweep the live instance and rewrite the cache — a public/shared instance
# is mutable, so "not found" only means "not seen as of the last refresh",
# not "confirmed absent":
Rscript phenotype_library/scripts/check_dvi.R --refresh

# Pull a full definition for a known id (feed the saved file to check_overlap.R):
Rscript phenotype_library/scripts/check_dvi.R --cohort-id <id> --save /tmp/dvi.json
Rscript phenotype_library/scripts/check_dvi.R --concept-set-id <id> --save /tmp/dvi.json
```

The discovery tooling (`check_dvi.R`) is **read-only**. Two tools write to
ATLAS — `scripts/push_dvi_concept_sets.R` (**create**) and
`scripts/update_dvi_concept_sets.R` (**update in place**) — both deliberate,
standalone, explicitly-invoked writers driven from verified catalog entries. It is dry-run by default, is wired into no
search/refresh/sync path, and hard-refuses any target whose name does not
literally start with your chosen label. See "Pushing verified entries" below.

### Tier 2 — Local Catalog

Search the catalog — both the legacy `entries:` phenotype list and the
standalone `concept_sets:` registry (schema v1.5+) — for previously verified
concept sets, and check whether a candidate concept list (e.g. an export
from Tier 1b) already overlaps one of them before registering it as new:

```bash
Rscript phenotype_library/scripts/lookup_catalog.R "<clinical term>"

# Examples:
Rscript phenotype_library/scripts/lookup_catalog.R "bypass"
Rscript phenotype_library/scripts/lookup_catalog.R "diabetes"
Rscript phenotype_library/scripts/lookup_catalog.R --concept-id 4236706
Rscript phenotype_library/scripts/lookup_catalog.R --study my-study-desc

# Hierarchy traversal:
Rscript phenotype_library/scripts/lookup_catalog.R --children-of example_phenotype
Rscript phenotype_library/scripts/lookup_catalog.R --parent-of example_concept_set

# Overlap check — does a candidate concept list already match something here?
Rscript phenotype_library/scripts/check_overlap.R --concept-ids 317309,201820
Rscript phenotype_library/scripts/check_overlap.R --atlas-json /tmp/dvi.json
Rscript phenotype_library/scripts/check_overlap.R --entry example_phenotype   # check an existing entry against the rest of the catalog
```

If a `status: verified` entry matches, copy its concept IDs directly. The
`vocab_query_date` confirms they were checked against a live database.
`check_overlap.R` only does an exact concept_id match against what's
literally written in `catalog.yaml` — it does not expand
`include_descendants: true` ancestors against the live vocabulary, so treat
its output as narrowing down what to check via Tier 3, not as a final answer.

### Tier 3 — Live Vocabulary Query

Only run this if the OHDSI PL and the catalog both miss:

**In Claude Code:**
```
/concept-lookup <clinical term> [domain]
```

**From the terminal:**
```bash
Rscript scripts/concept_lookup.R "<clinical term>" [domain]
```

After confirming the concept IDs, **add a new entry to `catalog.yaml`** so the
next study doesn't need to repeat the query.

---

## Adding a New Entry to the Catalog

Copy the template below into `catalog.yaml` and fill it in:

```yaml
- id: my_phenotype             # unique, snake_case
  name: "Human-Readable Name"
  parent_ids:                    # list of parent entry ids if this is a subgroup; omit entirely for top-level
    - my_parent_phenotype        # an entry can belong to more than one composite (e.g. one condition could be
                                  # both an outcome-composite component and a frailty-index deficit) —
                                  # list every parent it genuinely belongs to, not just the first one found
  description: >
    One to three sentences: what clinical concept this represents, what it
    excludes, and any known caveats.
  domain: Condition             # Condition | Procedure | Measurement | Drug | Observation | Visit | Demographic | Composite
  ohdsi_pl_id: ~                # integer if found in OHDSI PL; ~ if not found or not checked
  ohdsi_pl_checked: "2026-05-12"  # ISO date you ran check_pl.R; ~ if not yet checked
  status: verified              # verified | pending | partial
  subgroup_ids:                 # list child entry ids if this entry has subgroups; omit if none
    - my_subgroup_phenotype
  concept_sets:
    - concept_id: 1234567
      concept_name: "Concept name from omop_vocab"
      vocabulary: SNOMED        # SNOMED | LOINC | ATC | ICD10CM | Gender | Race | Visit | OMOP
      standard_concept: S       # S (Standard) or C (Classification, ATC ancestors only)
      include_descendants: true
      vocab_query_date: "2026-05-12"
      notes: "Optional: SNOMED code, key descendants, exclusion rationale."
  used_by:
    - study_id: my-study-repo
      role: covariate           # target_cohort | outcome_cohort | covariate | report_rollup
  notes: "Any additional context not covered above."
```

### Rules

- Never set `status: verified` unless **all** concept IDs in the entry have a `vocab_query_date`.
- Never copy concept IDs from this catalog into study code without first checking that `status` is `verified`.
- If `ohdsi_pl_checked` is `~` (null), run `check_pl.R` before adding the entry — record the result even if nothing was found.
- Add yourself to `used_by` whenever you consume an entry in a new study.
- Set `parent_ids` (a list) when your entry is a clinical subgroup of one or more existing entries (e.g. a more specific population, drug subclass, or a shared component of two composite indices). Update each parent entry's `subgroup_ids` list to include your new entry's id — and verify the two lists actually agree with a script (`lookup_catalog.R --children-of <parent_id>` should return the same set as that parent's `subgroup_ids`); this drifted out of sync silently at least once before it was caught.

---

## Catalog Contents

Indentation in the Entry ID column indicates subgroup relationships.

| Entry ID | Name | Domain | Status | Studies |
|----------|------|--------|--------|---------|
| `example_phenotype` | Example Phenotype | Condition | **pending** | my-study-desc |

---

## OMOP-Limited Phenotypes

Some phenotypes of clinical interest cannot be reliably ascertained from the
OMOP CDM alone because the underlying data quality is insufficient — not
because the concept ID is unverified, but because the ETL coverage is
structurally poor for that concept type.

These are tracked in a separate `omop_limited_entries:` section at the bottom
of `catalog.yaml`. They are **not** part of the lookup-tier workflow and
should **not** be used as concept ID sources in `covariates/` or `cohorts/`
without first building and validating the indicated extraction pipeline.

### Development paths

| Path | Meaning |
|------|---------|
| `clarity` | Structured Epic Clarity SQL query against Clarity tables/columns |
| `nlp` | Unstructured clinical notes — NLP pipeline, regex, or LLM extraction |
| `imaging` | Radiology reports, DICOM, or imaging AI model |
| `clarity+nlp` | Combination: structured Clarity for what's coded, NLP for the rest |

Each entry carries:
- `omop_quality_issue` — why the CDM fails for this concept
- `development_path` — one of the four tags above
- `clarity_notes` — Clarity table/column hints (for `clarity` and `clarity+nlp` paths)
- `nlp_notes` — key terms, regex patterns, note types (for `nlp` and `clarity+nlp` paths)

### OMOP-Limited Catalog Contents

| Entry ID | Name | Development Path | Studies |
|----------|------|-----------------|---------|
| `example_omop_limited` | Example Concept Requiring Non-CDM Data | nlp | my-study-desc |

---

## File Structure

```
phenotype_library/
  catalog.yaml                ← master concept set index (edit this)
  dvi_index.yaml              ← cached snapshot of label-prefixed ATLAS entries (see check_dvi.R --refresh)
  README.md                   ← this file
  scripts/
    check_pl.R                ← Tier 1a: search OHDSI Phenotype Library
    check_dvi.R               ← Tier 1b: search label-prefixed ATLAS cohorts/concept sets (authoritative, read-only)
    lookup_catalog.R          ← Tier 2: search catalog.yaml (entries: and concept_sets:)
    check_overlap.R           ← Tier 2: check a candidate concept list against the catalog
    fetch_dvi_members.R       ← read-only: cache existing tagged concept-set memberships (for the writer's dedup)
    push_dvi_concept_sets.R   ← WRITE: create label-tagged concept sets from verified catalog entries (dry-run default, label-only)
    update_dvi_concept_sets.R ← WRITE: update an EXISTING tagged set's items to match its catalog entry (dry-run default, --only mandatory, backs up + round-trip verifies)
```

**Customize before use:** these five scripts default to this template's
example label (`[DVI]`) and a public demo ATLAS instance. Set
`ATLAS_LABEL_PREFIX` (and `ATLAS_BASE_URL`/`BASE_URL`, if you run your own
instance) at the top of each one to your own lab's choice before relying on
them — see each script's own header comment.

## Pushing verified entries

`scripts/push_dvi_concept_sets.R` is one of two tools that write to ATLAS (see
also `update_dvi_concept_sets.R` below, for sets that already exist). It
reads `catalog.yaml`, and for each `status: verified` entry with its own
concept set that does **not** already have a tagged counterpart, creates a
label-prefixed concept set on the configured instance. Guards: dry-run by
default, concept-based de-duplication (won't recreate a set whose concepts
already live in an existing tagged set), building-block entries excluded,
and a hard refusal of any name not starting with the configured label.
Entries with structured `exclusion_concept_sets:` are deferred unless
`--with-exclusions` is passed.

```bash
# Prereqs: refresh the cache and the membership index first.
Rscript phenotype_library/scripts/check_dvi.R --refresh
Rscript phenotype_library/scripts/fetch_dvi_members.R

Rscript phenotype_library/scripts/push_dvi_concept_sets.R                # dry-run: show the plan
Rscript phenotype_library/scripts/push_dvi_concept_sets.R --commit       # create the CREATE rows
Rscript phenotype_library/scripts/push_dvi_concept_sets.R --commit --limit 1   # contract-test one first
Rscript phenotype_library/scripts/push_dvi_concept_sets.R --with-exclusions --only example_phenotype --commit
```

After a push, record each new ATLAS id back onto its catalog entry via
`external_alignment:` + `alignment_status: matches_dvi` (the `--commit` run
writes an `{entry_id -> dvi_id}` map to `/tmp/dvi_created.json` to drive this).

## Updating an existing tagged set after a catalog change

`scripts/push_dvi_concept_sets.R` only ever **creates**, and skips any name that
already exists — so editing a catalog entry that was already pushed left the
change with no route to ATLAS. `scripts/update_dvi_concept_sets.R` closes that
gap: it rewrites an existing tagged set's item list to match its catalog entry.

**It is deliberately stricter than the create path, because an update is
destructive.** `PUT /conceptset/{id}/items` *replaces* the item list, and ATLAS
keeps no history, so a wrong target silently overwrites a phenotype with no way
back. On top of every guard the create path has:

| Guard | Why |
|---|---|
| `--only <entry_id[,…]>` is **mandatory** | No bulk mode. You cannot "update everything that drifted" in one command. |
| Backs up the live definition before writing | Written every run, dry runs included, to `/tmp/dvi_backup_<id>_<stamp>.json`. The only recovery path. |
| Item-level diff with concept names | The operator approves a clinical change, not a row count. |
| Round-trip verification after writing | Re-fetches and compares to intent; reports a partial state loudly. |
| Refuses an empty desired item list | Would otherwise blank the set. |
| Refuses unless the **live** ATLAS name starts with your configured label | Checked against WebAPI, not the catalog, so a mistyped id can't slip through. |
| Refuses unless the entry is `status: verified` and carries a tagged external_alignment id | It never guesses which ATLAS set an entry means. |
| Names unchanged unless `--rename` | Renaming can break references held elsewhere. |

```bash
Rscript phenotype_library/scripts/update_dvi_concept_sets.R --only example_phenotype                       # dry-run + diff
Rscript phenotype_library/scripts/update_dvi_concept_sets.R --only example_phenotype,another_entry          # several targets
Rscript phenotype_library/scripts/update_dvi_concept_sets.R --only example_phenotype --commit               # apply
Rscript phenotype_library/scripts/update_dvi_concept_sets.R --only <id> --with-exclusions --commit      # include exclusions
Rscript phenotype_library/scripts/update_dvi_concept_sets.R --only <id> --rename --commit               # also fix the name
```

It is **idempotent** — a target already matching its catalog entry reports
`NO CHANGE` and is not written. After a commit, set `alignment_status:
matches_dvi` on the affected entries (the run writes an
`{entry_id -> dvi_id}` map to `/tmp/dvi_updated.json` to drive this).

⚠️ `--with-exclusions` mirrors the create path: exclusions are omitted unless
asked for. If the entry *has* `exclusion_concept_sets:` and the flag is not
passed, the script warns that the pushed definition will be **broader** than the
catalog describes.
