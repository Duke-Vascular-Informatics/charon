#!/usr/bin/env Rscript
# =============================================================================
# phenotype_library/scripts/lookup_catalog.R
#
# PURPOSE
# -------
# Tier 2 of the three-tier phenotype lookup workflow. Searches the local
# phenotype_library/catalog.yaml for previously verified concept sets. Run this
# after check_pl.R (Tier 1) and before running a live vocabulary query (Tier 3).
#
# USAGE
# -----
#   Rscript phenotype_library/scripts/lookup_catalog.R "<search term>"
#   Rscript phenotype_library/scripts/lookup_catalog.R --concept-id <integer>
#   Rscript phenotype_library/scripts/lookup_catalog.R --study <study-id>
#   Rscript phenotype_library/scripts/lookup_catalog.R --status pending
#   Rscript phenotype_library/scripts/lookup_catalog.R --all
#   Rscript phenotype_library/scripts/lookup_catalog.R --children-of <id>
#   Rscript phenotype_library/scripts/lookup_catalog.R --parent-of <id>
#
# Examples:
#   Rscript phenotype_library/scripts/lookup_catalog.R "bypass"
#   Rscript phenotype_library/scripts/lookup_catalog.R "diabetes"
#   Rscript phenotype_library/scripts/lookup_catalog.R --concept-id 4236706
#   Rscript phenotype_library/scripts/lookup_catalog.R --study my-study-desc
#   Rscript phenotype_library/scripts/lookup_catalog.R --status pending
#   Rscript phenotype_library/scripts/lookup_catalog.R --children-of oler_procedure
#   Rscript phenotype_library/scripts/lookup_catalog.R --parent-of oler_procedure_subtypes
#
# OUTPUT
# ------
# Matching catalog entries with concept IDs, status, hierarchy, and usage.
# Exits with code 0 (found) or 1 (not found / error).
#
# REQUIREMENTS
# ------------
# yaml package. Install once: renv::install("yaml")
# =============================================================================

# ---------------------------------------------------------------------------
# Locate catalog.yaml relative to the script or working directory
# ---------------------------------------------------------------------------
find_catalog <- function() {
  # Try paths in order of likelihood
  candidates <- c(
    file.path(getwd(), "phenotype_library", "catalog.yaml"),
    file.path(dirname(dirname(sys.frame(1)$ofile %||% "")), "catalog.yaml"),
    "catalog.yaml"
  )
  for (p in candidates) {
    if (!is.na(p) && nchar(p) > 0 && file.exists(p)) return(p)
  }
  stop(
    "catalog.yaml not found. Run this script from the workspace root:\n",
    "  Rscript phenotype_library/scripts/lookup_catalog.R \"<term>\"\n"
  )
}

`%||%` <- function(x, y) if (is.null(x)) y else x

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
if (length(args) == 0L) {
  cat(
    "Usage:\n",
    "  Rscript phenotype_library/scripts/lookup_catalog.R \"<search term>\"\n",
    "  Rscript phenotype_library/scripts/lookup_catalog.R --concept-id <integer>\n",
    "  Rscript phenotype_library/scripts/lookup_catalog.R --study <study-id>\n",
    "  Rscript phenotype_library/scripts/lookup_catalog.R --status pending\n",
    "  Rscript phenotype_library/scripts/lookup_catalog.R --all\n",
    "  Rscript phenotype_library/scripts/lookup_catalog.R --children-of <id>\n",
    "  Rscript phenotype_library/scripts/lookup_catalog.R --parent-of <id>\n"
  )
  quit(status = 1)
}

mode         <- "text"
search_value <- NULL

if (args[1] == "--concept-id" && length(args) >= 2L) {
  mode         <- "concept_id"
  search_value <- suppressWarnings(as.integer(args[2L]))
  if (is.na(search_value)) stop("--concept-id requires an integer argument.")
} else if (args[1] == "--study" && length(args) >= 2L) {
  mode         <- "study"
  search_value <- args[2L]
} else if (args[1] == "--status" && length(args) >= 2L) {
  mode         <- "status"
  search_value <- tolower(args[2L])
} else if (args[1] == "--children-of" && length(args) >= 2L) {
  mode         <- "children_of"
  search_value <- args[2L]
} else if (args[1] == "--parent-of" && length(args) >= 2L) {
  mode         <- "parent_of"
  search_value <- args[2L]
} else if (args[1] == "--all") {
  mode <- "all"
} else {
  search_value <- args[1]
}

