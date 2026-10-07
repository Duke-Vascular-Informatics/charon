#!/usr/bin/env Rscript
# =============================================================================
# scripts/release_check.R
#
# PURPOSE
# -------
# For every Zenodo-archived repo this workspace publishes (its template repos,
# and charon itself), diff the repo's default branch against its LATEST GitHub
# release, recommend whether a new release is warranted and at which semver
# level (patch / minor / major / none), and emit a step-by-step PLAN for
# cutting the releases in the right order.
#
# READ-ONLY. This tool never tags, pushes, edits, or opens anything. It calls
# the GitHub API (read-only `gh api`) and, optionally, the public Zenodo API,
# then prints a plan whose commands YOU run. The recommendation is a heuristic
# over commit messages and changed paths; the evidence behind every
# recommendation is printed so you can overrule it. See docs/RELEASING.md for
# the policy the heuristics encode.
#
# WHAT IT CHECKS, PER REPO
# ------------------------
#   1. Latest published (non-draft, non-prerelease) GitHub release tag. A repo
#      with no release is reported as a "first release" candidate.
#   2. The diff <tag>...<default branch>: commits and changed files (GitHub
#      compare API; no local clone needed).
#   3. Signals, each with a level and a confidence:
#        MAJOR  a `type!:` / `BREAKING CHANGE` commit; a removed or renamed
#               code file under a "contract path" (scripts/, workflow/, R/,
#               setup/, .devcontainer/, ...); a removed NAMESPACE export()
#               line; a removed git submodule.
#        MINOR  a `feat:` commit; a NEW file under a contract path; a new
#               NAMESPACE export(); a new git submodule.
#        PATCH  a `fix:` commit; a modified code/infra file that is not
#               comment-only; a submodule pointer bump; substantial docs churn
#               (>= DOC_CHURN_PATCH changed lines under docs/ or *.md).
#        none   README/CITATION/CONTRIBUTORS/.github/CI/instance-registry
#               edits, comment-only code edits, and small docs edits.
#      The highest signal wins. For a 0.y.z version, semver treats the minor
#      number as the "breaking" slot, so MAJOR -> next minor and MINOR/PATCH ->
#      next patch (the output says when it applied this shift).
#   4. Metadata drift at the branch tip: DESCRIPTION Version / CITATION.cff
#      `version` disagreeing with the latest tag; Zenodo webhook present
#      (boolean only -- the hook URL carries a token and is NEVER printed); and
#      whether the latest tag's version actually appears under the repo's
#      Zenodo concept DOI (best-effort, public Zenodo API).
#   5. Submodule dependencies (from .gitmodules): for a repo that vendors other
#      checked repos (charon), whether each pointer is at the dependency's
#      latest release, ahead of it, or behind the dependency's main.
#
# THE PLAN
# --------
# Repos that warrant a release are ordered dependencies-first (templates, then
# charon). Each gets: files to edit (CITATION.cff date-released/version,
# DESCRIPTION Version), the PR + squash-merge + branch-reset commands from
# CLAUDE.md, the `gh release create` command with a drafted notes file, the
# Zenodo verification, and (for dependencies) the pointer bumps in dependents.
#
# USAGE
# -----
#   Rscript scripts/release_check.R                     # all repos, plan to stdout
#   Rscript scripts/release_check.R --out-dir release_plan   # also write files
#   Rscript scripts/release_check.R --repo OWNER/NAME   # add a repo (repeatable)
#   Rscript scripts/release_check.R --only NAME         # restrict to a repo name
#   Rscript scripts/release_check.R --no-zenodo         # skip the Zenodo API call
#   Rscript scripts/release_check.R --since NAME=REF    # diff NAME from REF (a tag/sha)
#                                                       # instead of its latest release;
#                                                       # for what-if checks and testing
#
# REPO DISCOVERY (union, de-duplicated)
#   * studies.yaml `templates:` entries that have a `github:` slug
#   * studies.yaml top-level `release_repos:` — an optional list of extra
#     OWNER/NAME slugs (e.g. the public charon repo, which a lab workspace does
#     not otherwise know about)
#   * the `charon` git remote, if this checkout has one (the lab workspace does)
#   * the `origin` remote (so running inside charon checks charon itself)
#   * any --repo OWNER/NAME arguments
#
# REQUIREMENTS
#   yaml, jsonlite (CRAN, already in the workspace lockfile); `gh`
#   (authenticated); `curl` only for the optional Zenodo check.
#
# EXIT CODE
#   0 — ran to completion (whether or not releases are recommended)
#   1 — a repo could not be read at all (e.g. `gh` unauthenticated)
# =============================================================================

suppressPackageStartupMessages({
  library(yaml)
  library(jsonlite)
})

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0L) y else x

# ---------------------------------------------------------------------------
# Section 1 — Tunable policy constants
# ---------------------------------------------------------------------------

