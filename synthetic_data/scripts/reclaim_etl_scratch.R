#!/usr/bin/env Rscript
# =============================================================================
# synthetic_data/scripts/reclaim_etl_scratch.R
#
# Purpose : Reclaim disk in the omop_synth database by dropping regenerable ETL
#           scratch, then physically returning the freed pages to the
#           filesystem with a relocating shrink.
#
# Inputs  : MSSQL_HOST / MSSQL_PORT / MSSQL_USER / MSSQL_SA_PASSWORD from the
#           devcontainer environment. DATABASECONNECTOR_JAR_FOLDER must point at
#           a folder containing mssql-jdbc-*.jar.
#
# Outputs : Console report of what was dropped and the before/after file sizes.
#           No files written.
#
# Flags   : --dry-run    list what would be dropped, change nothing (default)
#           --apply      actually drop and shrink
#           --skip-shrink  drop only; leave the relocating shrink for later
#
# WHAT THIS DROPS, and why each class is safe:
#
#   1. ETLSyntheaBuilder vocabulary maps -- source_to_source_vocab_map and
#      source_to_standard_vocab_map -- in EVERY CDM schema. These are a pure
#      function of omop_vocab (identical row counts across every schema that
#      has them: 6,346,845 and 4,528,412) and carry no patient data. They are
#      consumed only during the ETL's own LoadEventTables phase. Precedent:
#      omop_synth_pad_amp_ed_desc and omop_synth_pad_ler_ldl_synth already have
#      them dropped and both are registry status: verified.
#
#   2. Synthea CSV staging tables in the `synthea` schema that
#      scripts/quality_check_etl.R does NOT read. That script reads exactly
#      four -- patients, encounters, procedures, conditions -- and hard-stops
#      if the staging schema is absent, so those four are PRESERVED and Step 6
#      still runs. Everything else (claims_transactions at ~2.1 GB, claims,
#      imaging_studies, observations, medications, ...) is reloadable from the
#      on-disk CSVs without re-running Synthea generation, so no unseeded
#      regeneration problem arises.
#
# WHAT THIS NEVER TOUCHES: omop_vocab, any CDM v5.4 clinical table, any
# *_results schema, and the four QC staging dependencies above.
#
# WHY THE SHRINK MATTERS: dropping tables frees pages INSIDE omop_synth.mdf but
# the OS does not see the space back until a RELOCATING shrink runs. A
# TRUNCATEONLY shrink returns ~nothing here because the freed pages are not at
# the end of the file -- it exits cleanly and reclaims nothing, which is the
# trap documented from the 2026-07-24 incident. Verify by the delta in
# sys.database_files.size, never by the command's exit status.
# =============================================================================

library(DatabaseConnector)

args        <- commandArgs(trailingOnly = TRUE)
apply_mode  <- "--apply" %in% args
skip_shrink <- "--skip-shrink" %in% args

# Post-drop target for the data file, in MB. Sized to leave ~2 GB of internal
# headroom above expected post-drop usage so the next load does not immediately
# autogrow the file straight back.
SHRINK_TARGET_MB <- 20480L

# Staging tables Step 6 QC depends on -- never drop these.
QC_KEEP <- c("patients", "encounters", "procedures", "conditions")

cd <- createConnectionDetails(
  dbms          = "sql server",
  server        = Sys.getenv("MSSQL_HOST"),
  port          = Sys.getenv("MSSQL_PORT"),
  user          = Sys.getenv("MSSQL_USER"),
  password      = Sys.getenv("MSSQL_SA_PASSWORD"),
  extraSettings = "encrypt=false;trustServerCertificate=true;databaseName=omop_synth"
)
con <- connect(cd)
on.exit(disconnect(con), add = TRUE)

