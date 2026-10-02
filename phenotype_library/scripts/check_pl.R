#!/usr/bin/env Rscript
# =============================================================================
# phenotype_library/scripts/check_pl.R
#
# PURPOSE
# -------
# Tier 1 of the three-tier phenotype lookup workflow. Searches the OHDSI
# Phenotype Library for published, peer-reviewed phenotypes matching a clinical
# search term. Run this BEFORE searching the local catalog or running a live
# vocabulary query.
#
# USAGE
# -----
#   Rscript phenotype_library/scripts/check_pl.R "<search term>" [max_results]
#
# Examples:
#   Rscript phenotype_library/scripts/check_pl.R "surgical site infection"
#   Rscript phenotype_library/scripts/check_pl.R "peripheral arterial disease" 20
#   Rscript phenotype_library/scripts/check_pl.R "heart failure"
#
# OUTPUTS
# -------
# Prints matching phenotype IDs, names, and descriptions.  Emits a ready-to-paste
# YAML snippet for catalog.yaml if matches are found.
#
# If no match is found, prints the OHDSI PL browser URL.
#
# FALLBACK (no R connection required)
# ------------------------------------
# Browse the full phenotype index online:
#   https://ohdsi.github.io/PhenotypeLibrary/articles/CohortDefinitionsInOhdsiPhenotypeLibrary.html
#
# PACKAGE REQUIREMENT
# -------------------
# PhenotypeLibrary (OHDSI HADES). Install once:
#   renv::install("PhenotypeLibrary")
# After installing, run renv::snapshot() to record it in renv.lock.
# =============================================================================

PL_BROWSER_URL <- paste0(
  "https://ohdsi.github.io/PhenotypeLibrary/articles/",
  "CohortDefinitionsInOhdsiPhenotypeLibrary.html"
)

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
if (length(args) == 0L) {
  cat(
    "Usage: Rscript phenotype_library/scripts/check_pl.R \"<search term>\" [max_results]\n\n",
    "Examples:\n",
    "  Rscript phenotype_library/scripts/check_pl.R \"surgical site infection\"\n",
    "  Rscript phenotype_library/scripts/check_pl.R \"heart failure\" 20\n\n",
    "Browse all phenotypes:\n  ", PL_BROWSER_URL, "\n"
  )
  quit(status = 1)
}

search_term <- args[1]
max_results <- if (length(args) >= 2L) suppressWarnings(as.integer(args[2L])) else 20L
if (is.na(max_results) || max_results < 1L) max_results <- 20L

# ---------------------------------------------------------------------------
# Check PhenotypeLibrary is installed
# ---------------------------------------------------------------------------
if (!requireNamespace("PhenotypeLibrary", quietly = TRUE)) {
  cat(
    "[check_pl] PhenotypeLibrary package is not installed.\n\n",
    "Install it with:\n",
    "  renv::install(\"PhenotypeLibrary\")\n",
    "  renv::snapshot()\n\n",
    "In the meantime, browse phenotypes online:\n",
    "  ", PL_BROWSER_URL, "\n"
  )
  quit(status = 1)
}

# ---------------------------------------------------------------------------
# Fetch phenotype index
# ---------------------------------------------------------------------------
# PhenotypeLibrary::getPhenotypeDescription() returns a data frame with at
# minimum: phenotypeId, cohortName, description.
# getMetaData() is an alternate entry point in some package versions.
# Both are tried here for version compatibility.
# ---------------------------------------------------------------------------
pl_list <- tryCatch(
  {
    if (existsFunction("listPhenotypes", where = asNamespace("PhenotypeLibrary"))) {
      PhenotypeLibrary::listPhenotypes()
    } else if (existsFunction("getPhenotypeDescription", where = asNamespace("PhenotypeLibrary"))) {
      PhenotypeLibrary::getPhenotypeDescription()
    } else {
      # Fallback: attempt getMetaData() which exists in earlier HADES versions
      PhenotypeLibrary::getMetaData()
    }
  },
  error = function(e) {
    cat(
      "[check_pl] Could not retrieve phenotype list: ", conditionMessage(e), "\n",
      "The PhenotypeLibrary API may have changed. Update the package:\n",
      "  renv::update(\"PhenotypeLibrary\")\n\n",
      "Browse phenotypes online:\n  ", PL_BROWSER_URL, "\n"
    )
    quit(status = 1)
  }
)

