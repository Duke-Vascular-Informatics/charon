#!/usr/bin/env Rscript
# =============================================================================
# synthetic_data/scripts/drop_local_schema.R
#
# Guarded dropper for a LOCAL synthetic-CDM schema (and its overlay views), to
# free mssql_dev disk in the load-on-demand reuse model:
#     export_clinical_tables.R  ->  drop_local_schema.R  ->  import_clinical_tables.R
#
# ONLY drop a synthetic schema you have already exported (export_clinical_tables.R)
# or can regenerate — this is destructive. Refuses to touch the shared vocabulary
# schema. Restore later with:
#   Rscript synthetic_data/scripts/import_clinical_tables.R --zip <export.zip> --target-schema <schema>
#
# USAGE (devcontainer):
#   Rscript synthetic_data/scripts/drop_local_schema.R --schema <schema_name> [--schema <schema2> ...] --yes
#   # --yes is REQUIRED (no-op dry preview without it).
#
# Env: OMOP_SERVER, OMOP_DATABASE, MSSQL_USER, MSSQL_SA_PASSWORD, MSSQL_PORT,
#      DATABASECONNECTOR_JAR_FOLDER.
# =============================================================================
args <- commandArgs(trailingOnly = TRUE)
schemas <- args[which(args == "--schema") + 1L]
confirm <- "--yes" %in% args
if (length(schemas) == 0L) {
  cat("Usage: Rscript synthetic_data/scripts/drop_local_schema.R --schema <name> [--schema <name2>] --yes\n")
  quit(status = 1)
}

# Guard: never drop vocabulary / master schemas.
FORBIDDEN <- c("omop_vocab", "dbo", "sys", "information_schema", "guest")
bad <- schemas[tolower(schemas) %in% FORBIDDEN | grepl("vocab", schemas, ignore.case = TRUE)]
if (length(bad) > 0L) {
  stop(sprintf("[drop_local_schema] Refusing to drop protected schema(s): %s", paste(bad, collapse = ", ")))
}

suppressPackageStartupMessages(library(DatabaseConnector))
cd <- DatabaseConnector::createConnectionDetails(
  dbms = "sql server",
  server = Sys.getenv("OMOP_SERVER", "localhost"),
  user = Sys.getenv("MSSQL_USER", "SA"),
  password = Sys.getenv("MSSQL_SA_PASSWORD"),
  port = as.integer(Sys.getenv("MSSQL_PORT", "1433")),
  extraSettings = paste0("database=", Sys.getenv("OMOP_DATABASE", "omop_synth"),
                         ";trustServerCertificate=true")
)
conn <- DatabaseConnector::connect(cd); on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

for (sch in schemas) {
  objs <- tryCatch(DatabaseConnector::querySql(conn, sprintf(
    "SELECT v.name AS name, 'V' typ FROM sys.views v JOIN sys.schemas s ON s.schema_id=v.schema_id WHERE s.name='%s'
     UNION ALL
     SELECT t.name AS name, 'U' typ FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id WHERE s.name='%s'",
    sch, sch)), error = function(e) { cat("[drop_local_schema] query error:", conditionMessage(e), "\n"); data.frame() })
  names(objs) <- toupper(names(objs))
  cat(sprintf("[drop_local_schema] %s: %d object(s)%s\n", sch, nrow(objs),
              if (!confirm) " (preview — pass --yes to drop)" else ""))
  if (!confirm || nrow(objs) == 0L) next
  for (i in seq_len(nrow(objs))) {
    kind <- if (objs$TYP[i] == "V") "VIEW" else "TABLE"
    tryCatch(DatabaseConnector::executeSql(conn, sprintf("DROP %s [%s].[%s]", kind, sch, objs$NAME[i])),
             error = function(e) cat("  (skip)", objs$NAME[i], "\n"))
  }
  tryCatch(DatabaseConnector::executeSql(conn, sprintf("DROP SCHEMA [%s]", sch)), error = function(e) NULL)
  cat(sprintf("[drop_local_schema] dropped %s\n", sch))
}

if (confirm) {
  db <- Sys.getenv("OMOP_DATABASE", "omop_synth")
  tryCatch(DatabaseConnector::executeSql(conn, sprintf("USE %s; CHECKPOINT", db)), error = function(e) NULL)
  for (cmd in c(sprintf("USE %s; DBCC SHRINKFILE (%s_log, 512, TRUNCATEONLY)", db, db),
                sprintf("USE %s; DBCC SHRINKFILE (%s, TRUNCATEONLY)", db, db))) {
    tryCatch(DatabaseConnector::executeSql(conn, cmd), error = function(e) NULL)
  }
  cat("[drop_local_schema] checkpoint + TRUNCATEONLY shrink done. Remember to update local_schemas.yaml.\n")
}