file_state <- function() {
  querySql(con, "
    SELECT name AS NAME,
           CAST(size*8.0/1024 AS DECIMAL(9,0)) AS ALLOC_MB,
           CAST(FILEPROPERTY(name,'SpaceUsed')*8.0/1024 AS DECIMAL(9,0)) AS USED_MB
    FROM sys.database_files;")
}

# Refuse to run against a live ETL -- a drop mid-load would corrupt the run.
busy <- querySql(con, "
  SELECT r.session_id AS SESSION_ID
  FROM sys.dm_exec_requests r
  JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
  WHERE s.is_user_process = 1 AND r.session_id <> @@SPID;")
if (nrow(busy) > 0) {
  stop("Active user sessions are running against omop_synth. Aborting -- ",
       "re-run once the ETL has finished.")
}

# Build the drop list from live catalog state rather than a hardcoded list, so a
# CDM schema added since this was written is still covered automatically.
targets <- querySql(con, sprintf("
  SELECT s.name AS SCH, t.name AS TBL,
         CAST(SUM(p.used_page_count)*8.0/1024 AS DECIMAL(9,1)) AS MB
  FROM sys.dm_db_partition_stats p
  JOIN sys.tables t  ON t.object_id = p.object_id
  JOIN sys.schemas s ON s.schema_id = t.schema_id
  WHERE t.name IN ('source_to_source_vocab_map','source_to_standard_vocab_map')
     OR (s.name = 'synthea' AND t.name NOT IN ('%s'))
  GROUP BY s.name, t.name
  ORDER BY MB DESC;", paste(QC_KEEP, collapse = "','")))

if (nrow(targets) == 0) {
  cat("Nothing to reclaim -- no ETL scratch found.\n"); quit(status = 0)
}

cat(sprintf("\n=== reclaim candidates: %d tables, %.2f GB ===\n\n",
            nrow(targets), sum(targets$MB) / 1024))
print(targets, row.names = FALSE)

# Safety assertions: cheap insurance against a bad WHERE clause above.
protected <- c("person","observation_period","visit_occurrence","visit_detail",
               "condition_occurrence","drug_exposure","procedure_occurrence",
               "measurement","observation","death","cost","condition_era",
               "drug_era","device_exposure","provider","care_site","location",
               "payer_plan_period","cdm_source")
bad_cdm <- targets[tolower(targets$SCH) != "synthea" &
                     tolower(targets$TBL) %in% protected, ]
stopifnot("drop list caught a CDM clinical table -- aborting" = nrow(bad_cdm) == 0)

bad_qc <- targets[tolower(targets$SCH) == "synthea" &
                    tolower(targets$TBL) %in% QC_KEEP, ]
stopifnot("drop list caught a Step 6 QC dependency -- aborting" = nrow(bad_qc) == 0)

bad_vocab <- targets[tolower(targets$SCH) == "omop_vocab", ]
stopifnot("drop list caught omop_vocab -- aborting" = nrow(bad_vocab) == 0)

if (!apply_mode) {
  cat("\n[DRY RUN] Nothing changed. Re-run with --apply to execute.\n")
  quit(status = 0)
}

before <- file_state()
cat("\n--- file state before ---\n"); print(before, row.names = FALSE)

cat("\n--- dropping ---\n")
for (i in seq_len(nrow(targets))) {
  executeSql(con,
             sprintf("DROP TABLE IF EXISTS [%s].[%s];", targets$SCH[i], targets$TBL[i]),
             progressBar = FALSE, reportOverallTime = FALSE)
  cat(sprintf("  dropped %-32s %-30s %8.1f MB\n",
              targets$SCH[i], targets$TBL[i], targets$MB[i]))
}

if (skip_shrink) {
  cat("\n--skip-shrink set: pages are free inside the .mdf but NOT returned",
      "to the filesystem yet.\n")
  print(file_state(), row.names = FALSE); quit(status = 0)
}

# CHECKPOINT first so the drops' log records can be truncated under SIMPLE
# recovery before the data-file shrink generates its own log volume.
executeSql(con, "CHECKPOINT;", progressBar = FALSE, reportOverallTime = FALSE)

# Relocating shrink -- NOT TRUNCATEONLY. Expect several minutes on a ~29 GB
# file; sys.dm_exec_requests will show command = 'DbccFilesCompact' while it
# works. DBCC returns a result set, so this must go through querySql().
cat(sprintf("\n--- relocating shrink of omop_synth -> %d MB (several minutes) ---\n",
            SHRINK_TARGET_MB))
invisible(querySql(con, sprintf("DBCC SHRINKFILE (omop_synth, %d);", SHRINK_TARGET_MB)))

# Trim any log growth the shrink itself caused.
executeSql(con, "CHECKPOINT;", progressBar = FALSE, reportOverallTime = FALSE)
invisible(querySql(con, "DBCC SHRINKFILE (omop_synth_log, 512);"))

after <- file_state()
cat("\n--- file state after ---\n"); print(after, row.names = FALSE)

delta <- sum(before$ALLOC_MB) - sum(after$ALLOC_MB)
cat(sprintf("\n=== reclaimed %.2f GB of allocated file space ===\n", delta / 1024))
if (delta <= 0) {
  cat("WARNING: allocation did not shrink. The freed pages may not have been\n",
      "relocatable in one pass -- re-run, or check for an open transaction.\n")
}
