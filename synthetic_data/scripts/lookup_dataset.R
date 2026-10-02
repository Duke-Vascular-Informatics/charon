#!/usr/bin/env Rscript
# =============================================================================
# synthetic_data/scripts/lookup_dataset.R
#
# PURPOSE
# -------
# Search synthetic_data/registry.yaml for a reusable synthetic OMOP CDM
# dataset before running your own Synthea generation from scratch. If a
# (gitignored) synthetic_data/local_schemas.yaml exists on this machine,
# matches are annotated with same-machine availability.
#
# USAGE
# -----
#   Rscript synthetic_data/scripts/lookup_dataset.R "<search term>"
#   Rscript synthetic_data/scripts/lookup_dataset.R --disease "<term>"
#   Rscript synthetic_data/scripts/lookup_dataset.R --procedure "<term>"
#   Rscript synthetic_data/scripts/lookup_dataset.R --study <repo-name>
#   Rscript synthetic_data/scripts/lookup_dataset.R --status verified
#   Rscript synthetic_data/scripts/lookup_dataset.R --all
#
# Examples:
#   Rscript synthetic_data/scripts/lookup_dataset.R "peripheral arterial disease"
#   Rscript synthetic_data/scripts/lookup_dataset.R --procedure "amputation"
#   Rscript synthetic_data/scripts/lookup_dataset.R --study my-study-desc
#
# OUTPUT
# ------
# Matching registry entries with disease/procedure/outcome coverage, generation
# recipe, download availability, and local-schema availability (if known).
# Exits with code 0 (found) or 1 (not found / error).
#
# REQUIREMENTS
# ------------
# yaml package. Install once: renv::install("yaml")
# =============================================================================

`%||%` <- function(x, y) if (is.null(x)) y else x