# Paths whose REMOVAL is a breaking change and whose ADDITION is new capability.
# Anchored regexes against repo-relative paths. A user (or another repo) can
# be calling anything under these.
CONTRACT_PATHS <- c(
  "^scripts/", "^workflow/", "^R/", "^setup/", "^\\.devcontainer/",
  "^infrastructure/", "^phenotype_library/scripts/", "^synthetic_data/scripts/",
  "^inst/"
)

# Paths that never justify a release on their own (metadata, CI, instance data).
IGNORE_PATHS <- c(
  "^\\.github/(workflows|ISSUE_TEMPLATE)/", "^\\.github/CODEOWNERS$",
  "^\\.github/pull_request_template\\.md$",
  "^CITATION\\.cff$", "^CONTRIBUTORS\\.md$", "^contributors\\.yaml$",
  "^README\\.md$", "^\\.gitignore$", "^\\.lintr$", "^\\.Rbuildignore$",
  "^docs/CHANGELOG\\.md$",
  # Per-lab instance data (differs between every workspace by design).
  "^studies\\.yaml$", "^WORKSPACE_ROSTER\\.md$", "^osf/.*\\.csv$",
  "^phenotype_library/catalog\\.yaml$", "^synthetic_data/registry\\.yaml$"
)

# Documentation paths: a signal only when the churn is substantial.
DOC_PATHS <- c("\\.md$", "^docs/", "^\\.github/(instructions|prompts)/")

# Changed lines under docs before docs alone suggest a patch release.
DOC_CHURN_PATCH <- 40L

# Extensions whose comment-only edits carry no behavior change.
COMMENT_HASH_EXT <- c("R", "r", "sh", "ps1", "yml", "yaml", "py", "cff", "txt")

LEVELS <- c(none = 0L, patch = 1L, minor = 2L, major = 3L)
LEVEL_NAMES <- names(LEVELS)

# ---------------------------------------------------------------------------
# Section 2 — Argument parsing
# ---------------------------------------------------------------------------
parse_args <- function(argv) {
  opts <- list(repos = character(0), only = NULL, out_dir = NULL, zenodo = TRUE, since = list())
  i <- 1L
  while (i <= length(argv)) {
    a <- argv[[i]]
    if (a %in% c("-h", "--help")) {
      cat("See the header of scripts/release_check.R, or docs/RELEASING.md.\n")
      quit(status = 0L, save = "no")
    } else if (a == "--repo")    { opts$repos  <- c(opts$repos, argv[[i + 1L]]); i <- i + 1L
    } else if (a == "--only")    { opts$only   <- argv[[i + 1L]]; i <- i + 1L
    } else if (a == "--out-dir") { opts$out_dir <- argv[[i + 1L]]; i <- i + 1L
    } else if (a == "--since")   { kv <- strsplit(argv[[i + 1L]], "=", fixed = TRUE)[[1]]
                                   opts$since[[kv[1]]] <- kv[2]; i <- i + 1L
    } else if (a == "--no-zenodo") { opts$zenodo <- FALSE
    } else stop("Unknown argument: ", a)
    i <- i + 1L
  }
  opts
}
opts <- parse_args(commandArgs(trailingOnly = TRUE))

# ---------------------------------------------------------------------------
# Section 3 — Thin, read-only wrappers around `gh` and `curl`
# ---------------------------------------------------------------------------

# GET a GitHub API path and return the parsed JSON (lists, not data frames), or
# NULL if the call failed (404, no auth, ...). The path is shell-quoted because
# system2() runs through a shell and API paths contain '?' and '&'.
gh_json <- function(path) {
  out <- suppressWarnings(system2(
    "gh", c("api", shQuote(path)), stdout = TRUE, stderr = FALSE
  ))
  if (!is.null(attr(out, "status")) || length(out) == 0L) return(NULL)
  tryCatch(jsonlite::fromJSON(paste(out, collapse = "\n"), simplifyVector = FALSE),
           error = function(e) NULL)
}

# Fetch a text file from a repo at a ref, via the contents API (base64).
gh_file <- function(slug, path, ref) {
  r <- gh_json(sprintf("repos/%s/contents/%s?ref=%s", slug, path, ref))
  if (is.null(r) || is.null(r$content)) return(NULL)
  rawToChar(jsonlite::base64_dec(gsub("\n", "", r$content)))
}

# ---------------------------------------------------------------------------
# Section 4 — Version helpers
# ---------------------------------------------------------------------------

# "v1.2.3" / "1.2.3" -> c(1, 2, 3); NULL if the tag is not semver-shaped.
parse_version <- function(tag) {
  m <- regmatches(tag, regexec("^v?([0-9]+)\\.([0-9]+)\\.([0-9]+)", tag))[[1]]
  if (length(m) != 4L) return(NULL)
  as.integer(m[2:4])
}

