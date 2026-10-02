#!/usr/bin/env Rscript
# =============================================================================
# infrastructure/scripts/setup_omop_vocab_schema.R
#
# One-time setup: load the OMOP vocabulary into a dedicated shared schema
# (default: "omop_vocab") so that all subsequent ETL runs can reference it
# via SQL Server synonyms instead of reloading 130M rows from CSV each time.
#
# When to run:
#   - First time setting up this project on a new SQL Server instance.
#   - After upgrading the OMOP vocabulary to a new release.
#   - You should NOT need to run this again between synthetic dataset runs.
#
# What it does:
#   1. Creates the shared vocabulary schema if it does not exist.
#   2. Creates all OMOP CDM v5.4 vocabulary tables in that schema.
#   3. Sets the database to SIMPLE recovery and pre-grows the transaction log
#      (CONCEPT_ANCESTOR alone is 75M rows and needs ~25 GB of log headroom).
#   4. Loads all vocabulary tables from CSV using ETLSyntheaBuilder::LoadVocabFromCsv.
#   5. Sets the database permanently to SIMPLE recovery (appropriate for a
#      synthetic/dev database with no point-in-time restore requirement).
#
# Usage:
#   $env:OHDSI_VOCAB_CSV_DIR = "C:\path\to\Vocabulary_YYYYMMDD"
#   Rscript infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template
#
# Optional arguments:
#   --study-dir <path>   Study repository path relative to workspace root.
#                        Defaults to "synthea-omop-template".
#
# After this script completes, set in workflow/05_etl_csv_to_omop.R:
#   use_shared_vocab_schema <- TRUE
# Every subsequent ETL run will skip the vocabulary load entirely and wire
# synonyms in ~1 second instead of waiting 30-60 minutes for CSV load.
# =============================================================================

# -----------------------------------------------------------------------------
# Settings
# -----------------------------------------------------------------------------
vocab_schema      <- "omop_vocab"          # Shared schema to load vocab into
cdm_version       <- "5.4"
vocab_delimiter   <- "\t"                  # OHDSI vocabulary CSVs are tab-delimited
target_log_mb     <- 25600L               # 25 GB log headroom for bulk vocab load
# Default to the dev-container mount (/omop_vocab). The OHDSI_VOCAB_CSV_DIR
# environment variable overrides this for host-side or alternate locations.
vocab_file_loc    <- Sys.getenv("OHDSI_VOCAB_CSV_DIR", unset = "/omop_vocab")

# SQL Server max-memory cap (MB) used DURING the vocabulary load. The load is
# bound by R-side memory (ETLSyntheaBuilder::LoadVocabFromCsv reads each CSV
# fully into R, and DatabaseConnector duplicates it into JDBC batch buffers —
# the 6.3M-row CONCEPT table alone peaks at ~12 GB). If SQL Server is left
# uncapped it grows its buffer pool until the R loader is OOM-killed mid-insert
# (silent exit, no error). Capping SQL low during the load guarantees headroom
# for R. It is raised to a balanced value for analysis once the load finishes.
load_sql_cap_mb   <- 2048L
# Below this much total RAM the load is at high risk of OOM; warn the user.
min_recommended_ram_mb <- 12000L

# -----------------------------------------------------------------------------
# Bootstrap
# -----------------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
study_dir <- "synthea-omop-template"
if (length(args) > 0L) {
  i <- 1L
  while (i <= length(args)) {
    arg <- args[[i]]
    if (arg == "--study-dir") {
      if (i == length(args)) {
        stop("--study-dir requires a path value.", call. = FALSE)
      }
      study_dir <- args[[i + 1L]]
      i <- i + 2L
    } else {
      stop("Unknown argument: ", arg, call. = FALSE)
    }
  }
}

workspace_root <- getwd()
study_root <- normalizePath(file.path(workspace_root, study_dir), winslash = "/", mustWork = FALSE)

if (!dir.exists(study_root)) {
  stop(
    "Study directory not found: ", study_root, "\n",
    "Run from workspace root and provide --study-dir <study-folder>.",
    call. = FALSE
  )
}

