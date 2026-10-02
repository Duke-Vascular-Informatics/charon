#!/usr/bin/env Rscript
# =============================================================================
# synthetic_data/scripts/export_clinical_tables.R
#
# PURPOSE
# -------
# Export ONLY the clinical fact tables of an already-populated synthetic OMOP
# CDM schema to CSV, zip them, and print the commands to publish the zip as a
# GitHub Release asset — so another machine can bulk-load it later via
# import_clinical_tables.R instead of re-running Synthea from scratch.
#
# HARD SAFETY RULE
# -----------------
# Vocabulary tables are NEVER exported, under any circumstance. This is
# enforced in code (VOCAB_TABLE_DENYLIST + an assertion that it never
# intersects CLINICAL_TABLE_ALLOWLIST), not just documented. See
# synthetic_data/README.md for why (omop_vocab is Athena/UMLS-licensed and
# not for redistribution — docs/SETUP.md Step 7).
#
# This script does NOT create the GitHub Release itself — publishing public
# content is a call you make deliberately, each time. It prints the exact
# `gh release create` / `gh release upload` commands for you to review and run.
#
# USAGE
# -----
#   Rscript synthetic_data/scripts/export_clinical_tables.R --id <registry_id> [--dry-run]
#   Rscript synthetic_data/scripts/export_clinical_tables.R --schema <schema_name> --id <registry_id> [--dry-run]
#
# Examples:
#   Rscript synthetic_data/scripts/export_clinical_tables.R --id pad_oler_ssi_val --dry-run
#   Rscript synthetic_data/scripts/export_clinical_tables.R --id pad_oler_ssi_val
#
# REQUIREMENTS
# ------------
# Run inside the devcontainer (never against the host). yaml + DatabaseConnector
# packages. Connection env vars: OMOP_SERVER, OMOP_DATABASE, MSSQL_USER,
# MSSQL_SA_PASSWORD, MSSQL_PORT (same as any study repo's config.R).
# =============================================================================

`%||%` <- function(x, y) if (is.null(x)) y else x

# ---------------------------------------------------------------------------
# Table lists — the actual safety mechanism, not just a comment
# ---------------------------------------------------------------------------
CLINICAL_TABLE_ALLOWLIST <- c(
  "person", "observation_period", "visit_occurrence", "visit_detail",
  "condition_occurrence", "drug_exposure", "procedure_occurrence",
  "measurement", "observation", "death",
  "condition_era", "drug_era", "dose_era"
)

VOCAB_TABLE_DENYLIST <- c(
  "concept", "concept_relationship", "concept_ancestor", "concept_synonym",
  "vocabulary", "drug_strength", "domain", "concept_class", "relationship",
  "source_to_concept_map"
)

overlap <- intersect(CLINICAL_TABLE_ALLOWLIST, VOCAB_TABLE_DENYLIST)
if (length(overlap) > 0L) {
  stop(
    "[export_clinical_tables] Refusing to run: CLINICAL_TABLE_ALLOWLIST and ",
    "VOCAB_TABLE_DENYLIST overlap on: ", paste(overlap, collapse = ", "),
    " — this would risk exporting vocabulary content. Fix the lists in this ",
    "script before re-running."
  )
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)

get_flag <- function(flag, args, default = NULL) {
  idx <- which(args == flag)
  if (length(idx) == 0L || idx == length(args)) return(default)
  args[idx + 1L]
}

dataset_id    <- get_flag("--id", args)
schema_arg    <- get_flag("--schema", args)
output_dir    <- get_flag("--output-dir", args, default = file.path("synthetic_data", "exports"))
dry_run       <- "--dry-run" %in% args

if (is.null(dataset_id)) {
  cat(
    "Usage:\n",
    "  Rscript synthetic_data/scripts/export_clinical_tables.R --id <registry_id> [--dry-run]\n",
    "  Rscript synthetic_data/scripts/export_clinical_tables.R --schema <schema_name> --id <registry_id> [--dry-run]\n"
  )
  quit(status = 1)
}

if (!requireNamespace("yaml", quietly = TRUE)) {
  stop("Package 'yaml' is required. Install with: renv::install('yaml')")
}

registry_path <- if (file.exists("synthetic_data/registry.yaml")) {
  "synthetic_data/registry.yaml"
} else {
  stop("registry.yaml not found. Run this script from the workspace root.")
}
registry <- yaml::read_yaml(registry_path)
entry <- Filter(function(e) identical(e$id, dataset_id), registry$datasets)
if (length(entry) == 0L) {
  stop(sprintf("[export_clinical_tables] No registry entry with id '%s'. Run lookup_dataset.R --all to see valid ids.", dataset_id))
}
entry <- entry[[1L]]

# Resolve source schema: explicit --schema wins, else look up local_schemas.yaml
schema_name <- schema_arg
if (is.null(schema_name)) {
  local_path <- "synthetic_data/local_schemas.yaml"
  if (!file.exists(local_path)) {
    stop(
      "[export_clinical_tables] No --schema given and synthetic_data/local_schemas.yaml ",
      "doesn't exist. Either pass --schema <name> explicitly, or record this dataset's ",
      "populated schema in local_schemas.yaml first (see README)."
    )
  }
  local_cache <- yaml::read_yaml(local_path)
  populated <- Filter(function(p) identical(p$registry_id, dataset_id), local_cache$populated %||% list())
  if (length(populated) == 0L) {
    stop(sprintf(
      "[export_clinical_tables] No local_schemas.yaml entry for '%s'. Pass --schema <name> explicitly.",
      dataset_id
    ))
  }
  schema_name <- populated[[1L]]$cdm_schema
}

