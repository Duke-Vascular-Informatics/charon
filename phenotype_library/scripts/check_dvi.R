#!/usr/bin/env Rscript
# =============================================================================
# phenotype_library/scripts/check_dvi.R
#
# PURPOSE
# -------
# Tier 1b of the phenotype lookup workflow (runs alongside check_pl.R's Tier 1
# OHDSI Phenotype Library check, before the local catalog and any live vocab
# query). Sweeps a shared OHDSI ATLAS instance for published cohort
# definitions and concept sets whose name carries YOUR LAB'S CHOSEN label
# prefix (set ATLAS_LABEL_PREFIX below — "[DVI]" in the example below is just
# this template's placeholder, pick your own and use it consistently). A
# label-tagged entry is treated as AUTHORITATIVE: local phenotype/concept-set
# definitions should converge to their tagged counterpart, with any
# deliberate difference recorded as a documented exception (see the
# `alignment_status` field convention in catalog.yaml), not silently diverged
# from.
#
# CUSTOMIZE BEFORE USE: set ATLAS_LABEL_PREFIX below to your own lab's label
# (e.g. "[MYLAB]") and, if you maintain your own ATLAS instance rather than
# using the public OHDSI demo, ATLAS_BASE_URL too. Keep the choice consistent
# across this script, push_dvi_concept_sets.R, update_dvi_concept_sets.R, and
# rename_dvi_conceptset.R — they all key off the same prefix.
#
# USAGE
# -----
#   Rscript phenotype_library/scripts/check_dvi.R "<search term>"
#   Rscript phenotype_library/scripts/check_dvi.R --list
#   Rscript phenotype_library/scripts/check_dvi.R --refresh
#   Rscript phenotype_library/scripts/check_dvi.R --cohort-id <id> [--save <path>]
#   Rscript phenotype_library/scripts/check_dvi.R --concept-set-id <id> [--save <path>]
#
# Examples:
#   Rscript phenotype_library/scripts/check_dvi.R "revascularization"
#   Rscript phenotype_library/scripts/check_dvi.R --list
#   Rscript phenotype_library/scripts/check_dvi.R --refresh
#   Rscript phenotype_library/scripts/check_dvi.R --cohort-id 1796269 --save /tmp/dvi_1796269.json
#     # the saved file can then be fed to check_overlap.R --atlas-json
#
# HOW THE CACHE WORKS
# --------------------
# The first two usages ("<term>" / --list) search a LOCAL, committed snapshot
# of every label-prefixed cohort/concept-set NAME + ID (phenotype_library/
# dvi_index.yaml) — not a live query — because the bulk ATLAS list endpoints
# return the instance's ENTIRE catalog (tens of thousands of cohorts/concept
# sets on the public OHDSI demo instance) and re-fetching all of that on
# every lookup would be slow and unnecessary. Run --refresh periodically (and
# definitely before relying on an absence — "not found" only means "not in
# the last refresh") to re-sweep the live instance and rewrite the cache. The
# cache is a workspace-shared, git-committed file specifically so everyone
# sees the same snapshot without each having to sweep tens of thousands of
# entries themselves.
#
# --cohort-id / --concept-set-id fetch the FULL definition for one already-
# known ID directly from the live API (not the cache) and print/save it as
# JSON. Feed the saved file to check_overlap.R --atlas-json to compare it
# against this catalog before registering anything new.
#
# THIS SCRIPT IS READ-ONLY. It has no write/POST capability at all, and none
# should be added without a deliberate, separate decision: any future
# ATLAS-write tool must (a) only run when explicitly invoked for that specific
# write, never as a side effect of a search/refresh/sync command, and (b)
# hard-refuse unless the target name literally starts with your chosen label
# prefix.
#
# REQUIREMENTS
# ------------
# yaml, jsonlite packages. Install once: renv::install(c("yaml", "jsonlite"))
# Network access to the configured ATLAS instance (ATLAS_BASE_URL below).
# =============================================================================

ATLAS_BASE_URL     <- "https://atlas-demo.ohdsi.org/WebAPI"  # public OHDSI demo instance; point at your own if you have one
ATLAS_LABEL_PREFIX <- "[DVI]"  # TODO: replace with your own lab's label, e.g. "[MYLAB]"

`%||%` <- function(x, y) if (is.null(x)) y else x