# Next version for a bump level. For 0.y.z the "breaking" slot is the minor
# number (semver 2.0 item 4), so major -> next minor, minor/patch -> next patch.
next_version <- function(ver, level) {
  shifted <- FALSE
  if (ver[1] == 0L) {
    if (level == "major") { level <- "minor"; shifted <- TRUE
    } else if (level == "minor") { level <- "patch"; shifted <- TRUE }
  }
  nv <- switch(level,
    major = c(ver[1] + 1L, 0L, 0L),
    minor = c(ver[1], ver[2] + 1L, 0L),
    patch = c(ver[1], ver[2], ver[3] + 1L)
  )
  list(version = paste(nv, collapse = "."), shifted = shifted)
}

# ---------------------------------------------------------------------------
# Section 5 — Diff retrieval (GitHub compare API, paginated, de-duplicated)
# ---------------------------------------------------------------------------
compare_range <- function(slug, base, head) {
  commits <- list(); files <- list(); meta <- NULL; page <- 1L
  repeat {
    r <- gh_json(sprintf("repos/%s/compare/%s...%s?per_page=100&page=%d",
                         slug, base, head, page))
    if (is.null(r)) return(NULL)
    if (is.null(meta)) meta <- r[c("status", "ahead_by", "behind_by", "total_commits")]
    commits <- c(commits, r$commits)
    files   <- c(files, r$files)
    # A short page on both lists means we have everything.
    if (length(r$commits) < 100L && length(r$files) < 100L) break
    page <- page + 1L
    if (page > 30L) break
  }
  # The files list can repeat across pages; keep the first occurrence per path.
  seen <- character(0); uniq <- list()
  for (f in files) {
    if (!(f$filename %in% seen)) { seen <- c(seen, f$filename); uniq[[length(uniq) + 1L]] <- f }
  }
  list(meta = meta, commits = commits, files = uniq)
}

# ---------------------------------------------------------------------------
# Section 6 — Signal extraction
# ---------------------------------------------------------------------------
# Every signal is list(level, reason, conf) with conf in {high, medium, low}.
signal <- function(level, reason, conf) list(level = level, reason = reason, conf = conf)

matches_any <- function(path, patterns) any(vapply(patterns, grepl, logical(1), x = path))

# Lines changed (added + removed) in a unified-diff patch string.
patch_lines <- function(patch) {
  if (is.null(patch)) return(character(0))
  ls <- strsplit(patch, "\n", fixed = TRUE)[[1]]
  ls[grepl("^[+-]", ls) & !grepl("^(\\+\\+\\+|---)", ls)]
}

# TRUE when every changed line is blank or a '#' comment (so the edit cannot
# change behavior). Only trusted for extensions that use '#' comments.
comment_only <- function(path, patch) {
  ext <- tools::file_ext(path)
  if (!(ext %in% COMMENT_HASH_EXT) && basename(path) != "Dockerfile") return(FALSE)
  ch <- patch_lines(patch)
  if (length(ch) == 0L) return(FALSE)
  body <- trimws(substring(ch, 2L))
  all(body == "" | grepl("^#", body))
}

# Commit-message signals from conventional-commit prefixes (feat/fix/...!:).
commit_signals <- function(commits) {
  sigs <- list()
  for (cm in commits) {
    msg <- cm$commit$message
    subj <- strsplit(msg, "\n", fixed = TRUE)[[1]][1]
    short <- substr(cm$sha, 1, 7)
    if (grepl("^[a-z]+(\\([^)]*\\))?!:", subj) || grepl("BREAKING CHANGE", msg, fixed = TRUE)) {
      sigs[[length(sigs) + 1L]] <- signal("major", sprintf("breaking-change commit %s: %s", short, subj), "high")
    } else if (grepl("^feat(\\([^)]*\\))?:", subj)) {
      sigs[[length(sigs) + 1L]] <- signal("minor", sprintf("feat commit %s: %s", short, subj), "medium")
    } else if (grepl("^fix(\\([^)]*\\))?:", subj)) {
      sigs[[length(sigs) + 1L]] <- signal("patch", sprintf("fix commit %s: %s", short, subj), "medium")
    }
  }
  sigs
}

