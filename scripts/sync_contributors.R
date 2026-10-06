#!/usr/bin/env Rscript
# =============================================================================
# scripts/sync_contributors.R
#
# PURPOSE
# -------
# Single source-of-truth sync for contributor attribution across the workspace.
# Reads contributors.yaml and writes three outputs:
#
#   1. CONTRIBUTORS.md (workspace root) — human-readable table of all
#      contributors with affiliations and per-repo CRediT roles.
#
#   2. CITATION.cff (workspace root) — updates the `authors:` block only.
#      All other CITATION.cff fields are preserved exactly as written.
#
#   3. CONTRIBUTORS.md (each study/ETL repo) — filtered to only the
#      contributors assigned to that repo (via explicit repo name or "*").
#      Written to <workspace_root>/<repo_dir>/CONTRIBUTORS.md.
#
# Run this script whenever contributors.yaml changes (new contributor, role
# update, affiliation change). Never edit CONTRIBUTORS.md or the authors block
# of CITATION.cff by hand — those are generated and will be overwritten.
#
# Optional per-contributor field `cff_author: false` keeps someone in
# CONTRIBUTORS.md but omits them from CITATION.cff's authors (e.g. early
# testers who gave feedback but did not author the software). Default: included.
#
# USAGE
# -----
#   Rscript scripts/sync_contributors.R            # normal run
#   Rscript scripts/sync_contributors.R --dry-run  # print diffs, write nothing
#
# INPUTS
# ------
#   contributors.yaml   — contributor registry (workspace root)
#   CITATION.cff        — existing citation metadata (workspace root)
#   studies.yaml         — registry of study/ETL repo dirs (derives the per-repo list)
#
# OUTPUTS
# -------
#   CONTRIBUTORS.md                  — regenerated (workspace root)
#   CITATION.cff                     — authors block replaced, all other fields unchanged
#   <repo_dir>/CONTRIBUTORS.md       — regenerated for each known study/ETL repo
#
# REQUIREMENTS
# ------------
#   yaml   — CRAN; install once: renv::install("yaml")
#
# CRediT TAXONOMY
# ---------------
#   https://credit.niso.org/
#   14 standardised roles:
#     conceptualization, methodology, software, validation, formal-analysis,
#     investigation, data-curation, writing-original-draft,
#     writing-review-editing, visualization, supervision,
#     project-administration, funding-acquisition, resources
# =============================================================================

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0L) y else x

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
args     <- commandArgs(trailingOnly = TRUE)
dry_run  <- "--dry-run" %in% args

if (dry_run) {
  cat("[sync_contributors] DRY RUN — no files will be written.\n\n")
}

# ---------------------------------------------------------------------------
# Locate workspace root
# ---------------------------------------------------------------------------
# Support running from any working directory: walk up from the script location
# until we find contributors.yaml, or fall back to getwd().
find_workspace_root <- function() {
  # Primary: derive from --file argument Rscript passes when called by path
  # e.g. Rscript /path/to/scripts/sync_contributors.R
  all_args    <- commandArgs(trailingOnly = FALSE)
  file_flag   <- grep("^--file=", all_args, value = TRUE)
  script_path <- if (length(file_flag) > 0L) {
    normalizePath(sub("^--file=", "", file_flag[1L]), mustWork = FALSE)
  } else {
    ""
  }

  candidates <- c(
    if (nchar(script_path) > 0L) dirname(dirname(script_path)) else NULL,
    getwd(),
    normalizePath(".")
  )
  for (p in candidates[!vapply(candidates, is.null, logical(1))]) {
    if (nchar(p) > 0L && file.exists(file.path(p, "contributors.yaml"))) {
      return(normalizePath(p))
    }
  }
  stop(
    "contributors.yaml not found. Run this script from the workspace root:\n",
    "  Rscript scripts/sync_contributors.R\n"
  )
}

root <- find_workspace_root()
cat(sprintf("[sync_contributors] Workspace root: %s\n\n", root))

contributors_path <- file.path(root, "contributors.yaml")
citation_path     <- file.path(root, "CITATION.cff")
md_out_path       <- file.path(root, "CONTRIBUTORS.md")

# ---------------------------------------------------------------------------
# Load yaml dependency
# ---------------------------------------------------------------------------
if (!requireNamespace("yaml", quietly = TRUE)) {
  stop("Package 'yaml' is required. Install with: renv::install('yaml')")
}