# Two-part database.schema form required — this SQL Server misreads a BARE schema
# name as a database name in getTableNames (documented workspace gotcha; a bare
# schema errors "Database '<schema>' does not exist"). Qualify with OMOP_DATABASE
# unless the caller already passed a dotted --schema.
if (!grepl("\\.", schema_name)) {
  schema_name <- paste0(Sys.getenv("OMOP_DATABASE", "omop_synth"), ".", schema_name)
}

cat(sprintf("[export_clinical_tables] Dataset   : %s\n", dataset_id))
cat(sprintf("[export_clinical_tables] Schema    : %s\n", schema_name))
cat(sprintf("[export_clinical_tables] Output dir: %s\n", output_dir))
cat(sprintf("[export_clinical_tables] Denylist  : %s (never exported)\n", paste(VOCAB_TABLE_DENYLIST, collapse = ", ")))
cat("\n")

if (dry_run) {
  cat("[export_clinical_tables] --dry-run: no database connection will be made.\n")
  cat("Tables that WOULD be exported (allowlist only; existence not yet verified against the schema):\n")
  for (t in CLINICAL_TABLE_ALLOWLIST) cat(sprintf("  - %s\n", t))
  cat("\nRe-run without --dry-run (in the devcontainer) to actually connect and export.\n")
  quit(status = 0)
}

# ---------------------------------------------------------------------------
# Connect and export (devcontainer only — requires DatabaseConnector + a
# provisioned JDBC driver, same connection env vars any study repo's
# config.R / R/connection.R already use)
# ---------------------------------------------------------------------------
if (!requireNamespace("DatabaseConnector", quietly = TRUE)) {
  stop("Package 'DatabaseConnector' is required (HADES). Install with: renv::install('DatabaseConnector')")
}

connection_details <- DatabaseConnector::createConnectionDetails(
  dbms         = "sql server",
  server       = Sys.getenv("OMOP_SERVER", "localhost"),
  user         = Sys.getenv("MSSQL_USER", "SA"),
  password     = Sys.getenv("MSSQL_SA_PASSWORD"),
  port         = as.integer(Sys.getenv("MSSQL_PORT", "1433")),
  # database goes in extraSettings (not a "host/database" server string) and
  # trustServerCertificate=true is required for mssql_dev's self-signed cert —
  # the modern mssql-jdbc driver defaults to encrypt=true and otherwise rejects
  # the handshake. Matches every working repo's connection pattern in this workspace.
  extraSettings = paste0("database=", Sys.getenv("OMOP_DATABASE", "omop_synth"),
                         ";trustServerCertificate=true")
)

connection <- DatabaseConnector::connect(connection_details)
on.exit(DatabaseConnector::disconnect(connection), add = TRUE)

existing_tables <- tolower(DatabaseConnector::getTableNames(connection, databaseSchema = schema_name))
tables_to_export <- intersect(CLINICAL_TABLE_ALLOWLIST, existing_tables)
skipped <- setdiff(CLINICAL_TABLE_ALLOWLIST, existing_tables)
if (length(skipped) > 0L) {
  cat(sprintf("[export_clinical_tables] Not present in schema, skipping: %s\n", paste(skipped, collapse = ", ")))
}
if (length(tables_to_export) == 0L) {
  stop("[export_clinical_tables] None of the allowlisted clinical tables exist in this schema. Nothing to export.")
}

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
staging_dir <- file.path(output_dir, dataset_id)
dir.create(staging_dir, recursive = TRUE, showWarnings = FALSE)

row_counts <- list()
for (tbl in tables_to_export) {
  cat(sprintf("[export_clinical_tables] Exporting %s.%s ...\n", schema_name, tbl))
  sql <- SqlRender::translate(
    SqlRender::render("SELECT * FROM @schema.@table;", schema = schema_name, table = tbl),
    targetDialect = "sql server"
  )
  df <- DatabaseConnector::querySql(connection, sql)
  csv_path <- file.path(staging_dir, paste0(tbl, ".csv"))
  write.csv(df, csv_path, row.names = FALSE)
  row_counts[[tbl]] <- nrow(df)
}

zip_path <- file.path(output_dir, paste0(dataset_id, "_clinical_tables.zip"))
old_wd <- getwd()
setwd(staging_dir)
zip(file.path(old_wd, zip_path), list.files("."))
setwd(old_wd)

cat("\n[export_clinical_tables] Done. Row counts:\n")
for (tbl in names(row_counts)) cat(sprintf("  %-25s %s\n", tbl, format(row_counts[[tbl]], big.mark = ",")))

cat(sprintf("\n[export_clinical_tables] Zip written to: %s\n", zip_path))
cat("\nTo publish (you run this — not automated):\n")
release_tag <- paste0("synth-data-", dataset_id, "-v1")
cat(sprintf("  gh release create %s %s --repo <owner>/%s \\\n", release_tag, zip_path, entry$source_repo %||% "<repo>"))
cat(sprintf("    --title \"%s synthetic clinical tables\" \\\n", dataset_id))
cat("    --notes \"Clinical fact tables only — no vocabulary content. See synthetic_data/README.md.\"\n")

cat("\nThen add this to the entry's `download:` block in synthetic_data/registry.yaml:\n")
cat(sprintf("  download:\n"))
cat(sprintf("    github_release: \"<owner>/%s@%s\"\n", entry$source_repo %||% "<repo>", release_tag))
cat(sprintf("    asset: \"%s\"\n", basename(zip_path)))
cat(sprintf("    tables_included: [%s]\n", paste(tables_to_export, collapse = ", ")))
cat("    vocabulary_tables_excluded: true\n")
cat(sprintf("    published_date: <today's date>\n"))

quit(status = 0)