# Normalise column names — different package versions use different conventions
names(pl_list) <- tolower(gsub("([A-Z])", "_\\1", names(pl_list), perl = TRUE))
names(pl_list) <- sub("^_", "", names(pl_list))

# Identify the columns we need (flexible — handles naming variation)
id_col   <- intersect(names(pl_list), c("phenotype_id", "cohort_id", "id"))[1]
name_col <- intersect(names(pl_list), c("cohort_name", "name", "phenotype_name"))[1]
desc_col <- intersect(names(pl_list), c("description", "desc"))[1]

if (is.na(id_col) || is.na(name_col)) {
  cat(
    "[check_pl] Unexpected column structure in PhenotypeLibrary output.\n",
    "Columns returned: ", paste(names(pl_list), collapse = ", "), "\n",
    "Update phenotype_library/scripts/check_pl.R to handle this version.\n",
    "Browse phenotypes online:\n  ", PL_BROWSER_URL, "\n"
  )
  quit(status = 1)
}

# ---------------------------------------------------------------------------
# Search: match search_term against name and description (case-insensitive)
# ---------------------------------------------------------------------------
name_match <- grepl(search_term, pl_list[[name_col]], ignore.case = TRUE)
desc_match <- if (!is.na(desc_col)) {
  !is.na(pl_list[[desc_col]]) &
    grepl(search_term, pl_list[[desc_col]], ignore.case = TRUE)
} else {
  rep(FALSE, nrow(pl_list))
}

matches <- pl_list[name_match | desc_match, , drop = FALSE]

if (nrow(matches) == 0L) {
  cat(
    "[check_pl] No phenotypes found matching: '", search_term, "'\n\n",
    "Record in catalog.yaml as:\n",
    "  ohdsi_pl_id: ~\n",
    "  ohdsi_pl_checked: \"", format(Sys.Date(), "%Y-%m-%d"), "\"\n\n",
    "Browse all phenotypes:\n  ", PL_BROWSER_URL, "\n"
  )
  quit(status = 0)
}

# Trim to max_results
if (nrow(matches) > max_results) {
  cat("[check_pl]", nrow(matches), "matches found; showing top", max_results,
      "— refine your search term for a shorter list.\n\n")
  matches <- matches[seq_len(max_results), , drop = FALSE]
} else {
  cat("[check_pl]", nrow(matches), "phenotype(s) found for '", search_term, "':\n\n")
}

# ---------------------------------------------------------------------------
# Print results
# ---------------------------------------------------------------------------
for (i in seq_len(nrow(matches))) {
  pl_id   <- matches[[id_col]][i]
  pl_name <- matches[[name_col]][i]
  pl_desc <- if (!is.na(desc_col) && !is.na(matches[[desc_col]][i])) {
    matches[[desc_col]][i]
  } else {
    "(no description)"
  }

  cat(sprintf("  [PL %s] %s\n", pl_id, pl_name))
  # Wrap description at 78 chars
  desc_lines <- strwrap(pl_desc, width = 74, indent = 4, exdent = 4)
  cat(paste(desc_lines, collapse = "\n"), "\n\n")
}

# ---------------------------------------------------------------------------
# Emit YAML snippet for catalog.yaml
# ---------------------------------------------------------------------------
cat("--- To record in catalog.yaml (update ohdsi_pl_id to the best match) ---\n")
cat(sprintf(
  "  ohdsi_pl_id: %s\n  ohdsi_pl_checked: \"%s\"\n",
  matches[[id_col]][1],
  format(Sys.Date(), "%Y-%m-%d")
))
cat("--------------------------------------------------------------------------\n")
cat("Browse full phenotype definitions:\n  ", PL_BROWSER_URL, "\n")