# ---------------------------------------------------------------------------
# Read contributors.yaml
# ---------------------------------------------------------------------------
raw        <- yaml::read_yaml(contributors_path)
contribs   <- raw$contributors %||% list()

if (length(contribs) == 0L) {
  stop("contributors.yaml contains no entries under 'contributors:'.")
}

cat(sprintf("[sync_contributors] Loaded %d contributor(s).\n\n", length(contribs)))

# ---------------------------------------------------------------------------
# Helper: pretty-print a CRediT role slug as a display label
# e.g. "writing-original-draft" -> "Writing – original draft"
# ---------------------------------------------------------------------------
credit_label <- function(slug) {
  display <- list(
    "conceptualization"       = "Conceptualization",
    "methodology"             = "Methodology",
    "software"                = "Software",
    "validation"              = "Validation",
    "formal-analysis"         = "Formal analysis",
    "investigation"           = "Investigation",
    "data-curation"           = "Data curation",
    "writing-original-draft"  = "Writing – original draft",
    "writing-review-editing"  = "Writing – review & editing",
    "visualization"           = "Visualization",
    "supervision"             = "Supervision",
    "project-administration"  = "Project administration",
    "funding-acquisition"     = "Funding acquisition",
    "resources"               = "Resources"
  )
  display[[slug]] %||% slug  # fall back to raw slug if unrecognised
}

# ---------------------------------------------------------------------------
# Helper: collect CRediT roles for one contributor + one repo
# Merges wildcard ("*") roles with repo-specific roles, deduplicating.
# ---------------------------------------------------------------------------
roles_for_repo <- function(contrib, repo_name) {
  all_roles <- character(0L)
  for (r in contrib$repos %||% list()) {
    target <- r$repo %||% ""
    if (target == "*" || target == repo_name) {
      all_roles <- union(all_roles, r$credit %||% character(0L))
    }
  }
  all_roles
}

# ---------------------------------------------------------------------------
# Helper: collect all repos a contributor is assigned to
# (expanding "*" is deferred — we only list explicitly named repos here,
# plus a note if a wildcard is present)
# ---------------------------------------------------------------------------
named_repos_for <- function(contrib) {
  repos <- character(0L)
  for (r in contrib$repos %||% list()) {
    target <- r$repo %||% ""
    if (target != "*") repos <- c(repos, target)
  }
  unique(repos)
}

has_wildcard <- function(contrib) {
  any(vapply(contrib$repos %||% list(), function(r) {
    identical(r$repo %||% "", "*")
  }, logical(1)))
}

# ---------------------------------------------------------------------------
# Known study and ETL repos — derived from studies.yaml's `studies:` and
# `etls:` entries (their `dir:` field), not hardcoded, so a newly registered
# study automatically gets a per-repo CONTRIBUTORS.md the next time this
# script runs. `templates:` entries are intentionally excluded — those are
# shared, generic template repos (git submodules in this workspace) and must
# never receive a lab-specific CONTRIBUTORS.md.
# ---------------------------------------------------------------------------
studies_path <- file.path(root, "studies.yaml")
if (!file.exists(studies_path)) {
  stop(sprintf(
    "studies.yaml not found at: %s\nThis script derives its per-repo list from it.",
    studies_path
  ))
}
studies_raw <- yaml::read_yaml(studies_path)

dirs_from_section <- function(section_name) {
  entries <- studies_raw[[section_name]] %||% list()
  vapply(entries, function(e) e$dir %||% NA_character_, character(1L))
}

STUDY_REPOS <- unique(c(dirs_from_section("studies"), dirs_from_section("etls")))
STUDY_REPOS <- STUDY_REPOS[!is.na(STUDY_REPOS)]

cat(sprintf(
  "[sync_contributors] %d repo(s) registered in studies.yaml (studies + etls).\n\n",
  length(STUDY_REPOS)
))

