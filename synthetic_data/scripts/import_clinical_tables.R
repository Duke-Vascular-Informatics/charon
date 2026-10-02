#!/usr/bin/env Rscript
# =============================================================================
# synthetic_data/scripts/import_clinical_tables.R
#
# PURPOSE
# -------
# Download a published clinical-tables-only export (see export_clinical_tables.R
# and synthetic_data/registry.yaml's `download:` block) and bulk-load it into a
# fresh schema on YOUR OWN SQL Server instance. This is the fast path for a new
# clone (e.g. a student) to get a working synthetic dataset without running
# Synthea from scratch.
#
# The downloaded export never contains vocabulary table content (see
# export_clinical_tables.R's denylist and synthetic_data/README.md) — after
# importing, you still need your own Athena/UMLS vocab load (docs/SETUP.md
# Step 7) for condition/drug/procedure concept_ids to resolve to names.
#
# USAGE
# -----
#   Rscript synthetic_data/scripts/import_clinical_tables.R --id <registry_id> --target-schema <schema_name>
#   Rscript synthetic_data/scripts/import_clinical_tables.R --zip <path_to_zip> --target-schema <schema_name>
#
# Example:
#   Rscript synthetic_data/scripts/import_clinical_tables.R --id pad_oler_ssi_val --target-schema my_borrowed_pad_ssi
#
# REQUIREMENTS
# ------------
# Run inside the devcontainer. yaml, DatabaseConnector, CommonDataModel packages.
# gh CLI authenticated, if downloading via --id rather than a local --zip.
# Connection env vars: OMOP_SERVER, OMOP_DATABASE, MSSQL_USER, MSSQL_SA_PASSWORD,
# MSSQL_PORT (same as any study repo's config.R).
# =============================================================================

`%||%` <- function(x, y) if (is.null(x)) y else x

args <- commandArgs(trailingOnly = TRUE)
get_flag <- function(flag, args, default = NULL) {
  idx <- which(args == flag)
  if (length(idx) == 0L || idx == length(args)) return(default)
  args[idx + 1L]
}

dataset_id     <- get_flag("--id", args)
zip_arg        <- get_flag("--zip", args)
target_schema  <- get_flag("--target-schema", args)

if (is.null(target_schema) || (is.null(dataset_id) && is.null(zip_arg))) {
  cat(
    "Usage:\n",
    "  Rscript synthetic_data/scripts/import_clinical_tables.R --id <registry_id> --target-schema <schema_name>\n",
    "  Rscript synthetic_data/scripts/import_clinical_tables.R --zip <path_to_zip> --target-schema <schema_name>\n"
  )
  quit(status = 1)
}

# Two-part database.schema form required — this SQL Server misreads a BARE schema
# name as a database name (documented workspace gotcha). Qualify with OMOP_DATABASE
# unless the caller already passed a dotted --target-schema.
if (!grepl("\\.", target_schema)) {
  target_schema <- paste0(Sys.getenv("OMOP_DATABASE", "omop_synth"), ".", target_schema)
}

if (!requireNamespace("yaml", quietly = TRUE)) {
  stop("Package 'yaml' is required. Install with: renv::install('yaml')")
}

zip_path <- zip_arg
entry <- NULL