# Signals from changed files (see the header for the rule table).
file_signals <- function(files) {
  sigs <- list(); doc_churn <- 0L
  for (f in files) {
    p <- f$filename; st <- f$status; patch <- f$patch
    prev <- f$previous_filename

    # Git submodule pointer changes appear as a "Subproject commit" patch.
    if (!is.null(patch) && grepl("Subproject commit", patch, fixed = TRUE)) {
      if (st == "added") {
        sigs[[length(sigs) + 1L]] <- signal("minor", sprintf("new submodule: %s", p), "medium")
      } else if (st == "removed") {
        sigs[[length(sigs) + 1L]] <- signal("major", sprintf("removed submodule: %s", p), "high")
      } else {
        sigs[[length(sigs) + 1L]] <- signal("patch", sprintf("submodule pointer bump: %s", p), "medium")
      }
      next
    }

    # A rename is a removal of the old path plus an addition of the new one.
    removed_path <- if (st == "removed") p else if (st == "renamed") prev else NULL
    added_path   <- if (st == "added") p else if (st == "renamed") p else NULL

    if (!is.null(removed_path) && matches_any(removed_path, CONTRACT_PATHS) &&
        !matches_any(removed_path, DOC_PATHS)) {
      sigs[[length(sigs) + 1L]] <- signal("major", sprintf("removed/renamed contract file: %s", removed_path), "high")
    }
    if (!is.null(added_path) && matches_any(added_path, CONTRACT_PATHS) &&
        !matches_any(added_path, DOC_PATHS)) {
      sigs[[length(sigs) + 1L]] <- signal("minor", sprintf("new contract file: %s", added_path), "medium")
    }

    # R package API: NAMESPACE export() lines.
    if (identical(p, "NAMESPACE") && !is.null(patch)) {
      ch <- patch_lines(patch)
      rm_ex  <- sub("^-", "", ch[grepl("^-export\\(", ch)])
      add_ex <- sub("^\\+", "", ch[grepl("^\\+export\\(", ch)])
      gone <- setdiff(rm_ex, add_ex); new <- setdiff(add_ex, rm_ex)
      for (g in gone) sigs[[length(sigs) + 1L]] <- signal("major", sprintf("removed NAMESPACE %s", g), "high")
      for (n in new)  sigs[[length(sigs) + 1L]] <- signal("minor", sprintf("new NAMESPACE %s", n), "high")
    }

    # Added/removed/renamed code files under a contract path were fully
    # classified above (major/minor); don't double-count them as a patch.
    handled <- (!is.null(removed_path) && matches_any(removed_path, CONTRACT_PATHS) &&
                  !matches_any(removed_path, DOC_PATHS)) ||
               (!is.null(added_path) && matches_any(added_path, CONTRACT_PATHS) &&
                  !matches_any(added_path, DOC_PATHS))
    if (handled) next

    # Everything else: classify by path.
    if (matches_any(p, IGNORE_PATHS)) next
    if (matches_any(p, DOC_PATHS)) {
      doc_churn <- doc_churn + as.integer(f$additions %||% 0L) + as.integer(f$deletions %||% 0L)
      next
    }
    # A code/infra file outside the contract paths (or modified inside them):
    # at least a patch, unless the edit is comment-only.
    if (st == "modified" && comment_only(p, patch)) next
    sigs[[length(sigs) + 1L]] <- signal("patch", sprintf("%s code/infra file: %s", st, p), "medium")
  }
  if (doc_churn >= DOC_CHURN_PATCH) {
    sigs[[length(sigs) + 1L]] <- signal("patch",
      sprintf("substantial docs churn (%d changed lines)", doc_churn), "low")
  }
  sigs
}

# Collapse signals to the highest level, and the best confidence at that level.
summarise_signals <- function(sigs) {
  if (length(sigs) == 0L) return(list(level = "none", conf = "high", top = list()))
  lv <- vapply(sigs, function(s) LEVELS[[s$level]], integer(1))
  top_lv <- max(lv)
  top <- sigs[lv == top_lv]
  conf_rank <- c(low = 1L, medium = 2L, high = 3L)
  best <- names(conf_rank)[max(vapply(top, function(s) conf_rank[[s$conf]], integer(1)))]
  list(level = LEVEL_NAMES[top_lv + 1L], conf = best, top = top)
}

# ---------------------------------------------------------------------------
# Section 7 — Metadata drift, Zenodo, submodules
# ---------------------------------------------------------------------------

# TRUE/FALSE if the repo has a Zenodo webhook; NA if hooks are not readable
# (needs admin). Only the boolean leaves this function -- the URL has a token.
has_zenodo_hook <- function(slug) {
  r <- gh_json(sprintf("repos/%s/hooks", slug))
  if (is.null(r)) return(NA)
  any(vapply(r, function(h) grepl("zenodo", h$config$url %||% "", fixed = TRUE), logical(1)))
}

