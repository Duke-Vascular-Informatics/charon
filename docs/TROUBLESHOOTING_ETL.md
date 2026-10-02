# Troubleshooting: Synthetic Data Generation and ETL

Use this when the Workflow 03-06 commands (part of Step 11) fail.

> **Scope:** these `workflow/01,03-06` scripts belong to `synthea-omop-template`
> and to `-synth` repos (which keep Steps 1-6 of that scaffold — see that
> template's README). A `strategus-study-template` analysis-core repo has no
> such scripts: its synthetic data comes from a sibling `-synth` repo via
> `synthetic_data/registry.yaml`'s view-overlay mechanism instead. If you're on
> that path and something here doesn't apply, that's expected.

## Validate Run Order

Run in order:

```bash
Rscript workflow/01_setup_synthea_etl_qc_env.R
Rscript workflow/03_generate_synthea_module_artifacts.R
bash workflow/04_generate_synthea_csv.sh
Rscript workflow/05_etl_csv_to_omop.R
Rscript workflow/06_quality_check_defined_phenotypes.R
```

On Windows, use:

```powershell
powershell -ExecutionPolicy Bypass -File workflow/04_generate_synthea_csv.ps1
```

## Common Failure Patterns

- Missing Synthea CSV output:
  - Re-run Step 4 generator script (`.sh` or `.ps1`)
  - Check file paths expected by ETL scripts

- ETL fails on table/schema permissions:
  - Verify `cdm_schema` and `results_schema` in `study_params.yaml`
  - Confirm SQL user has create/insert privileges on target schema

- QC script reports low/empty counts:
  - Re-check cohort concept IDs and SQL placeholders (`concept_id = 0`)
  - Re-run `Rscript scripts/check_setup.R`

## Logs and Escalation

If still blocked, collect support diagnostics:

```bash
Rscript scripts/create_support_bundle.R
```

Share the archive path reported by the script when requesting help.
