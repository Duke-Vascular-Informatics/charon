#!/usr/bin/env Rscript
# =============================================================================
# phenotype_library/scripts/fetch_dvi_members.R
#
# PURPOSE
# -------
# Read-only helper for push_dvi_concept_sets.R. Fetches the INCLUDED concept-id
# membership of every existing label-tagged concept set listed in
# dvi_index.yaml and caches it to MEMBERS_CACHE (/tmp/dvi_members.json).
# push_dvi_concept_sets.R uses that cache to skip any catalog entry whose
# concepts are already covered by an existing tagged set (concept-based
# de-duplication).
#
# Excluded concepts (isExcluded == 1) are intentionally dropped so a carve-out
# (e.g. Major Amputation's Syme/Pirogoff exclusions) does not inflate overlap.
#
# USAGE (run from workspace root; re-run whenever dvi_index.yaml is refreshed):
#   Rscript phenotype_library/scripts/fetch_dvi_members.R
#
# REQUIREMENTS: yaml, jsonlite; curl on PATH; network access to ATLAS.
# =============================================================================
suppressWarnings(suppressMessages({ library(yaml); library(jsonlite) }))
`%||%` <- function(x, y) if (is.null(x)) y else x

BASE_URL     <- "https://atlas-demo.ohdsi.org/WebAPI"
MEMBERS_CACHE <- "/tmp/dvi_members.json"

find_workspace_root <- function() {
  for (p in c(getwd(), file.path(getwd(), ".."))) {
    if (file.exists(file.path(p, "phenotype_library", "catalog.yaml"))) return(normalizePath(p))
  }
  stop("Run from the workspace root (where phenotype_library/ lives).")
}

root <- find_workspace_root()
dvi  <- yaml::read_yaml(file.path(root, "phenotype_library", "dvi_index.yaml"))
sets <- dvi$concept_sets %||% list()

out <- list()
for (s in sets) {
  url <- sprintf("%s/conceptset/%d/items", BASE_URL, s$id)
  txt <- tryCatch(paste(system2("curl", c("-s", shQuote(url)), stdout = TRUE), collapse = ""),
                  error = function(e) "")
  items <- tryCatch(fromJSON(txt, simplifyVector = FALSE), error = function(e) list())
  # Only INCLUDED items count as membership.
  items <- Filter(function(it) !isTRUE(as.integer(it$isExcluded %||% 0) == 1), items)
  cids <- sort(unique(vapply(items, function(it) as.integer(it$conceptId %||% NA), integer(1))))
  cids <- cids[!is.na(cids)]
  out[[length(out) + 1]] <- list(id = s$id, name = s$name, concept_ids = cids)
  cat(sprintf("  %-9d %-55s n=%d\n", s$id, s$name, length(cids)))
}
writeLines(toJSON(out, auto_unbox = TRUE), MEMBERS_CACHE)
cat(sprintf("\nWrote membership for %d label-tagged concept sets to %s\n", length(out), MEMBERS_CACHE))
