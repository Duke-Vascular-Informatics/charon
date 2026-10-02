#!/usr/bin/env Rscript
# =============================================================================
# update_dvi_concept_sets.R
#
# WHAT THIS IS
# ------------
# ONE-OFF, EXPLICITLY-INVOKED writer that UPDATES the item list of an EXISTING
# label-prefixed ATLAS concept set (see ATLAS_LABEL_PREFIX below — "[DVI]" is
# just this template's placeholder, use your own lab's label) so it matches
# its `phenotype_library/catalog.yaml` entry. The companion to
# push_dvi_concept_sets.R, which only ever CREATES and skips any name that
# already exists — meaning a catalog change to an already-pushed set would
# otherwise have no path to ATLAS at all, leaving that entry's
# `alignment_status` stuck at "LOCAL AHEAD OF ATLAS".
#
# WHY IT IS MORE GUARDED THAN THE CREATE PATH
# -------------------------------------------
# An update is DESTRUCTIVE: `PUT /conceptset/{id}/items` REPLACES the item list.
# A wrong target silently rewrites someone else's phenotype, and the previous
# definition is not recoverable from ATLAS. So, beyond everything the create path
# does, this script:
#   * REQUIRES --only <entry_id[,entry_id...]>. There is deliberately NO bulk
#     sweep — you cannot update "everything that drifted" in one command.
#   * BACKS UP the live definition to disk before writing, every time, including
#     on a dry run.
#   * Prints a real ITEM-LEVEL DIFF (added / removed / flags changed) with concept
#     names, so the operator approves a change rather than a count.
#   * ROUND-TRIP VERIFIES after writing and fails loudly on any mismatch.
#   * REFUSES to write an empty item list (that would blank the set).
#
# GUARDS (all of them)
# --------------------
#   * Dry-run is the DEFAULT. Writes happen only with --commit.
#   * --only is MANDATORY. No target defaults, no wildcards.
#   * The live ATLAS name must literally start with ATLAS_LABEL_PREFIX —
#     refused otherwise. This is checked against the LIVE name fetched from
#     WebAPI, not the catalog, so a mistyped id cannot slip through on a
#     catalog-side name.
#   * The catalog entry must be `status: verified`.
#   * The entry must carry an external_alignment entry tagged ATLAS_SOURCE_TAG
#     concept_set id — the script never guesses which ATLAS set an entry
#     corresponds to.
#   * Refuses an empty desired item list.
#   * Names are NOT changed unless --rename is passed; a mismatch is reported.
#     Renaming can break references held elsewhere, so it is opt-in.
#
# USAGE
# -----
#   Rscript phenotype_library/scripts/update_dvi_concept_sets.R --only example_phenotype
#   Rscript phenotype_library/scripts/update_dvi_concept_sets.R --only example_phenotype,another_entry
#   Rscript phenotype_library/scripts/update_dvi_concept_sets.R --only example_phenotype --commit
#   Rscript phenotype_library/scripts/update_dvi_concept_sets.R --only x --with-exclusions --commit
#   Rscript phenotype_library/scripts/update_dvi_concept_sets.R --only x --rename --commit
#
# NOTE ON --with-exclusions
#   Mirrors the create path: exclusions are omitted unless asked for. For a set
#   whose catalog entry has `exclusion_concept_sets: []` the flag is a no-op. For
#   one that HAS exclusions, omitting the flag would push a BROADER definition
#   than the catalog describes — the script warns when that is the case.
#
# OUTPUTS
#   Backups : /tmp/dvi_backup_<id>_<timestamp>.json   (always, incl. dry runs)
#   Map     : /tmp/dvi_updated.json                   (on --commit, for catalog
#                                                      alignment_status backfill)
# =============================================================================

suppressWarnings(suppressMessages({ library(yaml); library(jsonlite) }))
`%||%` <- function(x, y) if (is.null(x)) y else x

BASE_URL           <- "https://atlas-demo.ohdsi.org/WebAPI"  # public OHDSI demo instance; point at your own if you have one
ATLAS_LABEL_PREFIX <- "[DVI]"      # TODO: replace with your own lab's label, e.g. "[MYLAB]"
ATLAS_SOURCE_TAG   <- "DVI_ATLAS"  # TODO: matches external_alignment.source in catalog.yaml — keep in sync
UPDATED_MAP <- "/tmp/dvi_updated.json"
STAMP      <- format(Sys.time(), "%Y%m%dT%H%M%S")