if (!file.exists(file.path(study_root, "renv/activate.R"))) {
  stop(
    "The target study folder does not look like a study repository: ", study_root, "\n",
    "Missing: renv/activate.R",
    call. = FALSE
  )
}

setwd(study_root)

source("renv/activate.R")
if (requireNamespace("renv", quietly = TRUE)) renv::load(project = getwd())

source("config.R")
source("R/drivers.R")
source("R/connection.R")
source("R/db_maintenance.R")

cfg <- get_validation_config()

# Apply Java / JDBC setup from config.
if (!is.null(cfg$java_home) && nzchar(cfg$java_home) && dir.exists(cfg$java_home)) {
  java_bin <- file.path(cfg$java_home, "bin")
  Sys.setenv(JAVA_HOME = cfg$java_home)
  Sys.setenv(PATH = paste(
    normalizePath(java_bin, winslash = "/", mustWork = FALSE),
    Sys.getenv("PATH"), sep = .Platform$path.sep
  ))
  options(java.parameters = paste0(
    "-Djava.home=", normalizePath(cfg$java_home, winslash = "/", mustWork = FALSE)
  ))
  if (!is.null(cfg$jdbc_auth_dir) && nzchar(cfg$jdbc_auth_dir) && dir.exists(cfg$jdbc_auth_dir)) {
    jdbc_auth_native <- normalizePath(cfg$jdbc_auth_dir, winslash = "/", mustWork = FALSE)
    Sys.setenv(JAVA_TOOL_OPTIONS = paste0("-Djava.library.path=", jdbc_auth_native))
    Sys.setenv(PATH = paste(jdbc_auth_native, Sys.getenv("PATH"), sep = .Platform$path.sep))
  }
}

for (pkg in c("DatabaseConnector", "SqlRender", "ETLSyntheaBuilder")) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stop("Required package not found: ", pkg,
         ". Run workflow/01_setup_synthea_etl_qc_env.R first.", call. = FALSE)
  }
}

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------
cat("\n=== OMOP Shared Vocabulary Schema Setup ===\n")
cat("Vocabulary schema  :", vocab_schema, "\n")
cat("CDM version        :", cdm_version, "\n")
cat("Vocabulary CSV dir :", vocab_file_loc, "\n")
cat("Database           :", cfg$database, "on", cfg$server, "\n\n")

if (!dir.exists(vocab_file_loc)) {
  stop(
    "Vocabulary CSV directory not found: ", vocab_file_loc, "\n",
    "Set the OHDSI_VOCAB_CSV_DIR environment variable to the correct path.",
    call. = FALSE
  )
}

required_vocab_files <- c(
  "CONCEPT.csv", "CONCEPT_ANCESTOR.csv", "CONCEPT_CLASS.csv",
  "CONCEPT_RELATIONSHIP.csv", "CONCEPT_SYNONYM.csv", "DOMAIN.csv",
  "DRUG_STRENGTH.csv", "RELATIONSHIP.csv", "VOCABULARY.csv"
)
missing_files <- required_vocab_files[
  !file.exists(file.path(vocab_file_loc, required_vocab_files))
]
if (length(missing_files) > 0) {
  stop(
    "Missing required vocabulary CSV files in ", vocab_file_loc, ":\n",
    paste(" -", missing_files, collapse = "\n"),
    call. = FALSE
  )
}

ensure_jdbc_bundle(cfg)

connection_details <- build_connection_details(cfg)

# A separate connection to the server's `master` database. Needed to (a) create
# the target database if it does not yet exist, and (b) run instance-level
# sp_configure memory settings — neither can rely on the target DB existing.
master_connection_details <- DatabaseConnector::createConnectionDetails(
  dbms         = cfg$dbms,
  server       = cfg$server,
  user         = cfg$user,
  password     = cfg$password,
  pathToDriver = cfg$jdbc_runtime_dir,
  extraSettings = paste0(
    "database=master",
    ";trustServerCertificate=true",
    ";portNumber=", cfg$sql_server_port
  )
)