# ---------------------------------------------------------------------------
# Build CONTRIBUTORS.md content
# ---------------------------------------------------------------------------
build_contributors_md <- function(contribs) {
  lines <- c(
    "# Contributors",
    "",
    paste0(
      "This file is generated from [`contributors.yaml`](contributors.yaml). ",
      "To update it, edit `contributors.yaml` and run ",
      "`Rscript scripts/sync_contributors.R`."
    ),
    "",
    "CRediT roles follow the [NISO CRediT taxonomy](https://credit.niso.org/).",
    "",
    "---",
    ""
  )

  for (contrib in contribs) {
    # --- Name heading ---
    full_name <- paste(
      contrib$given_names %||% "",
      contrib$family_names %||% ""
    )
    suffix <- contrib$name_suffix %||% NULL
    if (!is.null(suffix)) full_name <- paste0(full_name, ", ", suffix)

    lines <- c(lines, paste0("## ", trimws(full_name)), "")

    # --- Affiliations ---
    affiliations <- contrib$affiliations %||% list()
    if (length(affiliations) > 0L) {
      lines <- c(lines, "**Affiliations:**")
      for (aff in affiliations) {
        aff_str <- aff$name %||% ""
        loc_parts <- c(aff$city, aff$region, aff$country)
        loc_parts <- loc_parts[!vapply(loc_parts, is.null, logical(1))]
        if (length(loc_parts) > 0L) {
          aff_str <- paste0(aff_str, ", ", paste(loc_parts, collapse = ", "))
        }
        lines <- c(lines, paste0("- ", aff_str))
      }
      lines <- c(lines, "")
    }

    # --- Contact + ORCID ---
    email <- contrib$email %||% NULL
    orcid <- contrib$orcid %||% NULL
    if (!is.null(email)) {
      lines <- c(lines, paste0("**Contact:** ", email, "  "))
    }
    if (!is.null(orcid)) {
      lines <- c(lines, paste0("**ORCID:** ", orcid))
    }
    lines <- c(lines, "")

    # --- Wildcard (all-repo) roles ---
    wildcard_roles <- character(0L)
    for (r in contrib$repos %||% list()) {
      if (identical(r$repo %||% "", "*")) {
        wildcard_roles <- union(wildcard_roles, r$credit %||% character(0L))
      }
    }
    if (length(wildcard_roles) > 0L) {
      role_str <- paste(vapply(wildcard_roles, credit_label, character(1L)),
                        collapse = " · ")
      lines <- c(lines,
                 paste0("**CRediT roles (all repos):** ", role_str),
                 "")
    }

    # --- Per-repo additional roles ---
    named_repos <- named_repos_for(contrib)
    if (length(named_repos) > 0L) {
      lines <- c(lines, "**Additional roles by study:**", "")
      lines <- c(lines, "| Repo | Roles |", "|---|---|")
      for (repo in named_repos) {
        # Only the roles not already covered by the wildcard
        all_r  <- roles_for_repo(contrib, repo)
        extra  <- setdiff(all_r, wildcard_roles)
        if (length(extra) > 0L) {
          role_str <- paste(vapply(extra, credit_label, character(1L)),
                            collapse = " · ")
          lines <- c(lines, sprintf("| %s | %s |", repo, role_str))
        }
      }
      lines <- c(lines, "")
    }

    lines <- c(lines, "---", "")
  }

  # Remove trailing separator
  if (length(lines) >= 2L &&
      lines[length(lines)]     == "" &&
      lines[length(lines) - 1L] == "---") {
    lines <- lines[seq_len(length(lines) - 2L)]
  }

  paste(lines, collapse = "\n")
}