args      <- commandArgs(trailingOnly = TRUE)
COMMIT    <- "--commit" %in% args
WITH_EXCL <- "--with-exclusions" %in% args
RENAME    <- "--rename" %in% args
ONLY      <- { i <- match("--only", args)
               if (!is.na(i) && length(args) >= i + 1) trimws(strsplit(args[i + 1], ",")[[1]]) else character(0) }

if (length(ONLY) == 0) {
  cat("\n*** REFUSED: --only <entry_id[,entry_id...]> is mandatory.\n",
      "    This script UPDATES existing ATLAS concept sets in place, which\n",
      "    replaces their item lists. There is deliberately no bulk mode.\n\n",
      "    Rscript phenotype_library/scripts/update_dvi_concept_sets.R --only example_phenotype\n\n", sep = "")
  quit(status = 1)
}

# ---- workspace root --------------------------------------------------------
find_workspace_root <- function() {
  d <- normalizePath(getwd(), mustWork = FALSE)
  for (i in 1:6) {
    if (file.exists(file.path(d, "phenotype_library", "catalog.yaml"))) return(d)
    p <- dirname(d); if (identical(p, d)) break; d <- p
  }
  stop("Could not locate phenotype_library/catalog.yaml from ", getwd())
}
ROOT <- find_workspace_root()
catalog <- yaml::read_yaml(file.path(ROOT, "phenotype_library", "catalog.yaml"))

# ---- helpers (kept behaviourally identical to push_dvi_concept_sets.R) -----
sanitize_name <- function(s) {
  s <- gsub("\\s*/\\s*", "-", s)
  s <- gsub('[\\\\:*?<>|"]', "-", s)
  s <- gsub("\\s+", " ", s)
  trimws(s)
}

