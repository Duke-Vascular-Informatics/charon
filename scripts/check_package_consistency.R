#!/usr/bin/env Rscript
# =============================================================================
# scripts/check_package_consistency.R
#
# PURPOSE
# -------
# Detects drift in this workspace's custom "renv-package" repos — a repo
# registered in studies.yaml's `templates:` section with `type: renv-package`
# (currently just omop-report-toolkit) that is NOT a submodule and NOT
# vendored anywhere, but is instead installed by consumer repos via
# `renv::install(owner/repo@sha)` pinned to a commit (CLAUDE.md Rule 2).
#
# That pin is exactly the kind of thing that silently rots: a bug gets fixed
# in the package, one consumer's renv.lock gets hand-edited to the new
# commit, and every OTHER consumer just... doesn't, because nothing checks.
# This has happened for real in this workspace: a crash fix landed in one
# consumer's renv.lock while other consumers were still pinned to the older,
# broken commit, with nothing flagging the gap.
#
# Consumers are discovered by SCANNING, not by trusting studies.yaml's
# `consumers:` field on the pipeline.repos entry — that field can itself go
# stale (e.g. it may still list pre-split analysis-core repos rather than the
# *-report repos that actually import the package after a report-split
# migration). A hand-maintained consumer list has the same drift problem as a
# hand-maintained pin, so this script does not add one.
#
# For every `type: renv-package` entry, this script:
#   1. Reads the latest commit on that GitHub repo's default branch (`gh api`
#      — read-only, no writes, no credentials beyond whatever `gh` already
#      has, same tool this workspace already requires for its PR workflow).
#   2. Walks every immediate subdirectory of the workspace root that has a
#      renv.lock, and for each one pinning that package (matched by
#      RemoteUsername/RemoteRepo, not by consumer-repo name), reports whether
#      the pin is current or behind.
#   3. Separately scans each such subdirectory's R source for
#      library(<pkg>)/<pkg>:: use with NO matching renv.lock entry at all —
#      a dependency that's used but was never declared/pinned in the first
#      place, which a pin-drift check alone would miss.
#
# USAGE
# -----
#   Rscript scripts/check_package_consistency.R
#
# REQUIREMENTS
# ------------
#   yaml, jsonlite — CRAN, already in the workspace lockfile
#   gh             — GitHub CLI; already required elsewhere in this workspace
#                    (see CLAUDE.md "Opening and merging PRs"). Only ever
#                    called here to read a public commit SHA.
#
# EXIT CODE
# ---------
#   0 — every renv-package pin found is current, and nothing is used unpinned
#   1 — at least one pin is behind, or a package is used with no pin at all,
#       or the latest commit could not be determined (e.g. `gh` not
#       authenticated) for at least one renv-package entry
# =============================================================================

library(yaml)
library(jsonlite)

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0L) y else x

# ---------------------------------------------------------------------------
# Section 1 — Locate the workspace root
# ---------------------------------------------------------------------------
# Same resolution strategy as osf/osf_sync.R and scripts/sync_contributors.R:
# derive it from --file= when run via `Rscript path/to/this.R`, else assume the
# working directory already IS the workspace root. studies.yaml's presence is
# the confirmation check every workspace tool uses.
resolve_workspace_root <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  candidate <- if (length(file_arg) == 1) {
    normalizePath(file.path(dirname(file_arg), ".."))  # scripts/ -> workspace root
  } else {
    normalizePath(getwd())
  }
  if (!file.exists(file.path(candidate, "studies.yaml"))) {
    stop("Cannot locate studies.yaml from '", candidate, "'. Run as: ",
         "Rscript scripts/check_package_consistency.R from the workspace root.")
  }
  candidate
}

workspace_root <- resolve_workspace_root()
registry       <- yaml::read_yaml(file.path(workspace_root, "studies.yaml"))

# ---------------------------------------------------------------------------
# Section 2 — Identify the renv-package entries to audit
# ---------------------------------------------------------------------------
renv_pkg_entries <- Filter(
  function(e) identical(e$type, "renv-package"),
  registry$templates %||% list()
)

if (length(renv_pkg_entries) == 0L) {
  message("[check_package_consistency] No `type: renv-package` entries found ",
          "in studies.yaml -- nothing to check.")
  quit(status = 0L, save = "no")
}