# Newest version string archived under a Zenodo concept DOI, or NA.
zenodo_latest_version <- function(concept_doi) {
  if (is.null(concept_doi)) return(NA_character_)
  q <- utils::URLencode(sprintf("conceptdoi:\"%s\"", concept_doi), reserved = TRUE)
  url <- sprintf("https://zenodo.org/api/records?q=%s&sort=mostrecent&size=1", q)
  out <- suppressWarnings(system2("curl", c("-s", "--max-time", "20", shQuote(url)),
                                  stdout = TRUE, stderr = FALSE))
  if (!is.null(attr(out, "status")) || length(out) == 0L) return(NA_character_)
  r <- tryCatch(jsonlite::fromJSON(paste(out, collapse = "\n"), simplifyVector = FALSE),
                error = function(e) NULL)
  hit <- r$hits$hits
  if (is.null(hit) || length(hit) == 0L) return(NA_character_)
  hit[[1]]$metadata$version %||% NA_character_
}

# Parse `url = https://github.com/OWNER/NAME(.git)` lines out of .gitmodules.
parse_gitmodules <- function(txt) {
  if (is.null(txt)) return(list())
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  path <- NA_character_; out <- list()
  for (ln in lines) {
    if (grepl("^\\s*path\\s*=", ln)) path <- trimws(sub("^\\s*path\\s*=", "", ln))
    if (grepl("^\\s*url\\s*=", ln)) {
      url <- trimws(sub("^\\s*url\\s*=", "", ln))
      m <- regmatches(url, regexec("github\\.com[:/]([^/]+/[^/]+?)(\\.git)?$", url))[[1]]
      if (length(m) >= 2L) out[[length(out) + 1L]] <- list(path = path, slug = m[2])
    }
  }
  out
}

# ---------------------------------------------------------------------------
# Section 8 — Per-repo analysis
# ---------------------------------------------------------------------------
analyse_repo <- function(slug, display) {
  info <- gh_json(sprintf("repos/%s", slug))
  if (is.null(info)) return(list(slug = slug, name = display, error = "cannot read repo via gh api"))
  branch <- info$default_branch
  res <- list(slug = slug, name = display, branch = branch, private = isTRUE(info$private))

  rels <- gh_json(sprintf("repos/%s/releases?per_page=30", slug)) %||% list()
  rels <- Filter(function(r) !isTRUE(r$draft) && !isTRUE(r$prerelease), rels)
  tip_sha <- (gh_json(sprintf("repos/%s/commits/%s", slug, branch)) %||% list())$sha

  cff_txt  <- gh_file(slug, "CITATION.cff", branch)
  cff      <- if (!is.null(cff_txt)) tryCatch(yaml::yaml.load(cff_txt), error = function(e) NULL) else NULL
  desc_txt <- gh_file(slug, "DESCRIPTION", branch)
  desc_ver <- if (!is.null(desc_txt)) {
    m <- regmatches(desc_txt, regexec("(?m)^Version:\\s*([0-9.]+)", desc_txt, perl = TRUE))[[1]]
    if (length(m) == 2L) m[2] else NA_character_
  } else NA_character_

  res$cff <- cff; res$cff_txt <- cff_txt; res$has_description <- !is.null(desc_txt)
  res$desc_version <- desc_ver; res$tip_sha <- tip_sha
  res$concept_doi <- cff$doi %||% NULL
  res$zenodo_hook <- has_zenodo_hook(slug)

  # --- No release yet: first-release candidate --------------------------------
  if (length(rels) == 0L) {
    res$latest_tag <- NA_character_
    res$first_release <- TRUE
    res$level <- "first"
    res$next_version <- if (!is.na(desc_ver)) desc_ver else "1.0.0"
    res$conf <- "n/a"
    res$evidence <- list("no GitHub release exists yet")
    res$commits <- list()
    return(res)
  }

  tag <- rels[[1]]$tag_name
  res$latest_tag <- tag; res$tag_date <- substr(rels[[1]]$published_at %||% "", 1, 10)
  res$first_release <- FALSE
  ver <- parse_version(tag)
  if (is.null(ver)) { res$error <- sprintf("latest tag '%s' is not semver", tag); return(res) }
  res$tag_commit <- (gh_json(sprintf("repos/%s/commits/%s", slug, tag)) %||% list())$sha

  base_ref <- opts$since[[display]] %||% tag
  if (!identical(base_ref, tag)) res$base_override <- base_ref
  cmp <- compare_range(slug, base_ref, branch)
  if (is.null(cmp)) { res$error <- "compare API failed"; return(res) }
  res$commits <- cmp$commits; res$files <- cmp$files
  res$ahead_by <- cmp$meta$ahead_by

  sigs <- c(commit_signals(cmp$commits), file_signals(cmp$files))
  sm <- summarise_signals(sigs)
  res$level <- sm$level; res$conf <- sm$conf
  res$evidence <- vapply(sm$top, function(s) s$reason, character(1))
  res$all_signals <- sigs
  if (sm$level != "none") {
    nv <- next_version(ver, sm$level)
    res$next_version <- nv$version; res$shifted <- nv$shifted
  }

  # --- Metadata drift ---------------------------------------------------------
  tagv <- paste(ver, collapse = ".")
  warn <- character(0)
  if (!is.na(desc_ver) && desc_ver != tagv) {
    warn <- c(warn, sprintf("DESCRIPTION Version %s != latest tag %s", desc_ver, tag))
  }
  if (!is.null(cff$version) && as.character(cff$version) != tagv) {
    warn <- c(warn, sprintf("CITATION.cff version %s != latest tag %s", cff$version, tag))
  }
  if (isFALSE(res$zenodo_hook)) warn <- c(warn, "no Zenodo webhook found: releases will not be archived")
  if (opts$zenodo && !is.null(res$concept_doi)) {
    zv <- zenodo_latest_version(res$concept_doi)
    res$zenodo_version <- zv
    if (!is.na(zv) && sub("^v", "", zv) != tagv) {
      warn <- c(warn, sprintf("latest Zenodo version (%s) != latest tag (%s): the release may not have been archived", zv, tag))
    }
  }
  res$warnings <- warn
  res
}