# Desired ATLAS items from a catalog entry: included concepts + optional excluded.
build_items <- function(e, with_excl = FALSE) {
  items <- list()
  for (it in e$concept_sets %||% list()) {
    cid <- suppressWarnings(as.integer(it$concept_id))
    if (is.na(cid) || cid == 0 || is.null(it$vocab_query_date)) next
    inc_desc <- isTRUE(it$include_descendants) || identical(it$include_descendants, "true")
    items[[length(items) + 1]] <- list(conceptId = cid, isExcluded = 0L,
      includeDescendants = if (inc_desc) 1L else 0L, includeMapped = 0L)
  }
  if (with_excl) for (it in e$exclusion_concept_sets %||% list()) {
    cid <- suppressWarnings(as.integer(it$concept_id))
    if (is.na(cid) || cid == 0) next
    inc_desc <- isTRUE(it$include_descendants) || identical(it$include_descendants, "true")
    items[[length(items) + 1]] <- list(conceptId = cid, isExcluded = 1L,
      includeDescendants = if (inc_desc) 1L else 0L, includeMapped = 0L)
  }
  items
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

# The ATLAS concept_set id recorded on the entry. Never inferred.
entry_dvi_id <- function(e) {
  for (al in e$external_alignment %||% list()) {
    if (identical(al$source, ATLAS_SOURCE_TAG) && identical(al$type, "concept_set")) {
      id <- suppressWarnings(as.integer(al$id))
      if (!is.na(id)) return(id)
    }
  }
  NA_integer_
}

# Normalise an items array (live or desired) to a comparable data frame.
as_item_df <- function(items) {
  if (length(items) == 0) {
    return(data.frame(conceptId = integer(0), isExcluded = integer(0),
                      includeDescendants = integer(0), stringsAsFactors = FALSE))
  }
  df <- do.call(rbind, lapply(items, function(x) data.frame(
    conceptId          = as.integer(x$conceptId %||% x$concept$CONCEPT_ID),
    isExcluded         = as.integer(isTRUE(as.logical(x$isExcluded %||% 0))),
    includeDescendants = as.integer(isTRUE(as.logical(x$includeDescendants %||% 0))),
    stringsAsFactors = FALSE)))
  df[order(df$conceptId), ]
}

# Concept names for the diff, so the operator reads clinical content not ids.
#
# Endpoint is /vocabulary/concept/{id} — NOT /concept/{id}, which exists but
# returns a Java stack trace on this instance. Names come from ATLAS's own
# vocabulary rather than the local omop_vocab, deliberately: this script talks
# only to WebAPI and needs no database connection, and for a diff it is more
# useful to show what ATLAS believes a concept is.
concept_names <- function(ids) {
  out <- setNames(rep(NA_character_, length(ids)), as.character(ids))
  for (id in unique(ids)) {
    r <- curl_json("GET", sprintf("%s/vocabulary/concept/%d", BASE_URL, id))
    nm <- tryCatch(fromJSON(r$body)$CONCEPT_NAME, error = function(e) NULL)
    if (!is.null(nm) && length(nm) == 1) out[[as.character(id)]] <- nm
  }
  out
}

fetch_set <- function(id) {
  meta <- curl_json("GET", sprintf("%s/conceptset/%d", BASE_URL, id))
  if (!startsWith(meta$code, "20")) stop(sprintf("GET conceptset/%d HTTP %s", id, meta$code))
  itm <- curl_json("GET", sprintf("%s/conceptset/%d/items", BASE_URL, id))
  if (!startsWith(itm$code, "20")) stop(sprintf("GET conceptset/%d/items HTTP %s", id, itm$code))
  list(name  = tryCatch(fromJSON(meta$body)$name, error = function(e) NA_character_),
       items = tryCatch(fromJSON(itm$body, simplifyVector = FALSE), error = function(e) list()))
}

# ---- plan ------------------------------------------------------------------
entries <- catalog$entries %||% list()
by_id <- setNames(entries, vapply(entries, function(e) e$id %||% "", character(1)))

cat(sprintf("\n%s [%s]%s — %d target(s)\n",
            if (COMMIT) "COMMIT MODE" else "DRY RUN (no writes)",
            if (WITH_EXCL) "--with-exclusions" else "includes only",
            if (RENAME) " [--rename]" else "", length(ONLY)))
cat(strrep("=", 78), "\n")

plans <- list()
for (eid in ONLY) {
  cat(sprintf("\n--- %s ---\n", eid))
  e <- by_id[[eid]]
  if (is.null(e)) { cat("  REFUSED: no catalog entry with this id.\n"); next }
  if (!identical(e$status, "verified")) {
    cat(sprintf("  REFUSED: catalog status is '%s', not 'verified'.\n", e$status %||% "NULL")); next
  }
  dvi_id <- entry_dvi_id(e)
  if (is.na(dvi_id)) {
    cat(sprintf("  REFUSED: no external_alignment %s concept_set id on this entry.\n", ATLAS_SOURCE_TAG),
        "           Use push_dvi_concept_sets.R to CREATE it first.\n", sep = ""); next
  }

  live <- fetch_set(dvi_id)
  if (!startsWith(live$name %||% "", ATLAS_LABEL_PREFIX)) {
    cat(sprintf("  REFUSED: live ATLAS name for %d is %s — does not start with '%s'.\n",
                dvi_id, dQuote(live$name %||% "<none>"), ATLAS_LABEL_PREFIX)); next
  }

  # Always back up before doing anything, dry run included.
  bak <- sprintf("/tmp/dvi_backup_%d_%s.json", dvi_id, STAMP)
  writeLines(toJSON(list(concept_set_id = dvi_id, name = live$name,
                         fetched_at = STAMP, items = live$items),
                    auto_unbox = TRUE, pretty = TRUE), bak)

  desired <- build_items(e, with_excl = WITH_EXCL)
  if (length(desired) == 0) {
    cat("  REFUSED: desired item list is EMPTY — refusing to blank the set.\n"); next
  }
  if (!WITH_EXCL && length(e$exclusion_concept_sets %||% list()) > 0) {
    cat("  ⚠ WARNING: entry HAS exclusion_concept_sets but --with-exclusions was not\n",
        "             passed. The pushed definition will be BROADER than the catalog.\n", sep = "")
  }

  cur_df <- as_item_df(live$items)
  new_df <- as_item_df(desired)
  key <- function(d) paste(d$conceptId, d$isExcluded, d$includeDescendants, sep = "/")
  added   <- new_df[!key(new_df) %in% key(cur_df), , drop = FALSE]
  removed <- cur_df[!key(cur_df) %in% key(new_df), , drop = FALSE]

  cat(sprintf("  ATLAS %d : %s\n", dvi_id, live$name))
  cat(sprintf("  backup   : %s\n", bak))
  cat(sprintf("  items    : live %d -> desired %d\n", nrow(cur_df), nrow(new_df)))

  if (nrow(added) == 0 && nrow(removed) == 0) {
    cat("  NO CHANGE — ATLAS already matches the catalog.\n")
    plans[[eid]] <- list(eid = eid, dvi_id = dvi_id, name = live$name,
                         desired = desired, nochange = TRUE)
    next
  }
  nm <- concept_names(unique(c(added$conceptId, removed$conceptId)))
  if (nrow(removed)) {
    cat("  REMOVE:\n")
    for (i in seq_len(nrow(removed))) cat(sprintf("    - %-9d excl=%d desc=%d  %s\n",
      removed$conceptId[i], removed$isExcluded[i], removed$includeDescendants[i],
      nm[[as.character(removed$conceptId[i])]] %||% "?"))
  }
  if (nrow(added)) {
    cat("  ADD:\n")
    for (i in seq_len(nrow(added))) cat(sprintf("    + %-9d excl=%d desc=%d  %s\n",
      added$conceptId[i], added$isExcluded[i], added$includeDescendants[i],
      nm[[as.character(added$conceptId[i])]] %||% "?"))
  }

  cat_name <- sanitize_name(paste(ATLAS_LABEL_PREFIX, e$name))
  if (!identical(cat_name, live$name)) {
    cat(sprintf("  NAME     : live %s\n             catalog %s\n", dQuote(live$name), dQuote(cat_name)))
    cat(sprintf("             %s\n", if (RENAME) "will be RENAMED (--rename)" else
                "left unchanged — pass --rename to update it"))
  }
  plans[[eid]] <- list(eid = eid, dvi_id = dvi_id, name = live$name,
                       cat_name = cat_name, desired = desired, nochange = FALSE)
}

actionable <- Filter(function(p) !isTRUE(p$nochange), plans)
cat(sprintf("\n--> %d target(s) with changes | %d already matching | %d refused\n",
            length(actionable), length(plans) - length(actionable), length(ONLY) - length(plans)))

if (!COMMIT) {
  cat("\nDry run only. Re-run with --commit to apply.\n")
  quit(status = 0)
}
if (length(actionable) == 0) { cat("\nNothing to do.\n"); quit(status = 0) }

# ---- commit ----------------------------------------------------------------
cat(sprintf("\nUpdating %d label-tagged concept set(s) on %s ...\n", length(actionable), BASE_URL))
results <- list(); failures <- 0L
for (p in actionable) {
  if (RENAME && !identical(p$cat_name, p$name)) {
    bf <- tempfile(fileext = ".json")
    writeLines(toJSON(list(id = p$dvi_id, name = p$cat_name), auto_unbox = TRUE), bf)
    r <- curl_json("PUT", sprintf("%s/conceptset/%d", BASE_URL, p$dvi_id), bf)
    if (!startsWith(r$code, "20")) {
      cat(sprintf("  FAIL rename id=%d HTTP %s\n", p$dvi_id, r$code)); failures <- failures + 1L
    } else cat(sprintf("  OK   renamed id=%d -> %s\n", p$dvi_id, p$cat_name))
  }

  bf2 <- tempfile(fileext = ".json")
  writeLines(toJSON(p$desired, auto_unbox = TRUE), bf2)
  r2 <- curl_json("PUT", sprintf("%s/conceptset/%d/items", BASE_URL, p$dvi_id), bf2)
  if (!startsWith(r2$code, "20")) {
    cat(sprintf("  FAIL id=%d items PUT HTTP %s: %s\n", p$dvi_id, r2$code, substr(r2$body, 1, 200)))
    failures <- failures + 1L; next
  }

  # Round-trip verify: what ATLAS now holds must equal what we intended.
  back <- fetch_set(p$dvi_id)
  got  <- as_item_df(back$items)
  want <- as_item_df(p$desired)
  ok <- identical(
    paste(got$conceptId,  got$isExcluded,  got$includeDescendants,  sep = "/"),
    paste(want$conceptId, want$isExcluded, want$includeDescendants, sep = "/"))
  if (ok) {
    cat(sprintf("  OK   id=%-9d items=%-3d verified  %s  <- %s\n",
                p$dvi_id, nrow(got), back$name, p$eid))
    results[[length(results) + 1]] <- list(entry_id = p$eid, dvi_id = p$dvi_id,
                                           name = back$name, n_items = nrow(got),
                                           updated_at = STAMP)
  } else {
    cat(sprintf("  FAIL id=%d ROUND-TRIP MISMATCH — wrote %d, ATLAS returned %d.\n",
                p$dvi_id, nrow(want), nrow(got)))
    cat("       The set may be in a partial state. Restore from the backup above.\n")
    failures <- failures + 1L
  }
}

if (length(results)) {
  writeLines(toJSON(results, auto_unbox = TRUE, pretty = TRUE), UPDATED_MAP)
  cat(sprintf("\nUpdated %d set(s). Map -> %s\n", length(results), UPDATED_MAP))
  cat("Next: set alignment_status back to matches_dvi for these entries in catalog.yaml.\n")
}
if (failures > 0) {
  cat(sprintf("\n%d failure(s). Backups are in /tmp/dvi_backup_*_%s.json\n", failures, STAMP))
  quit(status = 1)
}