# ---------------------------------------------------------------------------
# Section 3 — Read the latest published commit for each renv-package
# ---------------------------------------------------------------------------
# `gh api repos/<owner>/<repo>/commits/HEAD --jq .sha` resolves HEAD of the
# repo's default branch server-side, so this does not need to know (or guess)
# the branch name, and does not require a local clone to exist at all.
latest_commit_sha <- function(github_slug) {
  result <- suppressWarnings(system2(
    "gh",
    c("api", paste0("repos/", github_slug, "/commits/HEAD"), "--jq", ".sha"),
    stdout = TRUE, stderr = TRUE
  ))
  status <- attr(result, "status") %||% 0L
  if (!identical(status, 0L) || length(result) == 0L) return(NA_character_)
  sha <- trimws(result[[1]])
  if (!grepl("^[0-9a-f]{40}$", sha)) return(NA_character_)
  sha
}

targets <- lapply(renv_pkg_entries, function(e) {
  slug <- e$github
  parts <- strsplit(slug, "/", fixed = TRUE)[[1]]
  list(
    dir          = e$dir,
    github_slug  = slug,
    github_owner = parts[1],
    github_repo  = parts[2],
    latest_sha   = latest_commit_sha(slug)
  )
})
names(targets) <- vapply(targets, function(t) t$github_repo, character(1))

for (t in targets) {
  if (is.na(t$latest_sha)) {
    message("[check_package_consistency] WARNING: could not read the latest ",
            "commit for ", t$github_slug, " via `gh api` -- is `gh` ",
            "authenticated? Pin checks for this package will report UNKNOWN.")
  }
}

# ---------------------------------------------------------------------------
# Section 4 — Read the R package name each target actually installs as
# ---------------------------------------------------------------------------
# renv.lock keys packages by their R "Package:" name (e.g. "omopReportToolkit"),
# which need not match the GitHub repo's dash-case name (e.g.
# "omop-report-toolkit") -- read it from the target's own local clone so the
# library()/:: scan in Section 6 looks for the right symbol.
package_name_of <- function(target) {
  desc_path <- file.path(workspace_root, target$dir, "DESCRIPTION")
  if (!file.exists(desc_path)) return(NA_character_)
  desc <- read.dcf(desc_path)
  if (!"Package" %in% colnames(desc)) return(NA_character_)
  unname(desc[1, "Package"])
}
for (name in names(targets)) targets[[name]]$package_name <- package_name_of(targets[[name]])

# ---------------------------------------------------------------------------
# Section 5 — Discover every candidate consumer directory
# ---------------------------------------------------------------------------
# Deliberately NOT sourced from studies.yaml's `consumers:` field (see the
# file header for why that field is itself unreliable) or from the
# `studies:`/`pipeline.repos` YAML blocks (three different shapes to parse for
# no real benefit). A consumer is, definitionally, any workspace subdirectory
# that has a renv.lock -- so just look for one directly.
candidate_dirs <- list.dirs(workspace_root, full.names = FALSE, recursive = FALSE)
candidate_dirs <- candidate_dirs[nzchar(candidate_dirs) & !startsWith(candidate_dirs, ".")]
consumer_dirs  <- candidate_dirs[file.exists(file.path(workspace_root, candidate_dirs, "renv.lock"))]

# ---------------------------------------------------------------------------
# Section 6 — Check every consumer's pin, and every consumer's R source
# ---------------------------------------------------------------------------
# A renv.lock package entry is matched to a target by RemoteUsername/
# RemoteRepo (the GitHub identity), never by the consumer directory's own
# name -- a target's own repo is never its own consumer, and this is exactly
# the join key renv itself uses to know what to (re)install.
results <- list()