if (is.null(zip_path)) {
  registry_path <- if (file.exists("synthetic_data/registry.yaml")) "synthetic_data/registry.yaml" else stop("registry.yaml not found. Run from workspace root.")
  registry <- yaml::read_yaml(registry_path)
  # Match on the current id first, then fall back to `former_ids`. Dataset ids
  # can get renamed over time, and consumers hold the old id in committed code
  # — without this fallback, `former_id` could be recorded in the registry but
  # honored by nothing, so a rename would silently break this lookup path.
  # Resolving it here means a rename stays backward-compatible and pinned
  # consumers need no edit; the warning tells the caller to update at their
  # convenience.
  matched <- Filter(function(e) identical(e$id, dataset_id), registry$datasets)
  if (length(matched) == 0L) {
    matched <- Filter(function(e) dataset_id %in% unlist(e$former_ids %||% e$former_id %||% list()),
                      registry$datasets)
    if (length(matched) > 0L) {
      warning(sprintf(paste0(
        "[import_clinical_tables] '%s' is a FORMER id; resolved to '%s'. ",
        "Update your reference — former-id resolution is a compatibility shim."
      ), dataset_id, matched[[1L]]$id), call. = FALSE, immediate. = TRUE)
    }
  }
  if (length(matched) == 0L) stop(sprintf("[import_clinical_tables] No registry entry with id '%s'.", dataset_id))
  entry <- matched[[1L]]
  dl <- entry$download
  if (is.null(dl)) {
    stop(sprintf(paste0(
      "[import_clinical_tables] Registry entry '%s' has no `download:` block published yet. ",
      "Either ask the maintainer to publish one (see README §'Publishing a download export'), ",
      "or regenerate from the recipe instead (README §2: synthea_module_path + generation_params)."
    ), dataset_id))
  }

  release_parts <- strsplit(dl$github_release, "@", fixed = TRUE)[[1]]
  repo <- release_parts[1]
  tag  <- release_parts[2]

  download_dir <- file.path("synthetic_data", "downloads", dataset_id)
  dir.create(download_dir, recursive = TRUE, showWarnings = FALSE)
  zip_path <- file.path(download_dir, dl$asset)

  cat(sprintf("[import_clinical_tables] Downloading %s (tag %s) from %s ...\n", dl$asset, tag, repo))
  status <- system2("gh", c("release", "download", tag, "--repo", repo,
                             "--pattern", dl$asset, "--dir", download_dir, "--clobber"))
  if (status != 0L || !file.exists(zip_path)) {
    stop("[import_clinical_tables] `gh release download` failed. Confirm `gh auth status` and that the release/asset exist.")
  }
}

if (!file.exists(zip_path)) stop(sprintf("[import_clinical_tables] Zip not found: %s", zip_path))

extract_dir <- file.path(dirname(zip_path), "extracted")
dir.create(extract_dir, recursive = TRUE, showWarnings = FALSE)
unzip(zip_path, exdir = extract_dir, overwrite = TRUE)
csv_files <- list.files(extract_dir, pattern = "\\.csv$", full.names = TRUE)
if (length(csv_files) == 0L) stop("[import_clinical_tables] No CSV files found in the export zip.")

# Safety check mirrors export_clinical_tables.R's denylist — refuse to import
# anything that looks like a vocabulary table, even from a trusted export.
VOCAB_TABLE_DENYLIST <- c(
  "concept", "concept_relationship", "concept_ancestor", "concept_synonym",
  "vocabulary", "drug_strength", "domain", "concept_class", "relationship",
  "source_to_concept_map"
)
table_names <- tolower(tools::file_path_sans_ext(basename(csv_files)))
bad <- intersect(table_names, VOCAB_TABLE_DENYLIST)
if (length(bad) > 0L) {
  stop(
    "[import_clinical_tables] Refusing to import: this zip contains files matching ",
    "vocabulary table names (", paste(bad, collapse = ", "), "). This should never ",
    "happen from export_clinical_tables.R's own output — do not proceed without ",
    "investigating where this file came from."
  )
}

cat(sprintf("[import_clinical_tables] Found %d clinical table CSVs to load into schema '%s'.\n",
            length(csv_files), target_schema))

if (!requireNamespace("DatabaseConnector", quietly = TRUE)) {
  stop("Package 'DatabaseConnector' is required (HADES). Install with: renv::install('DatabaseConnector')")
}
if (!requireNamespace("CommonDataModel", quietly = TRUE)) {
  stop(
    "Package 'CommonDataModel' is required to create empty OMOP CDM v5.4 clinical ",
    "tables (HADES DDL generator). Install with: renv::install('OHDSI/CommonDataModel')"
  )
}