# ---------------------------------------------------------------------------
# Section 9 — Release-notes drafting
# ---------------------------------------------------------------------------
draft_notes <- function(r, version) {
  buckets <- list(Features = character(0), Fixes = character(0),
                  Documentation = character(0), Other = character(0))
  for (cm in r$commits) {
    subj <- strsplit(cm$commit$message, "\n", fixed = TRUE)[[1]][1]
    type <- sub("^([a-z]+)(\\([^)]*\\))?!?:.*$", "\\1", subj)
    text <- sub("^[a-z]+(\\([^)]*\\))?!?:\\s*", "", subj)
    key <- switch(type, feat = "Features", fix = "Fixes", docs = "Documentation", "Other")
    buckets[[key]] <- c(buckets[[key]], text)
  }
  title <- r$cff$title %||% r$name
  title <- gsub("\\s+", " ", trimws(as.character(title)))
  out <- c(sprintf("## %s v%s", title, version), "",
           "<!-- DRAFT generated by scripts/release_check.R from commit subjects; edit before publishing. -->", "")
  for (k in names(buckets)) {
    if (length(buckets[[k]]) == 0L) next
    out <- c(out, sprintf("### %s", k), "", paste0("- ", buckets[[k]]), "")
  }
  out <- c(out, "### Citing", "",
           "See `CITATION.cff`. A DOI is minted by Zenodo for this release.", "",
           "### License", "",
           sprintf("%s. Copyright %s Duke University.", r$cff$license %||% "GPL-2.0-only",
                   format(Sys.Date(), "%Y")))
  if (!is.null(r$cff_txt) && grepl("K12TR005435", r$cff_txt, fixed = TRUE)) {
    out <- c(out, "",
      paste("Research reported in this publication was supported by the National Center For",
            "Advancing Translational Sciences of the National Institutes of Health under Award",
            "Number K12TR005435. The content is solely the responsibility of the authors and",
            "does not necessarily represent the official views of the National Institutes of Health."))
  }
  out
}

# ---------------------------------------------------------------------------
# Section 10 — Gather the repo list
# ---------------------------------------------------------------------------
resolve_workspace_root <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  cand <- if (length(file_arg) == 1L) normalizePath(file.path(dirname(file_arg), "..")) else normalizePath(getwd())
  cand
}
root <- resolve_workspace_root()

slug_from_remote <- function(name) {
  out <- suppressWarnings(system2("git", c("-C", shQuote(root), "remote", "get-url", name),
                                  stdout = TRUE, stderr = FALSE))
  if (!is.null(attr(out, "status")) || length(out) == 0L) return(NULL)
  m <- regmatches(out[1], regexec("github\\.com[:/]([^/]+/[^/]+?)(\\.git)?$", out[1]))[[1]]
  if (length(m) >= 2L) m[2] else NULL
}

targets <- list()   # slug -> display name
add_target <- function(slug, name = NULL) {
  if (is.null(slug) || slug %in% names(targets)) return(invisible())
  targets[[slug]] <<- name %||% sub("^.*/", "", slug)
}

reg_path <- file.path(root, "studies.yaml")
if (file.exists(reg_path)) {
  reg <- yaml::read_yaml(reg_path)
  for (e in reg$templates %||% list()) if (!is.null(e$github)) add_target(e$github, e$template_name)
  for (s_ in reg$release_repos %||% list()) add_target(s_)
}
add_target(slug_from_remote("charon"))
add_target(slug_from_remote("origin"))
for (s in opts$repos) add_target(s)
if (!is.null(opts$only)) targets <- targets[vapply(names(targets), function(s) sub("^.*/", "", s) == opts$only, logical(1))]

if (length(targets) == 0L) stop("No repos to check. Register templates in studies.yaml or pass --repo OWNER/NAME.")