# ---------------------------------------------------------------------------
# Load catalog
# ---------------------------------------------------------------------------
if (!requireNamespace("yaml", quietly = TRUE)) {
  stop("Package 'yaml' is required. Install with: renv::install('yaml')")
}

catalog_path <- find_catalog()
catalog      <- yaml::read_yaml(catalog_path)
# Search both the legacy embedded entries: phenotype list and the standalone
# concept_sets: registry (schema v1.5+) — a registry item shares the same
# id/name/status/concept_sets shape as a phenotype entry, so no special
# casing is needed here (see catalog.yaml's CONCEPT_SETS REGISTRY comment).
entries      <- c(catalog$entries, catalog$concept_sets %||% list())

if (length(entries) == 0L) {
  cat("[lookup_catalog] catalog.yaml contains no entries.\n")
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
      grepl(term, tolower(e$id %||% ""),          fixed = TRUE) ||
      grepl(term, tolower(e$name %||% ""),        fixed = TRUE) ||
      grepl(term, tolower(e$description %||% ""), fixed = TRUE) ||
      grepl(term, tolower(e$domain %||% ""),      fixed = TRUE) ||
      any(vapply(e$concept_sets %||% list(), function(cs) {
        grepl(term, tolower(cs$concept_name %||% ""), fixed = TRUE)
      }, logical(1)))
    }, entries)
  },

  concept_id = {
    Filter(function(e) {
      any(vapply(
        c(e$concept_sets %||% list(), e$exclusion_concept_sets %||% list()),
        function(cs) identical(as.integer(cs$concept_id %||% NA), search_value),
        logical(1)
      ))
    }, entries)
  },

  study = {
    Filter(function(e) {
      any(vapply(e$used_by %||% list(), function(u) {
        grepl(search_value, u$study_id %||% "", ignore.case = TRUE)
      }, logical(1)))
    }, entries)
  },

  status = {
    Filter(function(e) {
      tolower(e$status %||% "") == search_value
    }, entries)
  },

  # Return all direct children of the given parent id (an entry is a child if
  # search_value appears anywhere in its parent_ids list — an entry may have
  # more than one parent, e.g. ischemic_heart_disease belongs to both
  # macce_composite and va_frailty_index)
  children_of = {
    Filter(function(e) {
      search_value %in% (e$parent_ids %||% character(0))
    }, entries)
  },

  # Return all parent entries of the given child id (a child may have more
  # than one parent_ids entry), then also the child itself so the caller sees
  # both sides of the relationship.
  parent_of = {
    # Find the target entry to get its parent_ids
    target <- Filter(function(e) identical(e$id %||% "", search_value), entries)
    if (length(target) == 0L) {
      cat(sprintf("[lookup_catalog] No entry found with id '%s'.\n", search_value))
      quit(status = 1)
    }
    pids <- target[[1L]]$parent_ids %||% NULL
    if (is.null(pids) || length(pids) == 0L) {
      cat(sprintf("[lookup_catalog] '%s' has no parent_ids — it is a top-level entry.\n",
                  search_value))
      quit(status = 0)
    }
    Filter(function(e) (e$id %||% "") %in% pids, entries)
  },

  all = entries
)

# ---------------------------------------------------------------------------
# Print results
# ---------------------------------------------------------------------------
if (length(matches) == 0L) {
  cat("[lookup_catalog] No entries found")
  if (!is.null(search_value)) cat(" matching: '", search_value, "'", sep = "")
  cat("\n\n")
  if (mode %in% c("children_of", "parent_of")) {
    cat("Check the id spelling — ids are snake_case (e.g. oler_procedure).\n")
  } else {
    cat("Run check_pl.R to search the OHDSI Phenotype Library (Tier 1).\n")
    cat("If not found there either, run a live vocabulary query (Tier 3).\n")
    cat("Then add the new entry to phenotype_library/catalog.yaml.\n")
  }
  quit(status = 1)
}

cat(sprintf("[lookup_catalog] %d entry/entries found:\n\n", length(matches)))