for (consumer in consumer_dirs) {
  lock_path <- file.path(workspace_root, consumer, "renv.lock")
  lock <- tryCatch(jsonlite::fromJSON(lock_path, simplifyVector = FALSE),
                    error = function(e) NULL)
  if (is.null(lock) || is.null(lock$Packages)) next

  pinned_slugs <- character(0)

  for (pkg in lock$Packages) {
    if (!identical(pkg$RemoteType %||% "", "github")) next
    slug <- paste0(pkg$RemoteUsername %||% "", "/", pkg$RemoteRepo %||% "")
    pinned_slugs <- c(pinned_slugs, slug)

    target <- targets[[pkg$RemoteRepo %||% ""]]
    if (is.null(target) || !identical(target$github_owner, pkg$RemoteUsername %||% "")) next

    pinned_sha <- pkg$RemoteSha %||% NA_character_
    status <- if (is.na(target$latest_sha)) {
      "UNKNOWN"
    } else if (identical(pinned_sha, target$latest_sha)) {
      "OK"
    } else {
      "BEHIND"
    }
    results[[length(results) + 1L]] <- list(
      consumer = consumer, package = pkg$Package, slug = target$github_slug,
      pinned = pinned_sha, latest = target$latest_sha, status = status
    )
  }

  # Used-but-unpinned check: grep this consumer's R source for
  # library(<pkg>) or <pkg>:: for every target NOT already found pinned above.
  #
  # Two things a plain grep gets wrong, both hit on the first real run of
  # this script against a populated workspace:
  #   1. A comment can mention the package name (e.g. explaining why it was
  #      deliberately NOT used) without the code ever calling it -- strip
  #      `#...` before matching, not after.
  #   2. requireNamespace(pkg, quietly = TRUE)-guarded use is an intentional,
  #      documented optional dependency (studies.yaml's omop-report-toolkit
  #      entry: "OPTIONAL, deliberately ... a private GitHub repo ... must
  #      still run somewhere without it") -- that is NOT the same failure as
  #      a library()/:: call with no guard and no pin at all, so it must not
  #      be reported at the same severity.
  r_files <- list.files(file.path(workspace_root, consumer), pattern = "\\.R$",
                         recursive = TRUE, full.names = TRUE)
  if (length(r_files) == 0L) next

  # useBytes = TRUE throughout this block: several R files in this workspace
  # contain stray non-UTF-8 bytes (e.g. a non-breaking space) that make R's
  # default string translation abort with "invalid input string" -- every
  # pattern matched here is plain ASCII, so byte-wise matching is exactly as
  # correct and sidesteps the encoding entirely.
  uncommented_lines_of <- function(f) {
    sub("#.*$", "", readLines(f, warn = FALSE, encoding = "UTF-8"), useBytes = TRUE)
  }

  for (target in targets) {
    if (is.na(target$package_name)) next
    if (target$github_slug %in% "") next
    already_pinned <- any(vapply(results, function(r) {
      identical(r$consumer, consumer) && identical(r$slug, target$github_slug)
    }, logical(1)))
    if (already_pinned) next

    use_pattern   <- paste0("library\\(", target$package_name, "\\)|",
                             target$package_name, "::")
    guard_pattern <- paste0("requireNamespace\\(\\s*[\"']", target$package_name, "[\"']")

    file_lines <- lapply(r_files, uncommented_lines_of)
    used  <- any(vapply(file_lines, function(l) any(grepl(use_pattern, l, useBytes = TRUE)), logical(1)))
    if (!used) next
    guarded <- any(vapply(file_lines, function(l) any(grepl(guard_pattern, l, useBytes = TRUE)), logical(1)))

    results[[length(results) + 1L]] <- list(
      consumer = consumer, package = target$package_name, slug = target$github_slug,
      pinned = NA_character_, latest = target$latest_sha,
      status = if (guarded) "OPTIONAL_UNPINNED" else "UNPINNED"
    )
  }
}

# ---------------------------------------------------------------------------
# Section 7 — Report
# ---------------------------------------------------------------------------
# Same [OK] / [WARN] / [FAIL] bracket convention as scripts/check_setup.R
# (CLAUDE.md "Template Customization Assistance"), so this reads the same way
# as every other workspace pre-flight check.
short <- function(sha) if (is.na(sha)) "??????" else substr(sha, 1, 8)

cat("\n== omop-dev-workspace :: renv-package consistency ==\n\n")

if (length(results) == 0L) {
  cat("[OK] No renv.lock in this workspace pins any registered renv-package.\n")
  quit(status = 0L, save = "no")
}

any_bad <- FALSE
for (r in results) {
  tag <- switch(r$status,
    OK                = "[OK]  ",
    BEHIND            = "[WARN]",
    UNPINNED          = "[FAIL]",
    OPTIONAL_UNPINNED = "[INFO]",
    UNKNOWN           = "[WARN]"
  )
  if (r$status %in% c("BEHIND", "UNPINNED", "UNKNOWN")) any_bad <- TRUE

  detail <- switch(r$status,
    OK                = sprintf("pinned to latest (%s)", short(r$pinned)),
    BEHIND            = sprintf("pinned to %s, latest is %s", short(r$pinned), short(r$latest)),
    UNPINNED          = "used in R source, but no renv.lock entry pins it at all",
    OPTIONAL_UNPINNED = "requireNamespace()-guarded optional use, no pin -- OK by design",
    UNKNOWN           = sprintf("pinned to %s, could not confirm latest", short(r$pinned))
  )
  cat(sprintf("%s %-28s %-20s %s\n", tag, r$consumer, r$package, detail))
}

cat("\n")
if (any_bad) {
  cat("Some consumers need attention -- see CLAUDE.md Rule 2 / each renv-\n",
      "package's own README for the hand-verified renv.lock bump process\n",
      "(never a blind renv::snapshot()).\n", sep = "")
  quit(status = 1L, save = "no")
} else {
  cat("All renv-package pins are current.\n")
  quit(status = 0L, save = "no")
}