# ---------------------------------------------------------------------------
# Section 11 — Run the analysis
# ---------------------------------------------------------------------------
message("[release_check] Reading ", length(targets), " repo(s) via gh api ...")
results <- Map(function(slug, name) analyse_repo(slug, name), names(targets), unname(targets))
errors <- Filter(function(r) !is.null(r$error), results)

# Private repos with no releases (e.g. the lab workspace) are not Zenodo
# candidates; drop them quietly.
results <- Filter(function(r) !(isTRUE(r$private) && isTRUE(r$first_release)), results)

# Submodule dependencies: for each repo with a .gitmodules, map to checked repos.
deps <- list()
for (r in results) {
  if (!is.null(r$error)) next
  gm <- parse_gitmodules(gh_file(r$slug, ".gitmodules", r$branch))
  gm <- Filter(function(x) x$slug %in% names(results), gm)
  if (length(gm) > 0L) deps[[r$slug]] <- gm
}

pointer_state <- function(parent, d) {
  dep <- results[[d$slug]]
  if (is.null(dep) || !is.null(dep$error)) return("unknown")
  node <- gh_json(sprintf("repos/%s/contents/%s?ref=%s", parent$slug, d$path, parent$branch))
  ptr <- node$sha
  if (is.null(ptr)) return("unknown")
  s <- substr(ptr, 1, 7)
  if (identical(ptr, dep$tip_sha)) {
    if (!is.null(dep$tag_commit) && identical(ptr, dep$tag_commit)) return(sprintf("%s = latest release %s (and main)", s, dep$latest_tag))
    if (is.na(dep$latest_tag %||% NA)) return(sprintf("%s = main (%s has no release yet)", s, dep$name))
    qual <- if (identical(dep$level, "none")) "only non-release-worthy changes" else "release-worthy changes"
    return(sprintf("%s = main (%s since %s)", s, qual, dep$latest_tag))
  }
  if (!is.null(dep$tag_commit) && identical(ptr, dep$tag_commit)) return(sprintf("%s = latest release %s; main is ahead", s, dep$latest_tag))
  behind <- gh_json(sprintf("repos/%s/compare/%s...%s", d$slug, ptr, dep$branch))
  sprintf("%s is %s commit(s) behind %s main", s, behind$ahead_by %||% "?", dep$name)
}

# ---------------------------------------------------------------------------
# Section 12 — Report
# ---------------------------------------------------------------------------
out <- character(0)
emit <- function(...) out <<- c(out, paste0(...))

emit("# Release check — ", format(Sys.Date()))
emit("")
emit("| Repo | Latest release | Commits since | Recommendation | Next | Confidence |")
emit("|---|---|---:|---|---|---|")
for (r in results) {
  if (!is.null(r$error)) { emit("| ", r$name, " | — | — | ERROR: ", r$error, " | — | — |"); next }
  rec <- if (isTRUE(r$first_release)) "first release" else r$level
  nxt <- if (isTRUE(r$first_release)) paste0("v", r$next_version) else if (r$level == "none") "—" else paste0("v", r$next_version)
  emit("| ", r$name, " | ", if (is.na(r$latest_tag %||% NA)) "none" else r$latest_tag, " | ", r$ahead_by %||% "—", " | **", rec, "** | ", nxt, " | ", r$conf, " |")
}
emit("")

emit("## Evidence")
for (r in results) {
  if (!is.null(r$error)) next
  emit("")
  emit("### ", r$name, if (isTRUE(r$first_release)) "" else paste0(" (", r$base_override %||% r$latest_tag, " -> ", r$branch, ")"),
       if (!is.null(r$base_override)) paste0(" [diff base overridden; version math still from ", r$latest_tag, "]") else "")
  if (isTRUE(r$first_release)) {
    emit("- No GitHub release yet; first-release candidate **v", r$next_version, "**",
         if (!is.na(r$desc_version)) " (taken from DESCRIPTION)" else "", ".")
  } else if (r$level == "none") {
    emit("- No release-worthy changes (", length(r$commits), " commit(s), ", length(r$files),
         " file(s): docs, metadata, CI, or comment-only).")
  } else {
    ev <- r$evidence
    if (length(ev) > 8L) ev <- c(ev[1:8], sprintf("... and %d more signal(s) at this level", length(ev) - 8L))
    for (e in ev) emit("- ", e)
    if (isTRUE(r$shifted)) emit("- Version 0.y.z: semver shifts the bump down one slot (breaking -> minor, feature/fix -> patch).")
  }
  for (w in r$warnings %||% character(0)) emit("- WARNING: ", w)
  zh <- r$zenodo_hook
  emit("- Zenodo webhook: ", if (is.na(zh)) "unknown (needs admin)" else if (zh) "present" else "ABSENT",
       if (!is.null(r$concept_doi)) paste0("; concept DOI ", r$concept_doi) else "; no doi in CITATION.cff")
  if (!is.null(deps[[r$slug]])) {
    emit("- Submodule pointers:")
    for (d in deps[[r$slug]]) emit("  - ", d$path, ": ", pointer_state(r, d))
  }
}
emit("")

