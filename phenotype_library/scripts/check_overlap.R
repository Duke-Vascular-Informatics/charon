#!/usr/bin/env Rscript
# =============================================================================
# phenotype_library/scripts/check_overlap.R
#
# PURPOSE
# -------
# Given a candidate list of concept IDs — typically pulled from an external
# source like a published ATLAS cohort/concept-set export — reports which
# EXISTING entries in phenotype_library/catalog.yaml already cover some or all
# of those concepts. Run this BEFORE registering a new concept set, so a
# candidate that substantially overlaps an already-verified local entry gets
# reused/composed instead of duplicated under a new name.
#
# This is what should have caught, automatically, that OHDSI ATLAS cohort
# 1796269's condition concept set overlapped with this workspace's already-
# verified `peripheral_arterial_disease` (317309) and `diabetes_mellitus`
# (201820) entries.
#
# USAGE
# -----
#   Rscript phenotype_library/scripts/check_overlap.R --concept-ids 317309,201820,4236706
#   Rscript phenotype_library/scripts/check_overlap.R --atlas-json <path to ATLAS export JSON>
#   Rscript phenotype_library/scripts/check_overlap.R --entry <existing catalog id>
#
# Examples:
#   Rscript phenotype_library/scripts/check_overlap.R --concept-ids 317309,201820
#   Rscript phenotype_library/scripts/check_overlap.R --atlas-json /tmp/atlas_1796269.json
#   Rscript phenotype_library/scripts/check_overlap.R --entry infra_oler
#
# --atlas-json accepts any of these ATLAS export shapes and extracts every
# concept ID it finds, regardless of nesting:
#   - A raw WebAPI cohortdefinition GET response (top-level "expression" field
#     is itself a JSON-ENCODED STRING containing "ConceptSets": [...])
#   - An already-parsed cohort expression object (top-level "ConceptSets")
#   - A bare concept-set EXPRESSION object (top-level "items", each item
#     nesting a full "concept": {"CONCEPT_ID": ...} object with metadata) —
#     the shape used inside a cohort's ConceptSets[].expression
#   - A raw concept-set ITEMS response, i.e. check_dvi.R's --concept-set-id
#     --save output (top-level "items", each a flat {"conceptId": ...,
#     "isExcluded": ...} row with NO nested concept metadata) — the shape
#     GET /WebAPI/conceptset/{id}/items actually returns
#   - A plain JSON array of integer concept IDs
#
# --entry checks an EXISTING catalog entry's own concept IDs against the rest
# of the catalog — useful for finding internal duplication, not just vetting
# something new.
#
# WHAT THIS DOES *NOT* DO
# ------------------------
# This is a STATIC, exact concept_id match against what is literally written
# in catalog.yaml. It does NOT expand `include_descendants: true` ancestors
# against the live vocabulary's concept_ancestor table, so a candidate concept
# that is a true descendant of an existing ancestor (but isn't itself listed)
# will NOT be detected as overlapping. That requires a live Tier 3 vocab query
# (scripts/concept_lookup.R) against omop_vocab.concept_ancestor — this script
# only narrows down which existing entries are worth checking that way.
#
# OUTPUT
# ------
# For each catalog entry with at least one matching concept ID: the entry's
# id/name/status, the matched concept IDs (flagging any that only match an
# EXCLUDED concept, which is a conflict, not simple overlap), and what
# fraction of both the candidate list and the entry's own concept list are
# covered. Ends with any candidate concept IDs matched by nothing in the
# catalog at all ("no existing catalog coverage").
#
# REQUIREMENTS
# ------------
# yaml, jsonlite packages. Install once: renv::install(c("yaml", "jsonlite"))
# =============================================================================

`%||%` <- function(x, y) if (is.null(x)) y else x

# ---------------------------------------------------------------------------
# Locate catalog.yaml relative to the working directory
# ---------------------------------------------------------------------------
find_catalog <- function() {
  candidates <- c(
    file.path(getwd(), "phenotype_library", "catalog.yaml"),
    "catalog.yaml"
  )
  for (p in candidates) {
    if (file.exists(p)) return(p)
  }
  stop(
    "catalog.yaml not found. Run this script from the workspace root:\n",
    "  Rscript phenotype_library/scripts/check_overlap.R --concept-ids ...\n"
  )
}