connection_details <- DatabaseConnector::createConnectionDetails(
  dbms         = "sql server",
  server       = Sys.getenv("OMOP_SERVER", "localhost"),
  user         = Sys.getenv("MSSQL_USER", "SA"),
  password     = Sys.getenv("MSSQL_SA_PASSWORD"),
  port         = as.integer(Sys.getenv("MSSQL_PORT", "1433")),
  # database in extraSettings + trustServerCertificate=true for mssql_dev's
  # self-signed cert (modern mssql-jdbc defaults to encrypt=true). Matches every
  # working repo's connection pattern; the prior "host/database" server string failed.
  extraSettings = paste0("database=", Sys.getenv("OMOP_DATABASE", "omop_synth"),
                         ";trustServerCertificate=true")
)

connection <- DatabaseConnector::connect(connection_details)
on.exit(DatabaseConnector::disconnect(connection), add = TRUE)

# CommonDataModel::executeDdl assumes the schema already exists -- it doesn't
# create one. target_schema here is two-part "database.schema"; CREATE SCHEMA
# takes the bare name only (it runs against the connection's default database).
bare_target_schema <- sub("^[^.]+\\.", "", target_schema)
DatabaseConnector::executeSql(connection, sprintf(
  "IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = '%s') EXEC('CREATE SCHEMA %s');",
  bare_target_schema, bare_target_schema
))

cat(sprintf("[import_clinical_tables] Creating empty CDM v5.4 clinical tables in schema '%s' (DDL via CommonDataModel) ...\n", target_schema))
CommonDataModel::executeDdl(
  connectionDetails   = connection_details,
  cdmVersion          = "5.4",
  cdmDatabaseSchema   = target_schema,
  executeDdl          = TRUE,
  executePrimaryKey   = FALSE,   # keep loads fast; add constraints afterward if needed
  executeForeignKey   = FALSE
)

# executeDdl() creates the FULL CDM v5.4 DDL (~39 tables), not just the ones
# we're about to load -- including empty vocabulary-domain tables (concept,
# vocabulary, concept_relationship, ...). If left in place, downstream tools
# that build a clinical+vocab view-overlay (generate_overlay_schema.R) treat
# a same-named table in the clinical schema as taking precedence over the
# real omop_vocab, so these empty placeholders would silently shadow real
# vocabulary content with zero rows. Drop everything executeDdl created that
# we don't actually have data for.
created_tables <- DatabaseConnector::getTableNames(connection, databaseSchema = target_schema)
unloaded_tables <- setdiff(tolower(created_tables), tolower(table_names))
for (tbl in unloaded_tables) {
  DatabaseConnector::executeSql(connection, sprintf("DROP TABLE IF EXISTS %s.%s;", bare_target_schema, tbl))
}
if (length(unloaded_tables) > 0) {
  cat(sprintf("[import_clinical_tables] Dropped %d unloaded placeholder table(s) from the DDL build: %s\n",
              length(unloaded_tables), paste(sort(unloaded_tables), collapse = ", ")))
}

for (csv in csv_files) {
  tbl <- tools::file_path_sans_ext(basename(csv))
  cat(sprintf("[import_clinical_tables] Loading %s ...\n", tbl))
  df <- read.csv(csv, stringsAsFactors = FALSE)
  DatabaseConnector::insertTable(
    connection      = connection,
    databaseSchema  = target_schema,
    tableName       = tbl,
    data            = df,
    dropTableIfExists = FALSE,
    createTable       = FALSE,
    progressBar       = TRUE
  )
}

cat(sprintf("\n[import_clinical_tables] Done. '%s' now has %d clinical tables loaded.\n", target_schema, length(csv_files)))
cat("\nREMINDER: this schema has NO vocabulary tables. Before querying condition/drug/\n")
cat("procedure names, either (a) point this schema's queries at your own already-loaded\n")
cat("omop_vocab (per docs/SETUP.md Step 7), or (b) run generate_overlay_schema.R to\n")
cat("build a combined view schema for tools (like Strategus) that need clinical + vocab\n")
cat("tables in one schema.\n")

quit(status = 0)