# -----------------------------------------------------------------------------
# Preflight: RAM advisory, database auto-create, and SQL Server memory cap
#
# These three steps remove the most common first-run failure modes:
#   1. Low host RAM -> R loader OOM-killed mid-load.
#   2. Target database does not exist yet -> "Cannot open database" login error.
#   3. Uncapped SQL Server buffer pool -> starves the R loader -> OOM.
# -----------------------------------------------------------------------------
conn_master <- DatabaseConnector::connect(master_connection_details)
on.exit(try(DatabaseConnector::disconnect(conn_master), silent = TRUE), add = TRUE)

# (1) RAM advisory — warn loudly but do not block; the memory cap below gives
# even an 8 GB machine a fighting chance, while 16 GB is the safe target.
total_ram_mb <- tryCatch({
  r <- DatabaseConnector::querySql(
    conn_master,
    "SELECT total_physical_memory_kb FROM sys.dm_os_sys_memory;"
  )
  as.numeric(r[[1]][[1]]) / 1024
}, error = function(e) NA_real_)
if (!is.na(total_ram_mb)) {
  cat(sprintf("[INFO] Detected ~%.1f GB total RAM.\n", total_ram_mb / 1024))
  if (total_ram_mb < min_recommended_ram_mb) {
    cat("[WARN] =====================================================================\n")
    cat(sprintf("[WARN] Only ~%.1f GB RAM detected. The vocabulary load reads multi-GB\n",
                total_ram_mb / 1024))
    cat("[WARN] CSV files fully into memory and can be OOM-killed below ~12 GB.\n")
    cat("[WARN] Recommended: raise Docker Desktop memory to 16 GB\n")
    cat("[WARN]   (Settings -> Resources -> Memory) and restart, then re-run.\n")
    cat("[WARN] Proceeding with a low SQL Server memory cap to maximise headroom.\n")
    cat("[WARN] =====================================================================\n")
  }
}

# (2) Auto-create the target database if it does not exist. This is idempotent
# and replaces the manual "CREATE DATABASE omop_synth" step from the docs.
DatabaseConnector::executeSql(
  conn_master,
  paste0(
    "IF DB_ID('", gsub("'", "''", cfg$database), "') IS NULL ",
    "CREATE DATABASE [", cfg$database, "];"
  ),
  progressBar = FALSE, reportOverallTime = FALSE
)
cat("[INFO] ✓ Target database '", cfg$database, "' present (created if missing)\n", sep = "")
DatabaseConnector::disconnect(conn_master)
# NOTE: the SQL Server memory cap is applied AFTER the "already populated" skip
# check below, so that re-runs (which exit early) never leave SQL Server
# throttled. See "Cap SQL Server memory for the load" further down.

# -----------------------------------------------------------------------------
# Check if vocab schema already populated — skip if so
# -----------------------------------------------------------------------------
conn_check <- DatabaseConnector::connect(connection_details)
on.exit(DatabaseConnector::disconnect(conn_check), add = TRUE)

schema_exists_sql <- paste0(
  "SELECT COUNT(*) AS n FROM sys.schemas WHERE name = '",
  gsub("'", "''", vocab_schema), "';"
)
schema_row <- DatabaseConnector::querySql(conn_check, schema_exists_sql)
colnames(schema_row) <- tolower(colnames(schema_row))
schema_exists <- as.integer(schema_row$n[[1]]) > 0L

if (schema_exists) {
  concept_check_sql <- paste0(
    "SELECT CASE WHEN EXISTS (SELECT 1 FROM [", vocab_schema, "].[concept]) ",
    "THEN 1 ELSE 0 END AS has_rows;"
  )
  concept_row <- tryCatch(
    { r <- DatabaseConnector::querySql(conn_check, concept_check_sql)
      colnames(r) <- tolower(colnames(r)); r },
    error = function(e) data.frame(has_rows = 0L)
  )
  if (as.integer(concept_row$has_rows[[1]]) > 0L) {
    cat("[INFO] Vocabulary schema '", vocab_schema,
        "' already exists and is populated. Nothing to do.\n", sep = "")
    cat("[INFO] To reload the vocabulary, drop the schema first:\n")
    cat("       DROP SCHEMA [", vocab_schema, "] (after dropping all tables in it)\n\n", sep = "")
    quit(save = "no", status = 0)
  }
}