for (entry in matches) {
  # Header
  status_tag <- toupper(entry$status %||% "UNKNOWN")
  cat(sprintf("%-60s [%s]\n", paste0(entry$id, " — ", entry$name), status_tag))
  cat(strrep("-", 72), "\n")

  # Domain and OHDSI PL
  cat(sprintf("  Domain   : %s\n", entry$domain %||% "—"))
  pl_id <- entry$ohdsi_pl_id %||% "not checked"
  pl_dt <- entry$ohdsi_pl_checked %||% "—"
  cat(sprintf("  OHDSI PL : %s (checked: %s)\n", pl_id, pl_dt))

  # Hierarchy relationships
  parent_ids   <- entry$parent_ids %||% character(0)
  subgroup_ids <- entry$subgroup_ids %||% list()
  if (length(parent_ids) > 0L || length(subgroup_ids) > 0L) {
    cat("\n  Hierarchy:\n")
    if (length(parent_ids) > 0L) {
      for (pid in parent_ids) {
        cat(sprintf("    Parent   : %s  (run --parent-of %s to view)\n",
                    pid, entry$id %||% ""))
      }
    }
    if (length(subgroup_ids) > 0L) {
      for (sid in subgroup_ids) {
        cat(sprintf("    Child    : %s  (run --children-of %s to view all)\n",
                    sid, entry$id %||% ""))
      }
    }
  }

  # Description (wrapped)
  if (!is.null(entry$description) && nchar(trimws(entry$description)) > 0) {
    desc_lines <- strwrap(trimws(entry$description), width = 68, indent = 2, exdent = 2)
    cat("\n", paste(desc_lines, collapse = "\n"), "\n", sep = "")
  }

  # Concept sets
  csets <- entry$concept_sets %||% list()
  if (length(csets) > 0L) {
    cat("\n  Concept sets:\n")
    for (cs in csets) {
      cid   <- cs$concept_id %||% "PENDING"
      cname <- cs$concept_name %||% ""
      vocab <- cs$vocabulary %||% ""
      desc  <- cs$include_descendants %||% FALSE
      role  <- if (!is.null(cs$concept_role)) paste0(" [", cs$concept_role, "]") else ""
      vdate <- cs$vocab_query_date %||% "not verified"
      status_flag <- if (is.null(cs$concept_id) || is.na(cs$concept_id)) " *** PENDING ***" else ""
      cat(sprintf(
        "    %-10s %-45s %-8s desc=%-5s%s  verified:%s%s\n",
        cid, cname, vocab, desc, role, vdate, status_flag
      ))
    }
  } else {
    cat("\n  Concept sets: (none — grouping entry or visit-based outcome)\n")
  }

  # Exclusion concept sets
  excl <- entry$exclusion_concept_sets %||% list()
  if (length(excl) > 0L) {
    cat("\n  Exclusion concept sets:\n")
    for (cs in excl) {
      cid   <- cs$concept_id %||% "PENDING"
      cname <- cs$concept_name %||% ""
      vocab <- cs$vocabulary %||% ""
      vdate <- cs$vocab_query_date %||% "not verified"
      cat(sprintf("    %-10s %-45s %-8s  verified:%s\n", cid, cname, vocab, vdate))
    }
  }

  # Usage
  usage <- entry$used_by %||% list()
  if (length(usage) > 0L) {
    cat("\n  Used by:\n")
    for (u in usage) {
      cat(sprintf("    %-35s role: %s\n", u$study_id %||% "—", u$role %||% "—"))
    }
  }

  # Notes
  if (!is.null(entry$notes) && nchar(trimws(entry$notes)) > 0) {
    cat("\n  Notes:\n")
    note_lines <- strwrap(trimws(entry$notes), width = 68, indent = 4, exdent = 4)
    cat(paste(note_lines, collapse = "\n"), "\n")
  }

  cat("\n")
}

# If any pending entries were returned, remind the analyst
pending_count <- sum(vapply(matches, function(e) {
  (e$status %||% "") == "pending"
}, logical(1)))

if (pending_count > 0L) {
  cat(sprintf(
    "[lookup_catalog] %d entry/entries are PENDING — concept IDs not yet verified.\n",
    pending_count
  ))
  cat("Run a live vocabulary query before using these IDs in study code.\n\n")
}

quit(status = 0)