find_workspace_root <- function() {
  candidates <- c(getwd(), file.path(getwd(), ".."))
  for (p in candidates) {
    if (file.exists(file.path(p, "phenotype_library", "catalog.yaml"))) return(normalizePath(p))
  }
  stop("Run this script from the workspace root (where phenotype_library/ lives).")
}

epoch_millis_to_date <- function(x) {
  if (is.null(x) || is.na(x)) return(NA_character_)
  format(as.POSIXct(as.numeric(x) / 1000, origin = "1970-01-01", tz = "UTC"), "%Y-%m-%d")
}

# ---------------------------------------------------------------------------
# Minimal HTTP GET using base R only (no httr/curl package dependency) —
# confirmed working against atlas-demo.ohdsi.org's WebAPI 2026-07-18.
# ---------------------------------------------------------------------------
http_get_json <- function(url, timeout_sec = 30) {
  old_timeout <- getOption("timeout")
  options(timeout = timeout_sec)
  on.exit(options(timeout = old_timeout), add = TRUE)

  con <- url(url, method = "libcurl", headers = c(Accept = "application/json"))
  on.exit(try(close(con), silent = TRUE), add = TRUE)
  txt <- tryCatch(
    paste(readLines(con, warn = FALSE), collapse = ""),
    error = function(e) stop("Request failed for ", url, ": ", conditionMessage(e))
  )
  jsonlite::fromJSON(txt, simplifyVector = FALSE)
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
usage <- function() {
  cat(
    "Usage:\n",
    "  Rscript phenotype_library/scripts/check_dvi.R \"<search term>\"\n",
    "  Rscript phenotype_library/scripts/check_dvi.R --list\n",
    "  Rscript phenotype_library/scripts/check_dvi.R --refresh\n",
    "  Rscript phenotype_library/scripts/check_dvi.R --cohort-id <id> [--save <path>]\n",
    "  Rscript phenotype_library/scripts/check_dvi.R --concept-set-id <id> [--save <path>]\n"
  )
}
if (length(args) == 0L) { usage(); quit(status = 1) }

if (!requireNamespace("yaml", quietly = TRUE)) {
  stop("Package 'yaml' is required. Install with: renv::install('yaml')")
}
if (!requireNamespace("jsonlite", quietly = TRUE)) {
  stop("Package 'jsonlite' is required. Install with: renv::install('jsonlite')")
}

root       <- find_workspace_root()
index_path <- file.path(root, "phenotype_library", "dvi_index.yaml")

# ---------------------------------------------------------------------------
# --cohort-id / --concept-set-id: fetch one full definition live, no cache
# ---------------------------------------------------------------------------
if (args[1] %in% c("--cohort-id", "--concept-set-id")) {
  if (length(args) < 2L) { usage(); quit(status = 1) }
  id <- suppressWarnings(as.integer(args[2]))
  if (is.na(id)) stop("ID must be an integer.")

  save_path <- NULL
  if (length(args) >= 4L && args[3] == "--save") save_path <- args[4]

  endpoint <- if (args[1] == "--cohort-id") "cohortdefinition" else "conceptset"
  url <- sprintf("%s/%s/%d", ATLAS_BASE_URL, endpoint, id)
  cat(sprintf("[check_dvi] Fetching %s ...\n", url))
  result <- http_get_json(url)

  # A bare GET /conceptset/{id} returns only metadata (id/name/dates) — the
  # actual concept membership lives at the /items sub-endpoint, in a
  # different shape (lowercase "conceptId", no concept name/vocab metadata)
  # than a cohort's embedded ConceptSets[].expression.items[].concept
  # objects. Fetch and attach it so the saved file is self-contained.
  if (args[1] == "--concept-set-id") {
    items_url <- sprintf("%s/conceptset/%d/items", ATLAS_BASE_URL, id)
    cat(sprintf("[check_dvi] Fetching %s ...\n", items_url))
    result$items <- http_get_json(items_url)
  }

  name <- result$name %||% "(unnamed)"
  is_dvi <- startsWith(trimws(name), ATLAS_LABEL_PREFIX)
  cat(sprintf("  id   : %d\n", id))
  cat(sprintf("  name : %s%s\n", name, if (is_dvi) "  [DVI-tagged]" else "  *** NOT [DVI]-tagged ***"))
  if (args[1] == "--concept-set-id") {
    cat(sprintf("  items: %d concept(s)\n", length(result$items %||% list())))
  }

  if (!is.null(save_path)) {
    jsonlite::write_json(result, save_path, auto_unbox = TRUE, pretty = TRUE)
    cat(sprintf("  Saved raw definition to: %s\n", save_path))
    cat(sprintf("  Feed it to: Rscript phenotype_library/scripts/check_overlap.R --atlas-json %s\n", save_path))
  }
  quit(status = 0)
}

# ---------------------------------------------------------------------------
# --refresh: sweep the full instance, filter to [DVI]-prefixed, rewrite cache
# ---------------------------------------------------------------------------
if (args[1] == "--refresh") {
  cat(sprintf("[check_dvi] Sweeping %s for \"%s\"-prefixed cohorts and concept sets ...\n",
              ATLAS_BASE_URL, ATLAS_LABEL_PREFIX))
  cat("  (this pulls the instance's full list — tens of thousands of entries — expect this to take a bit)\n")

  all_cohorts <- http_get_json(paste0(ATLAS_BASE_URL, "/cohortdefinition"))
  all_csets   <- http_get_json(paste0(ATLAS_BASE_URL, "/conceptset"))

  is_dvi_named <- function(e) startsWith(trimws(e$name %||% ""), ATLAS_LABEL_PREFIX)

  dvi_cohorts <- Filter(is_dvi_named, all_cohorts)
  dvi_csets   <- Filter(is_dvi_named, all_csets)

  cat(sprintf("  %d/%d cohorts and %d/%d concept sets match the \"%s\" prefix.\n",
              length(dvi_cohorts), length(all_cohorts),
              length(dvi_csets), length(all_csets), ATLAS_LABEL_PREFIX))

  index <- list(
    fetched_date = format(Sys.Date(), "%Y-%m-%d"),
    instance     = ATLAS_BASE_URL,
    cohorts = lapply(dvi_cohorts, function(e) list(
      id = e$id, name = e$name, modified_date = epoch_millis_to_date(e$modifiedDate %||% e$createdDate)
    )),
    concept_sets = lapply(dvi_csets, function(e) list(
      id = e$id, name = e$name, modified_date = epoch_millis_to_date(e$modifiedDate %||% e$createdDate)
    ))
  )
  yaml::write_yaml(index, index_path)
  cat(sprintf("[check_dvi] Cache written to %s\n", index_path))
  quit(status = 0)
}

# ---------------------------------------------------------------------------
# "<term>" / --list: search the cached snapshot (auto-refresh if missing)
# ---------------------------------------------------------------------------
if (!file.exists(index_path)) {
  cat("[check_dvi] No local cache yet — run --refresh first:\n")
  cat("  Rscript phenotype_library/scripts/check_dvi.R --refresh\n")
  quit(status = 1)
}

index <- yaml::read_yaml(index_path)
cat(sprintf("[check_dvi] Searching cached snapshot from %s (%d cohorts, %d concept sets)\n\n",
            index$fetched_date %||% "unknown date", length(index$cohorts %||% list()), length(index$concept_sets %||% list())))

term <- if (args[1] == "--list") NULL else tolower(args[1])
matches_cohort <- function(e) is.null(term) || grepl(term, tolower(e$name %||% ""), fixed = TRUE)

matched_cohorts <- Filter(matches_cohort, index$cohorts %||% list())
matched_csets   <- Filter(matches_cohort, index$concept_sets %||% list())

if (length(matched_cohorts) == 0L && length(matched_csets) == 0L) {
  cat("[check_dvi] No match in the cached snapshot")
  if (!is.null(term)) cat(sprintf(" for \"%s\"", term))
  cat(sprintf(".\nCache is from %s — if this may be new, run --refresh and search again.\n", index$fetched_date %||% "unknown date"))
  quit(status = 1)
}

if (length(matched_cohorts) > 0L) {
  cat(sprintf("Cohort definitions (%d):\n", length(matched_cohorts)))
  for (e in matched_cohorts) {
    cat(sprintf("  %-10s %s  (modified %s)\n", e$id, e$name, e$modified_date %||% "?"))
  }
  cat("\n")
}
if (length(matched_csets) > 0L) {
  cat(sprintf("Concept sets (%d):\n", length(matched_csets)))
  for (e in matched_csets) {
    cat(sprintf("  %-10s %s  (modified %s)\n", e$id, e$name, e$modified_date %||% "?"))
  }
  cat("\n")
}

cat("To pull a full definition: --cohort-id <id> or --concept-set-id <id> [--save <path>]\n")
quit(status = 0)