DatabaseConnector::disconnect(conn_check)

# -----------------------------------------------------------------------------
# Cap SQL Server memory for the load (restored to a balanced value at the end).
#
# Applied only now — past the "already populated" early-exit above — so re-runs
# never leave SQL Server throttled. The load is R-memory-bound; capping the
# SQL Server buffer pool low guarantees headroom for the R loader's CSV reads
# and prevents a silent OOM kill mid-insert.
# -----------------------------------------------------------------------------
conn_mem_cap <- DatabaseConnector::connect(master_connection_details)
DatabaseConnector::executeSql(
  conn_mem_cap,
  paste0("EXEC sp_configure 'show advanced options', 1; RECONFIGURE; ",
         "EXEC sp_configure 'max server memory (MB)', ", load_sql_cap_mb, "; RECONFIGURE;"),
  progressBar = FALSE, reportOverallTime = FALSE
)
DatabaseConnector::disconnect(conn_mem_cap)
cat(sprintf("[INFO] ✓ SQL Server memory capped at %d MB for the load (headroom for the R loader)\n",
            load_sql_cap_mb))

# -----------------------------------------------------------------------------
# Step 1: Transaction log preparation
# -----------------------------------------------------------------------------
prepare_txlog_for_bulk_etl(cfg, target_min_mb = target_log_mb)

# -----------------------------------------------------------------------------
# Step 2: Create vocabulary schema and CDM vocab tables
# -----------------------------------------------------------------------------
cat("[INFO] Creating vocabulary schema '", vocab_schema, "' ...\n", sep = "")

conn_setup <- DatabaseConnector::connect(connection_details)
on.exit(DatabaseConnector::disconnect(conn_setup), add = TRUE)

DatabaseConnector::executeSql(
  conn_setup,
  paste0(
    "IF SCHEMA_ID('", gsub("'", "''", vocab_schema), "') IS NULL ",
    "EXEC('CREATE SCHEMA [", vocab_schema, "]');"
  )
)
cat("[INFO] \u2713 Schema created (or already exists)\n")
DatabaseConnector::disconnect(conn_setup)

# Use ETLSyntheaBuilder to create CDM tables in the vocab schema, then
# we only use the vocabulary table definitions.
cat("[INFO] Creating CDM vocabulary table definitions in '", vocab_schema, "' ...\n", sep = "")
ETLSyntheaBuilder::CreateCDMTables(
  connectionDetails = connection_details,
  cdmSchema         = vocab_schema,
  cdmVersion        = cdm_version
)
cat("[INFO] \u2713 CDM tables created\n")

# -----------------------------------------------------------------------------
# Step 3: Load vocabulary from CSV
# -----------------------------------------------------------------------------
cat("[INFO] Loading OMOP vocabulary from CSV (this will take 30-60 minutes) ...\n")
cat("[INFO] CONCEPT_ANCESTOR alone is 75M rows — please be patient.\n\n")

ETLSyntheaBuilder::LoadVocabFromCsv(
  connectionDetails = connection_details,
  cdmSchema         = vocab_schema,
  vocabFileLoc      = vocab_file_loc,
  delimiter         = vocab_delimiter
)

cat("\n[INFO] \u2713 Vocabulary loaded successfully into '", vocab_schema, "'\n", sep = "")

# -----------------------------------------------------------------------------
# Step 3b: Post-load NULL corrections
#
# data.table/DatabaseConnector converts empty CSV fields to '' rather than SQL
# NULL.  Several OMOP vocab columns are nullable and the ETLSyntheaBuilder
# source-to-standard mapping SQL relies on IS NULL checks.  Restore proper
# NULLs here so that every downstream ETL run maps correctly without manual
# intervention.
# -----------------------------------------------------------------------------
cat("[INFO] Applying post-load NULL corrections ...\n")
conn_null_fix <- DatabaseConnector::connect(connection_details)
on.exit(DatabaseConnector::disconnect(conn_null_fix), add = TRUE)

