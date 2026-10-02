#!/usr/bin/env Rscript
# =============================================================================
# synthetic_data/scripts/generate_overlay_schema.R
#
# PURPOSE
# -------
# SAME-MACHINE ONLY. Replaces the manual, undocumented `CREATE VIEW` SQL that
# has, until now, been run by hand directly on the SQL Server instance to back
# the Strategus repos' OMOP_CDM_SCHEMA_OVERRIDE mechanism (e.g.
# pad_oler_aki_desc_cdm_test, pad_oler_ssi_plp_ssival_cdm_test). Builds a
# read-only schema of views: clinical tables pointing at a source schema on
# THIS SQL Server instance, plus vocabulary tables pointing at the shared
# omop_vocab — because Strategus/CohortGenerator has no separate vocab-schema
# parameter and needs both in one cdmDatabaseSchema.
#
# This is NOT a cross-machine sharing mechanism — it only works because the
# source schema is already populated on your own SQL Server instance. For
# sharing across machines, see synthetic_data/registry.yaml (regenerate from
# recipe) or export_clinical_tables.R / import_clinical_tables.R (download).
#
# USAGE
# -----
#   Rscript synthetic_data/scripts/generate_overlay_schema.R --source <schema> --target <schema> [--vocab-schema omop_vocab] [--registry-id <id>]
#
# Example:
#   Rscript synthetic_data/scripts/generate_overlay_schema.R \
#     --source omop_synth_pad_oler_ssi --target pad_oler_ssi_plp_ssival_cdm_test
#
# After running, update synthetic_data/local_schemas.yaml's `overlays:` list
# with the new overlay_schema/registry_id/used_by, and set
# OMOP_CDM_SCHEMA_OVERRIDE=<target> in the consuming repo's .env.
#
# AUTO-LOAD (--registry-id, optional)
# ------------------------------------
# If `--source` turns out to be empty or missing (e.g. a fresh clone that has
# the registry entry but never populated the physical schema), pass
# `--registry-id <id>` and this script will attempt to auto-load it by
# shelling out to import_clinical_tables.R, which downloads the dataset's
# published GitHub Release asset (synthetic_data/registry.yaml's `download:`
# block) into `--source` before building the overlay. Without --registry-id,
# a missing/empty source schema is a hard stop with a pointer to
# synthetic_data/README.md's three reuse tiers instead.
#
# REQUIREMENTS
# ------------
# Run inside the devcontainer. DatabaseConnector package. Connection env vars:
# OMOP_SERVER, OMOP_DATABASE, MSSQL_USER, MSSQL_SA_PASSWORD, MSSQL_PORT.
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
get_flag <- function(flag, args, default = NULL) {
  idx <- which(args == flag)
  if (length(idx) == 0L || idx == length(args)) return(default)
  args[idx + 1L]
}

# Resolve this script's own directory so the --registry-id auto-load below can
# find import_clinical_tables.R regardless of the caller's working directory
# (StrategusCodeToRun.R invokes this script via a relative path from a study
# repo's own directory, not from the workspace root).
all_args <- commandArgs(trailingOnly = FALSE)
script_arg <- sub("^--file=", "", all_args[grep("^--file=", all_args)])
script_dir <- dirname(normalizePath(script_arg))

source_schema <- get_flag("--source", args)
target_schema <- get_flag("--target", args)
vocab_schema  <- get_flag("--vocab-schema", args, default = Sys.getenv("OMOP_VOCAB_SCHEMA", "omop_vocab"))
registry_id   <- get_flag("--registry-id", args)

if (is.null(source_schema) || is.null(target_schema)) {
  cat(
    "Usage:\n",
    "  Rscript synthetic_data/scripts/generate_overlay_schema.R --source <schema> --target <schema> [--vocab-schema omop_vocab] [--registry-id <id>]\n"
  )
  quit(status = 1)
}

if (!requireNamespace("DatabaseConnector", quietly = TRUE)) {
  stop("Package 'DatabaseConnector' is required (HADES). Install with: renv::install('DatabaseConnector')")
}

connection_details <- DatabaseConnector::createConnectionDetails(
  dbms         = "sql server",
  server       = Sys.getenv("OMOP_SERVER", "localhost"),
  user         = Sys.getenv("MSSQL_USER", "SA"),
  password     = Sys.getenv("MSSQL_SA_PASSWORD"),
  port         = as.integer(Sys.getenv("MSSQL_PORT", "1433")),
  extraSettings = paste0(
    "database=", Sys.getenv("OMOP_DATABASE", "omop_synth"),
    ";trustServerCertificate=true"
  )
)

connection <- DatabaseConnector::connect(connection_details)
on.exit(DatabaseConnector::disconnect(connection), add = TRUE)

cat(sprintf("[generate_overlay_schema] Source: %s | Vocab: %s | Target: %s\n",
            source_schema, vocab_schema, target_schema))

clinical_tables <- DatabaseConnector::getTableNames(connection, databaseSchema = source_schema)

