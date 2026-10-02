#!/usr/bin/env Rscript
# =============================================================================
# phenotype_library/scripts/rename_dvi_conceptset.R
#
# WHAT THIS IS
# ------------
# ONE-OFF, EXPLICITLY-INVOKED writer that renames a SINGLE existing
# [DVI]-prefixed ATLAS concept set's `name` field. Nothing else about the set
# -- its items, its ATLAS id -- is touched.
#
# WHY THIS IS A SEPARATE SCRIPT FROM update_dvi_concept_sets.R
# --------------------------------------------------------------
# update_dvi_concept_sets.R's --rename mode renames AS A SIDE EFFECT of
# syncing a set's item list to its phenotype_library/catalog.yaml entry --
# running it always evaluates (and, on --commit, can push) an item-level
# add/remove diff, even when all you want is the name fixed. That is more
# than a pure rename should risk touching. This script does ONE thing:
# PUT /conceptset/{id} with {id, name} only. It never calls
# /conceptset/{id}/items in either direction.
#
# Confirmed by live GET against atlas-demo.ohdsi.org 2026-08-27: the ATLAS
# object being renamed here is a CONCEPT SET (GET /conceptset/{id} -> 200),
# not a cohort definition (GET /cohortdefinition/{id} -> 404 for the same
# id). Every existing DVI writer in this workspace only ever handles concept
# sets for exactly this reason -- see phenotype_library/scripts/
# update_dvi_concept_sets.R's header and [[dvi_atlas_write_access]].
#
# SAFETY GUARDS (same philosophy as update_dvi_concept_sets.R)
# --------------------------------------------------------------
#   * Dry-run is the DEFAULT. Writes happen only with --commit.
#   * --id and --new-name are both MANDATORY. No defaults, no bulk mode,
#     exactly one target per invocation.
#   * The LIVE ATLAS name (fetched from WebAPI, not typed by the operator)
#     must start with "[DVI]" -- refused otherwise, so this can never be
#     pointed at someone else's non-DVI set.
#   * --new-name must ALSO start with "[DVI]" -- refused otherwise.
#   * Backs up the live {id, name} to /tmp before any write, including on a
#     dry run.
#   * Refuses a no-op (new name identical to live name).
#   * Round-trip verifies after writing (re-fetches and compares) and fails
#     loudly on any mismatch.
#
# USAGE (run from anywhere; workspace root is auto-detected)
#   Rscript phenotype_library/scripts/rename_dvi_conceptset.R --id 1890929 \
#     --new-name "[DVI] Open Lower Extremity Revascularization (OLER)"
#   # add --commit to actually write, after reviewing the dry-run output
#
# OUTPUT
#   Backup: /tmp/dvi_conceptset_rename_backup_<id>_<timestamp>.json (always)
#
# REQUIREMENTS: jsonlite; curl on PATH; network access to ATLAS.
# =============================================================================

suppressWarnings(suppressMessages({ library(jsonlite) }))

BASE_URL   <- "https://atlas-demo.ohdsi.org/WebAPI"
DVI_PREFIX <- "[DVI]"
STAMP      <- format(Sys.time(), "%Y%m%dT%H%M%S")

args    <- commandArgs(trailingOnly = TRUE)
COMMIT  <- "--commit" %in% args
ID      <- { i <- match("--id", args); if (!is.na(i) && length(args) >= i + 1) suppressWarnings(as.integer(args[i + 1])) else NA_integer_ }
NEW_NAME <- { i <- match("--new-name", args); if (!is.na(i) && length(args) >= i + 1) args[i + 1] else NA_character_ }

if (is.na(ID) || is.na(NEW_NAME) || !nzchar(NEW_NAME)) {
  cat("\n*** REFUSED: --id <concept_set_id> and --new-name \"<name>\" are both mandatory.\n\n",
      "    Rscript phenotype_library/scripts/rename_dvi_conceptset.R --id 1890929 \\\n",
      "      --new-name \"[DVI] Open Lower Extremity Revascularization (OLER)\"\n\n", sep = "")
  quit(status = 1)
}