null_fix_stmts <- c(
  paste0("UPDATE [", vocab_schema, "].[concept] SET invalid_reason = NULL WHERE invalid_reason = ''"),
  paste0("UPDATE [", vocab_schema, "].[concept] SET standard_concept = NULL WHERE standard_concept = ''"),
  paste0("UPDATE [", vocab_schema, "].[concept_relationship] SET invalid_reason = NULL WHERE invalid_reason = ''"),
  paste0("UPDATE [", vocab_schema, "].[drug_strength] SET invalid_reason = NULL WHERE invalid_reason = ''"),
  paste0("UPDATE [", vocab_schema, "].[relationship] SET invalid_reason = NULL WHERE invalid_reason = ''")
)
for (stmt in null_fix_stmts) {
  tryCatch(
    DatabaseConnector::executeSql(conn_null_fix, stmt),
    error = function(e) cat("[INFO] NULL fix note (non-fatal):", conditionMessage(e), "\n")
  )
}
DatabaseConnector::disconnect(conn_null_fix)
cat("[INFO] \u2713 Nullable columns corrected (invalid_reason, standard_concept)\n")

# -----------------------------------------------------------------------------
# Step 4: Set database permanently to SIMPLE recovery
# -----------------------------------------------------------------------------
conn_final <- DatabaseConnector::connect(connection_details)
on.exit(DatabaseConnector::disconnect(conn_final), add = TRUE)

DatabaseConnector::executeSql(
  conn_final,
  paste0("ALTER DATABASE [", cfg$database, "] SET RECOVERY SIMPLE;")
)
cat("[INFO] \u2713 Database set to SIMPLE recovery (permanent for this dev/synthetic instance)\n")

# Shrink log back down now that vocab load is complete.
DatabaseConnector::executeSql(conn_final, "CHECKPOINT;")

log_name_sql <- paste0(
  "SELECT name FROM sys.master_files ",
  "WHERE database_id = DB_ID('", gsub("'", "''", cfg$database), "') AND type_desc = 'LOG';"
)
log_name_row <- DatabaseConnector::querySql(conn_final, log_name_sql)
colnames(log_name_row) <- tolower(colnames(log_name_row))
log_name <- as.character(log_name_row$name[[1]])
tryCatch(
  DatabaseConnector::querySql(conn_final, paste0("DBCC SHRINKFILE (", log_name, ", 1024);")),
  error = function(e) cat("[INFO] SHRINKFILE note (non-fatal):", conditionMessage(e), "\n")
)
cat("[INFO] \u2713 Transaction log shrunk back to ~1 GB\n")

DatabaseConnector::disconnect(conn_final)

# -----------------------------------------------------------------------------
# Step 5: Restore SQL Server memory to a balanced value for analysis
#
# The low cap used during the load is fine for bulk inserts but throttles
# analytic queries (CohortMethod, FeatureExtraction). Raise it to ~50% of total
# RAM (min 2 GB) so SQL Server and the R analysis session share memory sensibly.
# -----------------------------------------------------------------------------
analysis_sql_cap_mb <- if (!is.na(total_ram_mb)) {
  max(2048L, as.integer(floor(total_ram_mb * 0.5)))
} else {
  4096L
}
conn_mem <- DatabaseConnector::connect(master_connection_details)
DatabaseConnector::executeSql(
  conn_mem,
  paste0("EXEC sp_configure 'max server memory (MB)', ", analysis_sql_cap_mb, "; RECONFIGURE;"),
  progressBar = FALSE, reportOverallTime = FALSE
)
DatabaseConnector::disconnect(conn_mem)
cat(sprintf("[INFO] ✓ SQL Server memory restored to %d MB for analysis workloads\n",
            analysis_sql_cap_mb))

cat("\n=== Setup complete ===\n")
cat("Vocabulary is now available in schema '", vocab_schema, "'.\n\n", sep = "")
cat("Next steps:\n")
cat("  In workflow/05_etl_csv_to_omop.R, set:\n")
cat("    use_shared_vocab_schema <- TRUE\n")
cat("  All ETL runs will now use synonyms instead of reloading vocabulary.\n\n")