if (length(clinical_tables) == 0) {
  # source_schema may be given in two-part "database.schema" form (required
  # elsewhere so CohortGenerator doesn't misread a bare schema as the
  # database — see workspace memory design_decisions.md); import_clinical_tables.R's
  # --target-schema wants the bare schema name only, since its own connection
  # already targets OMOP_DATABASE.
  bare_source_schema <- sub("^[^.]+\\.", "", source_schema)

  if (is.null(registry_id)) {
    stop(sprintf(paste0(
      "[generate_overlay_schema] Source schema '%s' has no tables -- nothing to ",
      "overlay. Re-run with --registry-id <id> to auto-load it from the ",
      "registered dataset's GitHub Release, or see synthetic_data/README.md's ",
      "three reuse tiers (same-machine, cross-machine regenerate, cross-machine ",
      "download) to populate it yourself first.\n"
    ), source_schema))
  }

  cat(sprintf(
    "[generate_overlay_schema] Source schema '%s' has no tables -- attempting to auto-load registry dataset '%s' into it.\n",
    source_schema, registry_id
  ))

  # import_clinical_tables.R hard-requires cwd = workspace root (it reads
  # "synthetic_data/registry.yaml" as a relative path). script_dir is
  # .../synthetic_data/scripts, so its grandparent is the workspace root
  # regardless of the caller's own working directory.
  workspace_root <- dirname(dirname(script_dir))
  old_wd <- getwd()
  setwd(workspace_root)
  import_status <- system2(
    "Rscript",
    c("synthetic_data/scripts/import_clinical_tables.R",
      "--id", registry_id,
      "--target-schema", bare_source_schema)
  )
  setwd(old_wd)
  if (import_status != 0) {
    stop(sprintf(paste0(
      "[generate_overlay_schema] Auto-load via import_clinical_tables.R --id %s failed (see output above). ",
      "Common cause: the registry entry has no `download:` block published yet -- see ",
      "synthetic_data/README.md's three reuse tiers for other options.\n"
    ), registry_id))
  }

  clinical_tables <- DatabaseConnector::getTableNames(connection, databaseSchema = source_schema)
  if (length(clinical_tables) == 0) {
    stop(sprintf(
      "[generate_overlay_schema] Source schema '%s' is still empty after the auto-load attempt.\n",
      source_schema
    ))
  }
  cat(sprintf("[generate_overlay_schema] Auto-load succeeded: %d clinical tables now in '%s'.\n",
              length(clinical_tables), source_schema))
}

vocab_tables_raw <- DatabaseConnector::getTableNames(connection, databaseSchema = vocab_schema)

# vocab_schema is often a full CDM DDL build (via CreateCDMTables), so it can
# carry empty placeholder copies of clinical-domain tables (person,
# procedure_occurrence, condition_occurrence, etc.) alongside the real
# vocabulary tables. Since the view-creation loop below processes clinical
# tables first and vocab tables second with no dedup, any name collision let
# the (empty) vocab-schema copy silently clobber the real clinical view with
# no error — confirmed 2026-07-17 for 19 of 25 clinical tables. Clinical
# tables always take precedence: drop any vocab table name already provided
# by the clinical schema before building views.
vocab_tables <- setdiff(vocab_tables_raw, clinical_tables)
clobbered <- intersect(vocab_tables_raw, clinical_tables)
if (length(clobbered) > 0) {
  cat(sprintf("[generate_overlay_schema] Skipping %d vocab-schema table(s) that collide with clinical tables (clinical takes precedence): %s\n",
              length(clobbered), paste(sort(clobbered), collapse = ", ")))
}

cat(sprintf("[generate_overlay_schema] %d clinical tables, %d vocab tables found.\n",
            length(clinical_tables), length(vocab_tables)))

# CREATE SCHEMA operates within the connection's current database, so it takes
# a bare schema name -- unlike the view DDL below, which needs the full
# database.schema.table qualification. Passing target_schema through as-is
# here (e.g. "omop_synth.pad_bka_aka_prog_cdm_test") fails both the
# sys.schemas lookup (schema names never carry a database prefix) and the
# CREATE SCHEMA statement itself ("Incorrect syntax near '.'").
target_schema_bare <- sub("^[^.]+\\.", "", target_schema)
create_schema_sql <- sprintf("IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = '%s') EXEC('CREATE SCHEMA %s');",
                              target_schema_bare, target_schema_bare)
DatabaseConnector::executeSql(connection, create_schema_sql)

# DROP VIEW and CREATE VIEW, unlike OBJECT_ID() and a plain SELECT FROM
# reference, do not allow a database-name prefix at all -- even the CURRENT
# database's own name is rejected ("'DROP VIEW' does not allow specifying the
# database name as a prefix"). They take target_schema_bare (schema.table);
# OBJECT_ID() and the source/vocab SELECT FROM keep the full
# database.schema.table qualification, which those DO accept.
view_ddl <- character(0)
for (tbl in clinical_tables) {
  view_ddl <- c(view_ddl, sprintf(
    "IF OBJECT_ID('%s.%s', 'V') IS NOT NULL DROP VIEW %s.%s; CREATE VIEW %s.%s AS SELECT * FROM %s.%s;",
    target_schema, tbl, target_schema_bare, tbl, target_schema_bare, tbl, source_schema, tbl
  ))
}
for (tbl in vocab_tables) {
  view_ddl <- c(view_ddl, sprintf(
    "IF OBJECT_ID('%s.%s', 'V') IS NOT NULL DROP VIEW %s.%s; CREATE VIEW %s.%s AS SELECT * FROM %s.%s;",
    target_schema, tbl, target_schema_bare, tbl, target_schema_bare, tbl, vocab_schema, tbl
  ))
}

for (stmt in view_ddl) {
  DatabaseConnector::executeSql(connection, stmt)
}

cat(sprintf(
  "\n[generate_overlay_schema] Done. %d views created in %s (%d clinical + %d vocab).\n",
  length(view_ddl), target_schema, length(clinical_tables), length(vocab_tables)
))
cat("\nNext steps:\n")
cat(sprintf("  1. Record this in synthetic_data/local_schemas.yaml under `overlays:`.\n"))
cat(sprintf("  2. Set OMOP_CDM_SCHEMA_OVERRIDE=%s in the consuming repo's .env.\n", target_schema))

quit(status = 0)