# ---------------------------------------------------------------------------
# Build the CITATION.cff authors block as a character vector of lines
# ---------------------------------------------------------------------------
build_cff_authors_block <- function(contribs) {
  # yaml::as.yaml() adds a trailing newline; strip it with trimws().
  cff_str <- function(x) trimws(yaml::as.yaml(x), which = "right")

  # A contributor with `cff_author: false` stays in CONTRIBUTORS.md but is left
  # out of CITATION.cff's authors (and so out of Zenodo's creators) — for people
  # who gave feedback/testing rather than authoring the software. Absent = TRUE.
  contribs <- Filter(function(c) !identical(c$cff_author, FALSE), contribs)
  if (length(contribs) == 0L) {
    stop("Every contributor has cff_author: false — CITATION.cff needs at least one author.")
  }

  lines <- c("authors:")
  for (contrib in contribs) {
    # Each contributor appears once; primary affiliation = first in list.
    primary_aff <- (contrib$affiliations %||% list())[[1L]]
    aff_name    <- if (!is.null(primary_aff)) primary_aff$name %||% NULL else NULL

    lines <- c(lines,
      sprintf("  - family-names: %s", cff_str(contrib$family_names %||% "")),
      sprintf("    given-names: %s",  cff_str(contrib$given_names  %||% ""))
    )

    suffix <- contrib$name_suffix %||% NULL
    if (!is.null(suffix)) {
      lines <- c(lines, sprintf("    name-suffix: %s", cff_str(suffix)))
    }

    email <- contrib$email %||% NULL
    if (!is.null(email)) {
      lines <- c(lines, sprintf("    email: %s", email))
    }

    orcid <- contrib$orcid %||% NULL
    if (!is.null(orcid)) {
      lines <- c(lines, sprintf("    orcid: %s", cff_str(orcid)))
    }

    if (!is.null(aff_name)) {
      lines <- c(lines, sprintf("    affiliation: %s", cff_str(aff_name)))
      # Note secondary affiliations — CFF 1.2.0 only supports one affiliation
      # per author entry; the full list lives in contributors.yaml.
      all_affs <- contrib$affiliations %||% list()
      if (length(all_affs) > 1L) {
        secondary <- vapply(all_affs[-1L], function(a) a$name %||% "", character(1L))
        lines <- c(lines,
          sprintf("    # Secondary affiliation(s): %s", paste(secondary, collapse = "; ")),
          "    # CFF 1.2.0 does not support multiple affiliations per author entry.",
          "    # Full affiliation list is in contributors.yaml."
        )
      }
    }
  }
  lines
}

# ---------------------------------------------------------------------------
# Splice new authors block into existing CITATION.cff text
#
# Strategy: find the `authors:` line and the next top-level key (a line that
# starts without leading whitespace, is not blank, and is not a comment).
# Replace everything between those two anchors with the new authors block.
# ---------------------------------------------------------------------------
splice_authors_into_cff <- function(cff_text, new_authors_lines) {
  lines <- strsplit(cff_text, "\n", fixed = TRUE)[[1L]]

  # Find start of `authors:` block (exact match at column 1)
  authors_start <- which(grepl("^authors:", lines))[1L]
  if (is.na(authors_start)) {
    stop("CITATION.cff does not contain an 'authors:' key. Cannot splice.")
  }

  # Find the next top-level key after authors_start
  # A top-level key: starts with a letter or digit, not blank, not a comment
  next_top <- NA_integer_
  if (authors_start < length(lines)) {
    for (i in seq(authors_start + 1L, length(lines))) {
      ln <- lines[i]
      if (grepl("^[a-zA-Z0-9]", ln)) {
        next_top <- i
        break
      }
    }
  }

  before <- lines[seq_len(authors_start - 1L)]
  after  <- if (!is.na(next_top)) lines[next_top:length(lines)] else character(0L)

  paste(c(before, new_authors_lines, after), collapse = "\n")
}

# ---------------------------------------------------------------------------
# Build a repo-scoped CONTRIBUTORS.md — only contributors assigned to
# repo_name (via explicit name or wildcard "*") are included.
# ---------------------------------------------------------------------------
build_repo_contributors_md <- function(contribs, repo_name) {
  # Filter to contributors who have at least one role for this repo
  assigned <- Filter(function(contrib) {
    length(roles_for_repo(contrib, repo_name)) > 0L
  }, contribs)

  if (length(assigned) == 0L) return(NULL)

  lines <- c(
    "# Contributors",
    "",
    paste0(
      "This file is generated from the workspace ",
      "[`contributors.yaml`](../contributors.yaml). ",
      "To update it, edit `contributors.yaml` at the workspace root and run ",
      "`Rscript scripts/sync_contributors.R`."
    ),
    "",
    "CRediT roles follow the [NISO CRediT taxonomy](https://credit.niso.org/).",
    "",
    "---",
    ""
  )

  for (contrib in assigned) {
    full_name <- paste(contrib$given_names %||% "", contrib$family_names %||% "")
    suffix    <- contrib$name_suffix %||% NULL
    if (!is.null(suffix)) full_name <- paste0(full_name, ", ", suffix)

    lines <- c(lines, paste0("## ", trimws(full_name)), "")

    affiliations <- contrib$affiliations %||% list()
    if (length(affiliations) > 0L) {
      lines <- c(lines, "**Affiliations:**")
      for (aff in affiliations) {
        aff_str   <- aff$name %||% ""
        loc_parts <- c(aff$city, aff$region, aff$country)
        loc_parts <- loc_parts[!vapply(loc_parts, is.null, logical(1))]
        if (length(loc_parts) > 0L) {
          aff_str <- paste0(aff_str, ", ", paste(loc_parts, collapse = ", "))
        }
        lines <- c(lines, paste0("- ", aff_str))
      }
      lines <- c(lines, "")
    }

    email <- contrib$email %||% NULL
    orcid <- contrib$orcid %||% NULL
    if (!is.null(email)) lines <- c(lines, paste0("**Contact:** ", email, "  "))
    if (!is.null(orcid)) lines <- c(lines, paste0("**ORCID:** ", orcid))
    lines <- c(lines, "")

    # All roles for this repo (wildcard + explicit, merged)
    roles <- roles_for_repo(contrib, repo_name)
    if (length(roles) > 0L) {
      role_str <- paste(vapply(roles, credit_label, character(1L)), collapse = " · ")
      lines <- c(lines, paste0("**CRediT roles:** ", role_str), "")
    }

    lines <- c(lines, "---", "")
  }

  # Remove trailing separator
  if (length(lines) >= 2L &&
      lines[length(lines)]       == "" &&
      lines[length(lines) - 1L]  == "---") {
    lines <- lines[seq_len(length(lines) - 2L)]
  }

  paste(lines, collapse = "\n")
}