# ---------------------------------------------------------------------------
# Recursively walk an arbitrary parsed-JSON structure and pull out every
# CONCEPT_ID it finds under a "concept" object — this is deliberately generic
# so it doesn't care how deeply an ATLAS export nests ConceptSets/Groups.
# ---------------------------------------------------------------------------
extract_concept_ids_recursive <- function(x) {
  found <- integer(0)
  if (is.list(x)) {
    if (!is.null(x$CONCEPT_ID)) {
      found <- c(found, suppressWarnings(as.integer(x$CONCEPT_ID)))
    }
    # Raw GET /conceptset/{id}/items shape: flat {"conceptId": ..., ...} rows
    # with no nested "concept" object — distinct from the cohort-expression
    # shape's {"concept": {"CONCEPT_ID": ...}} above.
    if (!is.null(x$conceptId)) {
      found <- c(found, suppressWarnings(as.integer(x$conceptId)))
    }
    for (el in x) {
      found <- c(found, extract_concept_ids_recursive(el))
    }
  }
  found
}

parse_atlas_json <- function(path) {
  if (!file.exists(path)) stop("File not found: ", path)
  raw <- jsonlite::fromJSON(path, simplifyVector = FALSE)

  # A plain JSON array of integers, e.g. [317309, 201820, 4236706]
  if (is.list(raw) && length(raw) > 0 && all(vapply(raw, is.numeric, logical(1)))) {
    return(unique(as.integer(unlist(raw))))
  }

  # Raw WebAPI cohortdefinition GET response: "expression" is a JSON-encoded
  # STRING, not a nested object — needs a second parse pass.
  if (!is.null(raw$expression) && is.character(raw$expression)) {
    raw <- jsonlite::fromJSON(raw$expression, simplifyVector = FALSE)
  }

  ids <- extract_concept_ids_recursive(raw)
  unique(ids[!is.na(ids)])
}

# ---------------------------------------------------------------------------
# Flatten catalog entries into a lookup table: one row per (entry, concept),
# tagged with whether it came from concept_sets (included) or
# exclusion_concept_sets (excluded).
# ---------------------------------------------------------------------------
flatten_entry_concepts <- function(entry) {
  rows <- list()
  for (cs in entry$concept_sets %||% list()) {
    cid <- suppressWarnings(as.integer(cs$concept_id %||% NA))
    if (!is.na(cid)) {
      rows[[length(rows) + 1L]] <- list(
        concept_id = cid, concept_name = cs$concept_name %||% "",
        excluded = FALSE
      )
    }
  }
  for (cs in entry$exclusion_concept_sets %||% list()) {
    cid <- suppressWarnings(as.integer(cs$concept_id %||% NA))
    if (!is.na(cid)) {
      rows[[length(rows) + 1L]] <- list(
        concept_id = cid, concept_name = cs$concept_name %||% "",
        excluded = TRUE
      )
    }
  }
  rows
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
usage <- function() {
  cat(
    "Usage:\n",
    "  Rscript phenotype_library/scripts/check_overlap.R --concept-ids <id,id,...>\n",
    "  Rscript phenotype_library/scripts/check_overlap.R --atlas-json <path>\n",
    "  Rscript phenotype_library/scripts/check_overlap.R --entry <existing catalog id>\n"
  )
}

if (length(args) < 2L || !(args[1] %in% c("--concept-ids", "--atlas-json", "--entry"))) {
  usage()
  quit(status = 1)
}

if (!requireNamespace("yaml", quietly = TRUE)) {
  stop("Package 'yaml' is required. Install with: renv::install('yaml')")
}

catalog_path <- find_catalog()
catalog      <- yaml::read_yaml(catalog_path)
# Search both the legacy embedded entries: phenotype list and the standalone
# concept_sets: registry (schema v1.5+) — a registry item has the same
# id/name/status/concept_sets/exclusion_concept_sets shape as a phenotype
# entry (just without cohort_entry/pl_candidate), so flatten_entry_concepts()
# below handles both identically with no extra wrapping needed.
entries <- c(catalog$entries, catalog$concept_sets %||% list())

if (length(entries) == 0L) {
  cat("[check_overlap] catalog.yaml contains no entries.\n")
  quit(status = 1)
}

label <- NULL
if (args[1] == "--concept-ids") {
  candidate_ids <- suppressWarnings(as.integer(strsplit(args[2], ",")[[1]]))
  if (any(is.na(candidate_ids))) stop("--concept-ids requires a comma-separated list of integers.")
  label <- sprintf("%d supplied concept ID(s)", length(candidate_ids))

} else if (args[1] == "--atlas-json") {
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("Package 'jsonlite' is required. Install with: renv::install('jsonlite')")
  }
  candidate_ids <- parse_atlas_json(args[2])
  if (length(candidate_ids) == 0L) stop("No concept IDs found in ", args[2])
  label <- sprintf("%d concept ID(s) extracted from %s", length(candidate_ids), args[2])

} else if (args[1] == "--entry") {
  target <- Filter(function(e) identical(e$id %||% "", args[2]), entries)
  if (length(target) == 0L) {
    cat(sprintf("[check_overlap] No entry found with id '%s'.\n", args[2]))
    quit(status = 1)
  }
  target_rows   <- flatten_entry_concepts(target[[1L]])
  candidate_ids <- unique(vapply(Filter(function(r) !r$excluded, target_rows), function(r) r$concept_id, integer(1)))
  if (length(candidate_ids) == 0L) stop("Entry '", args[2], "' has no (non-excluded) concept IDs to compare.")
  label <- sprintf("%d concept ID(s) from existing entry '%s'", length(candidate_ids), args[2])
  entries <- Filter(function(e) !identical(e$id %||% "", args[2]), entries)  # don't compare the entry against itself
}