# --- The plan -----------------------------------------------------------------
needs <- Filter(function(r) is.null(r$error) && (isTRUE(r$first_release) || r$level != "none"), results)
dependents_of <- function(slug) names(Filter(function(ds) any(vapply(ds, function(d) d$slug == slug, logical(1))), deps))
# Dependencies first: a repo that something else vendors is released before it.
order_key <- vapply(needs, function(r) if (length(dependents_of(r$slug)) > 0L) 0L else 1L, integer(1))
needs <- needs[order(order_key)]

emit("## Plan")
emit("")
if (length(needs) == 0L) {
  emit("No repo warrants a new release. Nothing to do.")
} else {
  emit("Run in this order (dependencies before the repos that vendor them). Nothing below has been executed.")
  today <- format(Sys.Date())
  step <- 0L
  notes_files <- list()
  for (r in needs) {
    step <- step + 1L
    ver <- r$next_version
    kind <- if (isTRUE(r$first_release)) "first release" else sprintf("%s -> v%s (%s, confidence %s)", r$latest_tag, ver, r$level, r$conf)
    emit("")
    emit("### ", step, ". ", r$name, " — ", kind)
    emit("")
    emit("1. In a clone of `", r$slug, "` on your personal branch, edit:")
    emit("   - `CITATION.cff`: set `date-released: \"", today, "\"`",
         if (!is.null(r$cff$version)) paste0(" and `version: \"", ver, "\"`") else " (it has no `version` field; leave it out)", ".")
    if (isTRUE(r$has_description)) emit("   - `DESCRIPTION`: set `Version: ", ver, "`.")
    emit("2. Open the PR, squash-merge it, then reset your branch (CLAUDE.md \"After a PR is merged\"):")
    emit("   ```bash")
    emit("   BRANCH=$(gh api user --jq .login)")
    emit("   gh pr create --repo ", r$slug, " --base ", r$branch, " --head \"$(gh api user --jq .login)\" --title \"chore: release v", ver, "\"")
    emit("   gh pr merge <N> --repo ", r$slug, " --squash --admin")
    emit("   git fetch origin && git diff origin/", r$branch, " \"$BRANCH\" --stat   # must be empty")
    emit("   git reset --mixed origin/", r$branch, " && git push --force-with-lease origin \"$BRANCH\"")
    emit("   ```")
    notes_name <- sprintf("notes/%s_v%s.md", r$name, ver)
    notes_files[[notes_name]] <- draft_notes(r, ver)
    notes_cmd_path <- if (!is.null(opts$out_dir)) file.path(opts$out_dir, notes_name) else notes_name
    emit("3. Publish the release (edit the drafted notes first",
         if (!is.null(opts$out_dir)) paste0(": `", notes_cmd_path, "`") else " — rerun with `--out-dir DIR` to write them", "):")
    emit("   ```bash")
    emit("   gh release create v", ver, " --repo ", r$slug, " --target ", r$branch, " \\")
    emit("     --title \"", r$name, " v", ver, "\" --notes-file ", notes_cmd_path)
    emit("   ```")
    if (isFALSE(r$zenodo_hook)) emit("   - FIRST enable this repo in Zenodo (GitHub integration) — it has no webhook, so this release would not be archived.")
    emit("4. Verify Zenodo archived it: the new version should appear under the concept DOI",
         if (!is.null(r$concept_doi)) paste0(" `", r$concept_doi, "`") else " (add `doi:` to CITATION.cff after the first record exists)",
         "; the webhook delivery list shows one 202 and several 409 duplicates.")
    deps_of_me <- dependents_of(r$slug)
    if (length(deps_of_me) > 0L) emit("5. Then bump this submodule's pointer in: ", paste0("`", deps_of_me, "`", collapse = ", "), " (do that before releasing them).")
  }
  emit("")
  emit("Finally, bump submodule pointers in the lab workspace (`omop-dev-workspace`) to the new template releases, and record any new version DOIs in the READMEs.")
}

cat(paste(out, collapse = "\n"), "\n", sep = "")

if (!is.null(opts$out_dir)) {
  dir.create(file.path(opts$out_dir, "notes"), recursive = TRUE, showWarnings = FALSE)
  writeLines(out, file.path(opts$out_dir, "release_plan.md"))
  if (exists("notes_files")) for (n in names(notes_files)) writeLines(notes_files[[n]], file.path(opts$out_dir, n))
  message("[release_check] Wrote ", file.path(opts$out_dir, "release_plan.md"), " and drafted notes.")
}

if (length(errors) > 0L) quit(status = 1L, save = "no")