curl_json <- function(method, url, body_file = NULL) {
  resp <- tempfile(fileext = ".resp")
  a <- c("-s", "-o", resp, "-w", "%{http_code}", "-X", method,
         "-H", "Content-Type: application/json", "-H", "Accept: application/json")
  if (!is.null(body_file)) a <- c(a, "--data-binary", paste0("@", body_file))
  a <- c(a, url)
  # system() runs through a shell without quoting, so shQuote every arg or any
  # header containing a space is word-split.
  code <- paste(system(paste("curl", paste(shQuote(a), collapse = " ")), intern = TRUE), collapse = "")
  body <- if (file.exists(resp)) paste(readLines(resp, warn = FALSE), collapse = "\n") else ""
  list(code = code, body = body)
}

fetch_name <- function(id) {
  r <- curl_json("GET", sprintf("%s/conceptset/%d", BASE_URL, id))
  if (!startsWith(r$code, "20")) stop(sprintf("GET /conceptset/%d HTTP %s: %s", id, r$code, substr(r$body, 1, 300)))
  parsed <- tryCatch(fromJSON(r$body), error = function(e) NULL)
  if (is.null(parsed) || is.null(parsed$name)) stop(sprintf("GET /conceptset/%d: no 'name' in response: %s", id, substr(r$body, 1, 300)))
  parsed$name
}

cat(sprintf("\n%s — rename ATLAS concept set %d\n", if (COMMIT) "COMMIT MODE" else "DRY RUN (no writes)", ID))
cat(strrep("=", 78), "\n")

live_name <- fetch_name(ID)
cat(sprintf("Live name    : %s\n", dQuote(live_name)))
cat(sprintf("Desired name : %s\n", dQuote(NEW_NAME)))

if (!startsWith(live_name, DVI_PREFIX)) {
  cat(sprintf("\n*** REFUSED: live name does not start with '%s'. Refusing to touch a non-DVI set.\n", DVI_PREFIX))
  quit(status = 1)
}
if (!startsWith(NEW_NAME, DVI_PREFIX)) {
  cat(sprintf("\n*** REFUSED: --new-name does not start with '%s'.\n", DVI_PREFIX))
  quit(status = 1)
}
if (identical(live_name, NEW_NAME)) {
  cat("\nNO CHANGE — live name already matches --new-name. Nothing to do.\n")
  quit(status = 0)
}

# Always back up before doing anything, dry run included.
bak <- sprintf("/tmp/dvi_conceptset_rename_backup_%d_%s.json", ID, STAMP)
writeLines(toJSON(list(concept_set_id = ID, name = live_name, fetched_at = STAMP),
                  auto_unbox = TRUE, pretty = TRUE), bak)
cat(sprintf("Backup       : %s\n", bak))

if (!COMMIT) {
  cat("\nDry run only. Re-run with --commit to apply.\n")
  quit(status = 0)
}

cat(sprintf("\nRenaming concept set %d on %s ...\n", ID, BASE_URL))
bf <- tempfile(fileext = ".json")
writeLines(toJSON(list(id = ID, name = NEW_NAME), auto_unbox = TRUE), bf)
r <- curl_json("PUT", sprintf("%s/conceptset/%d", BASE_URL, ID), bf)
if (!startsWith(r$code, "20")) {
  cat(sprintf("FAIL rename id=%d HTTP %s: %s\n", ID, r$code, substr(r$body, 1, 300)))
  cat(sprintf("Restore from backup if needed: %s\n", bak))
  quit(status = 1)
}

# Round-trip verify: what ATLAS now holds must equal what we intended.
verify_name <- fetch_name(ID)
if (identical(verify_name, NEW_NAME)) {
  cat(sprintf("OK   id=%d renamed and verified -> %s\n", ID, dQuote(verify_name)))
} else {
  cat(sprintf("FAIL id=%d ROUND-TRIP MISMATCH — wrote %s, ATLAS returned %s.\n",
              ID, dQuote(NEW_NAME), dQuote(verify_name)))
  cat(sprintf("Restore from backup if needed: %s\n", bak))
  quit(status = 1)
}