# ---------------------------------------------------------------------------
# Generate outputs
# ---------------------------------------------------------------------------
md_content      <- build_contributors_md(contribs)
new_auth_lines  <- build_cff_authors_block(contribs)

# Read existing CITATION.cff (must exist — we never create it from scratch)
if (!file.exists(citation_path)) {
  stop(sprintf("CITATION.cff not found at: %s\nThis script updates an existing file.", citation_path))
}
cff_original <- readLines(citation_path, warn = FALSE)
cff_text     <- paste(cff_original, collapse = "\n")
new_cff_text <- splice_authors_into_cff(cff_text, new_auth_lines)

# ---------------------------------------------------------------------------
# Dry-run: show diffs and exit
# ---------------------------------------------------------------------------
if (dry_run) {
  cat("=== CONTRIBUTORS.md (new content) ===\n")
  cat(md_content, "\n\n")

  cat("=== CITATION.cff (new authors block) ===\n")
  cat(paste(new_auth_lines, collapse = "\n"), "\n\n")

  cat("[sync_contributors] Dry run complete — no files written.\n")
  quit(status = 0)
}

# ---------------------------------------------------------------------------
# Write outputs
# ---------------------------------------------------------------------------

# 1. CONTRIBUTORS.md
writeLines(md_content, md_out_path)
cat(sprintf("[OK] CONTRIBUTORS.md written → %s\n", md_out_path))

# 2. CITATION.cff — write only if content changed (avoid noisy git diffs)
new_cff_lines <- strsplit(new_cff_text, "\n", fixed = TRUE)[[1L]]
if (!identical(cff_original, new_cff_lines)) {
  writeLines(new_cff_lines, citation_path)
  cat(sprintf("[OK] CITATION.cff updated   → %s\n", citation_path))
} else {
  cat(sprintf("[OK] CITATION.cff unchanged → %s\n", citation_path))
}

cat("\n")

# 3. Per-repo CONTRIBUTORS.md
for (repo in STUDY_REPOS) {
  repo_dir <- file.path(root, repo)
  if (!dir.exists(repo_dir)) next  # skip repos not present locally

  repo_md <- build_repo_contributors_md(contribs, repo)
  if (is.null(repo_md)) {
    cat(sprintf("[--] %s/CONTRIBUTORS.md skipped (no contributors assigned)\n", repo))
    next
  }

  repo_md_path   <- file.path(repo_dir, "CONTRIBUTORS.md")
  existing_lines <- if (file.exists(repo_md_path)) readLines(repo_md_path, warn = FALSE) else character(0L)
  new_lines      <- strsplit(repo_md, "\n", fixed = TRUE)[[1L]]

  if (!dry_run) {
    if (!identical(existing_lines, new_lines)) {
      writeLines(new_lines, repo_md_path)
      cat(sprintf("[OK] %s/CONTRIBUTORS.md written\n", repo))
    } else {
      cat(sprintf("[OK] %s/CONTRIBUTORS.md unchanged\n", repo))
    }
  } else {
    cat(sprintf("[DRY] %s/CONTRIBUTORS.md would be written\n", repo))
  }
}

cat("\n[sync_contributors] Done.\n")