find_file <- function(relative_path) {
  candidates <- c(
    file.path(getwd(), relative_path),
    relative_path
  )
  for (p in candidates) {
    if (!is.na(p) && nchar(p) > 0 && file.exists(p)) return(p)
  }
  NA_character_
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
if (length(args) == 0L) {
  cat(
    "Usage:\n",
    "  Rscript synthetic_data/scripts/lookup_dataset.R \"<search term>\"\n",
    "  Rscript synthetic_data/scripts/lookup_dataset.R --disease \"<term>\"\n",
    "  Rscript synthetic_data/scripts/lookup_dataset.R --procedure \"<term>\"\n",
    "  Rscript synthetic_data/scripts/lookup_dataset.R --study <repo-name>\n",
    "  Rscript synthetic_data/scripts/lookup_dataset.R --status verified\n",
    "  Rscript synthetic_data/scripts/lookup_dataset.R --all\n"
  )
  quit(status = 1)
}

mode         <- "text"
search_value <- NULL

if (args[1] == "--disease" && length(args) >= 2L) {
  mode         <- "disease"
  search_value <- args[2L]
} else if (args[1] == "--procedure" && length(args) >= 2L) {
  mode         <- "procedure"
  search_value <- args[2L]
} else if (args[1] == "--study" && length(args) >= 2L) {
  mode         <- "study"
  search_value <- args[2L]
} else if (args[1] == "--status" && length(args) >= 2L) {
  mode         <- "status"
  search_value <- tolower(args[2L])
} else if (args[1] == "--all") {
  mode <- "all"
} else {
  search_value <- args[1]
}

# ---------------------------------------------------------------------------
# Load registry (+ optional local cache)
# ---------------------------------------------------------------------------
if (!requireNamespace("yaml", quietly = TRUE)) {
  stop("Package 'yaml' is required. Install with: renv::install('yaml')")
}

registry_path <- find_file("synthetic_data/registry.yaml")
if (is.na(registry_path)) {
  stop(
    "registry.yaml not found. Run this script from the workspace root:\n",
    "  Rscript synthetic_data/scripts/lookup_dataset.R --all\n"
  )
}

registry <- yaml::read_yaml(registry_path)
entries  <- registry$datasets

local_path <- find_file("synthetic_data/local_schemas.yaml")
local_cache <- if (!is.na(local_path)) yaml::read_yaml(local_path) else NULL

populated_lookup <- new.env()
if (!is.null(local_cache)) {
  for (p in local_cache$populated %||% list()) {
    assign(p$registry_id, p$cdm_schema, envir = populated_lookup)
  }
}
overlay_lookup <- new.env()
if (!is.null(local_cache)) {
  for (o in local_cache$overlays %||% list()) {
    existing <- mget(o$registry_id, envir = overlay_lookup, ifnotfound = list(character(0)))[[1]]
    assign(o$registry_id, c(existing, o$overlay_schema), envir = overlay_lookup)
  }
}

if (length(entries) == 0L) {
  cat("[lookup_dataset] registry.yaml contains no entries.\n")
  quit(status = 1)
}

# ---------------------------------------------------------------------------
# Match entries
# ---------------------------------------------------------------------------
matches <- switch(
  mode,

  text = {
    term <- tolower(search_value)
    Filter(function(e) {
      grepl(term, tolower(e$id %||% ""),        fixed = TRUE) ||
      # Former ids are searchable so a rename does not make a dataset
      # undiscoverable by the name someone remembers, or by the name still
      # hard-coded in a consumer repo (pad_amp_ed -> pad_amp_dispo -> pad_amp).
      any(vapply(unlist(e$former_ids %||% e$former_id %||% list()), function(fid) {
        grepl(term, tolower(fid %||% ""), fixed = TRUE)
      }, logical(1))) ||
      grepl(term, tolower(e$disease %||% ""),   fixed = TRUE) ||
      grepl(term, tolower(e$procedure %||% ""), fixed = TRUE) ||
      any(vapply(e$outcomes_present %||% list(), function(o) {
        grepl(term, tolower(o %||% ""), fixed = TRUE)
      }, logical(1)))
    }, entries)
  },

  disease = {
    term <- tolower(search_value)
    Filter(function(e) grepl(term, tolower(e$disease %||% ""), fixed = TRUE), entries)
  },

  procedure = {
    term <- tolower(search_value)
    Filter(function(e) grepl(term, tolower(e$procedure %||% ""), fixed = TRUE), entries)
  },

  study = {
    Filter(function(e) {
      search_value %in% (e$used_by %||% character(0)) ||
        identical(e$source_repo %||% "", search_value)
    }, entries)
  },

  status = {
    Filter(function(e) tolower(e$status %||% "") == search_value, entries)
  },

  all = entries
)

# ---------------------------------------------------------------------------
# Print results
# ---------------------------------------------------------------------------
if (length(matches) == 0L) {
  cat("[lookup_dataset] No entries found")
  if (!is.null(search_value)) cat(" matching: '", search_value, "'", sep = "")
  cat("\n\n")
  cat("If no dataset covers this disease/procedure/outcome combination yet, generate\n")
  cat("one via that study's own Steps 3-5, then register it in registry.yaml.\n")
  cat("See synthetic_data/README.md for the full workflow.\n")
  quit(status = 1)
}

cat(sprintf("[lookup_dataset] %d entry/entries found:\n\n", length(matches)))

for (entry in matches) {
  status_tag <- toupper(entry$status %||% "UNKNOWN")
  cat(sprintf("%-55s [%s]\n", entry$id, status_tag))
  cat(strrep("-", 72), "\n")

  cat(sprintf("  Source repo : %s\n", entry$source_repo %||% "—"))
  cat(sprintf("  Disease     : %s\n", entry$disease %||% "—"))
  cat(sprintf("  Procedure   : %s\n", entry$procedure %||% "—"))

  outcomes <- entry$outcomes_present %||% list()
  if (length(outcomes) > 0L) {
    cat("  Outcomes    :\n")
    for (o in outcomes) cat(sprintf("      - %s\n", o))
  }

  cat(sprintf("  Recipe      : %s\n", entry$synthea_module_path %||% "—"))
  gp <- entry$generation_params %||% list()
  if (length(gp) > 0L) {
    cat(sprintf(
      "  Params      : population=%s, age_range=%s, state=%s, seed=%s\n",
      gp$population %||% "?", gp$age_range %||% "?", gp$state %||% "?", gp$seed %||% "none"
    ))
  }

  # Two registry shapes are supported on purpose.
  #
  #   versions:        introduced 2026-08-06 for datasets extended across several
  #                    analytic use cases. Regeneration creates a NEW version in a
  #                    NEW physical schema rather than mutating one that consumers
  #                    are pinned to. `pad_amp` uses this.
  #   last_generated:  the original single-build shape, still used by every other
  #                    dataset. Regeneration replaces in place.
  #
  # Read `versions` when present and fall back otherwise, so adopting the new
  # shape is per-dataset and needs no migration of the rest of the registry.
  versions <- entry$versions %||% list()
  if (length(versions) > 0L) {
    cat(sprintf("  Versions    : %d (newest last)\n", length(versions)))
    for (v in versions) {
      pinned <- v$pinned_consumers %||% list()
      cat(sprintf("      %-5s %-11s schema=%-28s built=%s\n",
                  v$version %||% "?",
                  paste0("[", toupper(v$status %||% "unknown"), "]"),
                  v$physical_schema %||% "—",
                  v$date %||% "unknown"))
      cat(sprintf("            pinned consumers: %s\n",
                  if (length(pinned) > 0L) paste(unlist(pinned), collapse = ", ")
                  else "none — safe to regenerate"))
    }
    cat("  NOTE        : never mutate a version with pinned consumers; add a new one.\n")
  } else {
    lg <- entry$last_generated %||% list()
    cat(sprintf("  Last built  : %s (population_actual=%s)\n",
                lg$date %||% "unknown", lg$population_actual %||% "unknown"))
    cat("  NOTE        : unversioned — regeneration REPLACES this dataset in place.\n")
  }

  # Download availability. A VERSIONED dataset carries a `download:` block inside
  # each version, because a dataset-level block cannot say which version an asset
  # corresponds to. Fall back to the dataset level for unversioned entries.
  # is.list() guards against a scalar being placed here by hand — that used to
  # abort the whole lookup with "$ operator is invalid for atomic vectors".
  fmt_download <- function(dl, label) {
    if (is.null(dl) || !is.list(dl)) return(invisible(NULL))
    flag <- if (isTRUE(dl$stale)) "  [STALE — DO NOT USE]" else ""
    sup  <- if (!is.null(dl$superseded_by)) sprintf("  superseded by %s", dl$superseded_by) else ""
    cat(sprintf("  Download %-4s: %s / %s%s%s\n", label,
                dl$github_release %||% "—", dl$asset %||% "—", flag, sup))
  }
  versions <- entry$versions %||% list()
  any_dl <- FALSE
  if (length(versions) > 0L) {
    for (v in versions) {
      if (is.list(v$download)) { fmt_download(v$download, v$version %||% "?"); any_dl <- TRUE }
    }
  }
  if (!any_dl) {
    dl <- entry$download
    if (is.list(dl)) { fmt_download(dl, ""); any_dl <- TRUE }
  }
  if (!any_dl) {
    cat("  Download    : not published — regenerate from recipe (see README §2)\n")
  }

  local_schema <- mget(entry$id, envir = populated_lookup, ifnotfound = list(NULL))[[1]]
  if (!is.null(local_schema)) {
    cat(sprintf("  ** Already populated on THIS machine as: %s **\n", local_schema))
  }
  local_overlays <- mget(entry$id, envir = overlay_lookup, ifnotfound = list(character(0)))[[1]]
  if (length(local_overlays) > 0L) {
    cat(sprintf("  ** Overlay schema(s) on THIS machine: %s **\n",
                paste(local_overlays, collapse = ", ")))
  }

  usage <- entry$used_by %||% list()
  if (length(usage) > 0L) {
    cat(sprintf("  Used by     : %s\n", paste(usage, collapse = ", ")))
  }

  if (!is.null(entry$notes) && nchar(trimws(entry$notes)) > 0) {
    note_lines <- strwrap(trimws(entry$notes), width = 68, indent = 4, exdent = 4)
    cat("  Notes:\n", paste(note_lines, collapse = "\n"), "\n", sep = "")
  }

  cat("\n")
}

pending_count <- sum(vapply(matches, function(e) (e$status %||% "") %in% c("pending", "stale", "needs_regeneration"), logical(1)))
if (pending_count > 0L) {
  cat(sprintf(
    "[lookup_dataset] %d entry/entries are not verified/current — confirm before relying on them.\n\n",
    pending_count
  ))
}

quit(status = 0)