cat(sprintf("[check_overlap] Checking %s against %d catalog entries...\n\n", label, length(entries)))

# ---------------------------------------------------------------------------
# Compute overlap per catalog entry
# ---------------------------------------------------------------------------
results <- list()
for (entry in entries) {
  rows <- flatten_entry_concepts(entry)
  if (length(rows) == 0L) next

  matched_incl <- Filter(function(r) !r$excluded && r$concept_id %in% candidate_ids, rows)
  matched_excl <- Filter(function(r) r$excluded && r$concept_id %in% candidate_ids, rows)

  if (length(matched_incl) == 0L && length(matched_excl) == 0L) next

  n_entry_incl <- length(Filter(function(r) !r$excluded, rows))
  results[[length(results) + 1L]] <- list(
    entry         = entry,
    matched_incl  = matched_incl,
    matched_excl  = matched_excl,
    pct_of_candidate = round(100 * length(matched_incl) / length(candidate_ids), 1),
    pct_of_entry     = if (n_entry_incl > 0) round(100 * length(matched_incl) / n_entry_incl, 1) else NA
  )
}

# Sort by descending overlap count (included matches first)
results <- results[order(-vapply(results, function(r) length(r$matched_incl), integer(1)))]

if (length(results) == 0L) {
  cat("[check_overlap] No existing catalog entry shares any concept ID with the candidate list.\n")
  cat("All", length(candidate_ids), "candidate concept ID(s) appear novel to this catalog.\n")
  cat("Proceed to Tier 3 (live vocab query) before registering a new entry.\n")
  quit(status = 0)
}

for (r in results) {
  e <- r$entry
  cat(sprintf("%-60s [%s]\n", paste0(e$id, " — ", e$name), toupper(e$status %||% "UNKNOWN")))
  cat(strrep("-", 72), "\n")
  if (length(r$matched_incl) > 0) {
    cat(sprintf(
      "  Overlap: %d/%d of candidate list matched (%.1f%%); %.1f%% of this entry's own concept list\n",
      length(r$matched_incl), length(candidate_ids), r$pct_of_candidate, r$pct_of_entry
    ))
    for (m in r$matched_incl) {
      cat(sprintf("    %-10d %s\n", m$concept_id, m$concept_name))
    }
  }
  if (length(r$matched_excl) > 0) {
    cat("  CONFLICT — candidate concept(s) matched an EXCLUSION in this entry:\n")
    for (m in r$matched_excl) {
      cat(sprintf("    %-10d %s  (explicitly excluded here)\n", m$concept_id, m$concept_name))
    }
  }
  cat("\n")
}

unmatched <- setdiff(candidate_ids, unlist(lapply(results, function(r) {
  vapply(c(r$matched_incl, r$matched_excl), function(m) m$concept_id, integer(1))
})))
if (length(unmatched) > 0) {
  cat(sprintf("[check_overlap] %d candidate concept ID(s) matched no existing catalog entry:\n", length(unmatched)))
  cat("  ", paste(unmatched, collapse = ", "), "\n", sep = "")
  cat("These appear novel to this catalog. Proceed to Tier 3 (live vocab query)\n")
  cat("before registering them as a new entry.\n")
}

quit(status = 0)
