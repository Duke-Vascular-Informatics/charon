#!/usr/bin/env Rscript
# =============================================================================
# phenotype_library/scripts/regenerate_readme_table.R
#
# Regenerates the "Catalog Contents" table in phenotype_library/README.md
# from the current state of catalog.yaml. Run from the workspace root:
#
#   Rscript phenotype_library/scripts/regenerate_readme_table.R
#
# The script finds the table between the "| Entry ID |" header row and the
# next "---" horizontal rule, then replaces it with a freshly generated
# table from the YAML.
# =============================================================================

library(yaml)

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
workspace_root <- getwd()
catalog_path   <- file.path(workspace_root, "phenotype_library", "catalog.yaml")
readme_path    <- file.path(workspace_root, "phenotype_library", "README.md")

if (!file.exists(catalog_path)) {
  stop("catalog.yaml not found at: ", catalog_path,
       "\nRun this script from the workspace root.", call. = FALSE)
}
if (!file.exists(readme_path)) {
  stop("README.md not found at: ", readme_path, call. = FALSE)
}

# ---------------------------------------------------------------------------
# Read catalog
# ---------------------------------------------------------------------------
cat_data <- yaml::read_yaml(catalog_path)
entries  <- cat_data$entries

# ---------------------------------------------------------------------------
# Shorten study IDs for the table. No-op by default — customize this if your
# study repos share a common prefix you'd rather not repeat in every table
# cell (e.g. `sub("^my-lab-", "", sid)`).
# ---------------------------------------------------------------------------
shorten_study <- function(sid) {
  sid
}

# ---------------------------------------------------------------------------
# Build table rows
# ---------------------------------------------------------------------------
rows <- character(0)

for (e in entries) {
  indent <- ""
  if (length(e$parent_ids) > 0) {
    indent <- "&nbsp;&nbsp;\\u21b3 "
  }

  # Collect unique study IDs
  studies <- "—"
  if (!is.null(e$used_by) && length(e$used_by) > 0) {
    sids <- unique(vapply(e$used_by, function(u) u$study_id, character(1)))
    sids <- vapply(sids, shorten_study, character(1))
    studies <- paste(sids, collapse = ", ")
  }

  # Bold pending/partial statuses for visibility

  status <- e$status
  if (status %in% c("pending", "partial")) {
    status <- paste0("**", status, "**")
  }

  row <- sprintf("| %s`%s` | %s | %s | %s | %s |",
                 indent, e$id, e$name, e$domain, status, studies)
  rows <- c(rows, row)
}

header <- "| Entry ID | Name | Domain | Status | Studies |"
sep    <- "|----------|------|--------|--------|---------|"
table_lines <- c(header, sep, rows)

# ---------------------------------------------------------------------------
# Replace the table in README.md
# ---------------------------------------------------------------------------
readme <- readLines(readme_path)

# Find the existing table: starts at "| Entry ID |" header, ends at next "---"
table_start <- grep("^\\| Entry ID", readme)
if (length(table_start) == 0) {
  stop("Could not find '| Entry ID |' header row in README.md", call. = FALSE)
}
table_start <- table_start[1]

# Find the next "---" after the table
subsequent   <- seq(table_start + 1, length(readme))
table_end_candidates <- grep("^---$", readme[subsequent])
if (length(table_end_candidates) == 0) {
  stop("Could not find closing '---' after the table in README.md", call. = FALSE)
}
table_end <- subsequent[table_end_candidates[1]] - 1

# Trim any trailing blank lines before the ---
while (table_end >= table_start && readme[table_end] == "") {
  table_end <- table_end - 1
}

# Rebuild the file
new_readme <- c(
  readme[1:(table_start - 1)],
  table_lines,
  "",
  readme[(table_end + 1):length(readme)]
)

writeLines(new_readme, readme_path)

cat(sprintf("[OK] Regenerated catalog table: %d entries written to %s\n",
            length(rows), readme_path))
