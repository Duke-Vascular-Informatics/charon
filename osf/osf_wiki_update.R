# =============================================================================
# osf/osf_wiki_update.R — Generate and push per-study OSF home wikis
#
# Purpose:
#   Renders a home-wiki markdown page for every study with an OSF project in
#   osf/osf_projects.csv, describing the study as declared in its
#   study_params.yaml and the analysis pipeline executed by
#   workflow/08_run_analysis_and_manuscript_report.R, then pushes it to OSF.
#
# Inputs:
#   osf/osf_projects.csv          — study → OSF GUID (created by osf_sync.R)
#   studies.yaml                  — registry descriptions (fallback text)
#   <study>/study_params.yaml     — study identity, cohorts, windows, analyses
#   OSF_PAT                       — token, .env file checked before env var
#
# Outputs / side effects:
#   - Creates or updates the "home" wiki on each study's OSF project.
#     Updates are NEW WIKI VERSIONS — OSF keeps the full wiki history.
#   - Saves each rendered page to osf/wiki/<study>.md so the pushed content
#     is reviewable in git (the directory is committed, not gitignored).
#
# Privacy: wikis are pushed to PRIVATE projects only; this script never
# changes project visibility (see CLAUDE.md "OSF Protocol Hosting").
#
# API note: osfr (0.2.9) has no wiki support, so the two wiki endpoints are
# called directly via httr:
#   GET  /v2/nodes/{guid}/wikis/        — find the "home" wiki page id
#   POST /v2/nodes/{guid}/wikis/        — create "home" when absent
#   POST /v2/wikis/{id}/versions/       — push new content as a new version
#
# Usage:
#   Rscript osf/osf_wiki_update.R              # render + push all studies
#   Rscript osf/osf_wiki_update.R --dry-run    # render to osf/wiki/ only
# =============================================================================

library(yaml)
library(readr)
library(dplyr)
library(httr)
library(jsonlite)

# ============================================================
# Section 1 — Workspace root and inputs
# ============================================================
resolve_workspace_root <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  candidate <- if (length(file_arg) == 1) {
    normalizePath(file.path(dirname(file_arg), ".."))
  } else {
    normalizePath(getwd())
  }
  if (!file.exists(file.path(candidate, "studies.yaml"))) {
    stop("Cannot locate studies.yaml from '", candidate, "'.")
  }
  candidate
}

workspace_root <- resolve_workspace_root()
dry_run <- "--dry-run" %in% commandArgs(trailingOnly = TRUE)
# Optional --study=<dir> scopes a run to one study, so a rendering change
# aimed at one study's page doesn't silently rewrite every other study's
# already-existing wiki in the same run.
study_filter <- sub("^--study=", "",
                    grep("^--study=", commandArgs(trailingOnly = TRUE), value = TRUE))
study_filter <- if (length(study_filter) == 1) study_filter else NULL

state <- read_csv(file.path(workspace_root, "osf", "osf_projects.csv"),
                  col_types = cols(.default = col_character()))
registry <- yaml::read_yaml(file.path(workspace_root, "studies.yaml"))
descriptions <- setNames(
  vapply(registry$studies, function(s) s$description, character(1)),
  vapply(registry$studies, function(s) s$dir, character(1))
)
githubs <- setNames(
  vapply(registry$studies, function(s) if (is.null(s$github)) "" else s$github,
         character(1)),
  vapply(registry$studies, function(s) s$dir, character(1))
)

# ============================================================
# Section 2 — Authenticate (file before env var; see osf_sync.R rationale)
# ============================================================
read_env_fallback <- function(name, env_file) {
  if (!file.exists(env_file)) return("")
  lines <- readLines(env_file, warn = FALSE)
  hit <- grep(paste0("^", name, "="), lines, value = TRUE)
  if (length(hit) == 0) return("")
  gsub("^['\"]|['\"]$", "", sub(paste0("^", name, "="), "", hit[1]))
}

osf_pat <- trimws(read_env_fallback("OSF_PAT", file.path(workspace_root, ".env")))
if (!nzchar(osf_pat)) osf_pat <- trimws(Sys.getenv("OSF_PAT", unset = ""))
if (!dry_run && (!nzchar(osf_pat) || osf_pat == "your_osf_token_here")) {
  stop("OSF_PAT is not set — see .env.example.")
}
auth <- httr::add_headers(Authorization = paste("Bearer", osf_pat))
api  <- "https://api.osf.io/v2"

# ============================================================
# Section 3 — Wiki content rendering
# ============================================================
# Human-readable labels for the analyses: flags in study_params.yaml, matching
# the analysis blocks in workflow/08 Section 7. Order mirrors workflow/08.
analysis_labels <- c(
  cohort_characterization =
    "**Cohort characterization** — FeatureExtraction default covariate summary of the target cohort (`FeatureExtraction::getDbCovariateData`)",
  prognostic_model =
    "**Prognostic model development** — PatientLevelPrediction pipeline (LASSO logistic regression default)",
  causal_inference =
    "**Causal inference** — CohortMethod propensity-score matching with a Cox outcome model (target vs. comparator cohort)",
  integer_risk_score =
    "**Integer risk score validation** — applies the published integer point score from `covariates/covariates.csv` (points column) with optional score-to-probability lookup (`covariates/risk_lookup.csv`)",
  plp_model_validation =
    "**PLP model external validation** — applies the pre-built model from `model/` to the local cohort; writes person-level scores, covariate summary, and discrimination/calibration metrics",
  word_report =
    "**Manuscript report** — Word report assembled from the pipeline outputs (`R/report_extended.R`)"
)

# The fixed scaffolding every study executes in workflow/08 before Section 7;
# stated once so readers see the full execution context, not just the
# study-specific analysis blocks.
pipeline_preamble <- paste(
  "1. Workflow bootstrap, renv activation, and configuration load (`study_params.yaml` -> `config.R`)",
  "2. Java/JDBC session guard and package load (DatabaseConnector + HADES stack)",
  "3. Database connection to the OMOP CDM (SQL Server)",
  "4. Verification of every study concept ID against the live `omop_vocab` vocabulary",
  "5. Results-schema preparation and cohort instantiation from the SQL definitions in `cohorts/`",
  sep = "\n")

# Renders an "## Investigators" section from the workspace-root
# contributors.yaml (the same source scripts/sync_contributors.R reads to
# generate each repo's own CONTRIBUTORS.md / CITATION.cff), filtered to
# contributors who list this study_dir -- or the wildcard "*" -- under
# their own `repos`. Returns "" (not NULL) when the registry is missing or
# no entry applies, so callers can paste0() it unconditionally.
render_investigators <- function(study_dir) {
  contrib_path <- file.path(workspace_root, "contributors.yaml")
  if (!file.exists(contrib_path)) return("")
  reg <- tryCatch(yaml::read_yaml(contrib_path), error = function(e) NULL)
  people <- reg$contributors
  if (is.null(people)) return("")

  rows <- character(0)
  for (person in people) {
    repo_entry <- NULL
    for (r in person$repos %||% list()) {
      if (identical(r$repo, study_dir) || identical(r$repo, "*")) {
        repo_entry <- r
        if (identical(r$repo, study_dir)) break  # study-specific beats "*"
      }
    }
    if (is.null(repo_entry)) next

    name <- trimws(paste(person$given_names %||% "", person$family_names %||% ""))
    if (!is.null(person$name_suffix) && nzchar(person$name_suffix)) {
      name <- paste0(name, ", ", person$name_suffix)
    }
    affils <- vapply(person$affiliations %||% list(), function(a) a$name %||% "",
                     character(1))
    affils <- paste(affils[nzchar(affils)], collapse = "; ")
    roles <- paste(unlist(repo_entry$credit %||% list()), collapse = ", ")
    rows <- c(rows, paste0("| ", name, " | ", affils, " | ", roles, " |"))
  }
  if (length(rows) == 0) return("")

  paste0("\n## Investigators\n\n",
        "| Name | Affiliation(s) | Role(s) on this study |\n",
        "|---|---|---|\n", paste(rows, collapse = "\n"), "\n")
}

# For a study whose protocol is authored directly as docs/PROTOCOL.md
# (Strategus-based studies -- study_params.yaml there doesn't carry the
# legacy cohorts/sql_file/analyses: shape this script's generic cohort/
# pipeline rendering below expects, so forcing that rendering onto them
# produces confidently wrong text, e.g. "no analysis blocks enabled" for a
# study whose analysis already ran to completion). Extracts the protocol's
# own "1. Background and Rationale" and "2. Objectives" sections verbatim
# (the one heading pair confirmed consistent across every current
# docs/PROTOCOL.md) as the page body, rather than re-deriving a summary
# that could drift out of sync with the protocol.
render_from_protocol <- function(study_dir) {
  protocol_rel <- "docs/PROTOCOL.md"
  protocol_path <- file.path(workspace_root, study_dir, protocol_rel)
  if (!file.exists(protocol_path)) return(NULL)

  lines <- readLines(protocol_path, warn = FALSE)
  start <- grep("^##\\s*1\\.", lines)[1]
  end   <- grep("^##\\s*3\\.", lines)[1]
  if (is.na(start)) return(NULL)
  body_lines <- if (!is.na(end) && end > start) lines[start:(end - 1)] else lines[start:length(lines)]
  body <- paste(trimws(body_lines, which = "right"), collapse = "\n")

  # Regulatory/IRB coverage is matched by heading TEXT, not a fixed section
  # number -- it is Section 10 in one protocol and Section 11 in another,
  # and matching on wording is more robust than assuming a number stays
  # put as a protocol's own sections get inserted/renumbered over time.
  reg_start <- grep("^##\\s*[0-9]+\\.\\s*Regulatory and Ethical Considerations", lines)[1]
  reg_block <- if (!is.na(reg_start)) {
    reg_end <- grep("^## ", lines)[grep("^## ", lines) > reg_start][1]
    reg_lines <- if (!is.na(reg_end)) lines[reg_start:(reg_end - 1)] else lines[reg_start:length(lines)]
    paste0(paste(trimws(reg_lines, which = "right"), collapse = "\n"), "\n\n")
  } else ""

  paste0(
    trimws(body), "\n\n",
    reg_block,
    "_Full study design, data source, population, analysis plan, and ",
    "limitations are in the attached `PROTOCOL.md` (under Files) -- summarized ",
    "here are only its Background/Objectives and Regulatory/Ethical ",
    "Considerations sections, kept intentionally unparaphrased so this page ",
    "cannot drift out of sync with the protocol it is drawn from._\n")
}

# Renders one study's wiki markdown from its study_params.yaml; returns a
# minimal registry-based page when the study has no params file (e.g. an
# externally managed Strategus repo that doesn't carry that file).
render_wiki <- function(study_dir) {
  desc <- descriptions[[study_dir]] %||% ""
  params_path <- file.path(workspace_root, study_dir, "study_params.yaml")

  # H1 is the human-readable study title from osf_projects.csv (kept in sync
  # with the OSF project title by osf_sync.R); the repo name appears as a
  # metadata line so the page still links back to the analysis code.
  title <- state$title[state$study_dir == study_dir]
  title <- if (length(title) == 1 && !is.na(title) && nzchar(title)) title else study_dir
  gh <- if (study_dir %in% names(githubs)) githubs[[study_dir]] else ""
  repo_line <- if (nzchar(gh)) {
    paste0("**Analysis repository:** [", study_dir,
           "](https://github.com/", gh, ")\n\n")
  } else {
    paste0("**Analysis repository:** `", study_dir, "`\n\n")
  }

  header <- paste0(
    "# ", title, "\n\n", desc, "\n\n", repo_line,
    "> **Status: DRAFT — private.** This protocol is not approved for public release. ",
    "Protocol documents are attached under Files; this page is generated from the ",
    "study repository and updated by `osf/osf_wiki_update.R`.\n")

  investigators_md <- render_investigators(study_dir)

  protocol_body <- render_from_protocol(study_dir)
  if (!is.null(protocol_body)) {
    design_rows_protocol <- if (file.exists(params_path)) {
      pp <- yaml::read_yaml(params_path)
      c(
        if (!is.null(pp$study_design)) paste0("| Study design | ", pp$study_design, " |"),
        if (!is.null(pp$study_start_date) && !is.null(pp$study_end_date))
          paste0("| Study period | ", pp$study_start_date, " to ", pp$study_end_date, " |"))
    } else character(0)
    design_block <- if (length(design_rows_protocol) > 0) {
      paste0("## Study design\n\n| | |\n|---|---|\n",
            paste(design_rows_protocol, collapse = "\n"), "\n\n")
    } else ""
    return(paste0(header, "\n", design_block, protocol_body, investigators_md))
  }

  if (!file.exists(params_path)) {
    return(paste0(
      header, "\n",
      "This study is managed in an external network-study repository ",
      "(see the workspace registry); study parameters and analysis code live ",
      "upstream rather than in a local `study_params.yaml`. The attached ",
      "protocol documents are the authoritative description.\n",
      investigators_md))
  }

  p <- yaml::read_yaml(params_path)

  # --- Study design table -------------------------------------------------
  # Only rows whose values are actually set are emitted, so studies with
  # placeholder TODOs do not advertise misleading defaults.
  fmt_row <- function(label, value) {
    if (is.null(value) || (is.character(value) && !nzchar(value))) return(NULL)
    paste0("| ", label, " | ", value, " |")
  }
  design_rows <- c(
    fmt_row("Study design", p$study_design),
    fmt_row("Study period", paste(p$study_start_date, "to", p$study_end_date)),
    fmt_row("Prediction / outcome window",
            if (!is.null(p$prediction_window_days))
              paste0(p$prediction_window_days, " days after index")),
    fmt_row("Minimum prior observation",
            if (!is.null(p$min_prior_observation_days))
              paste0(p$min_prior_observation_days, " days")),
    fmt_row("Covariate lookback",
            if (!is.null(p$covariate_lookback_days))
              paste0(p$covariate_lookback_days, " days before index")))

  # --- Model reference (validation studies) -------------------------------
  mr <- p$model_reference
  model_rows <- if (!is.null(mr)) c(
    fmt_row("Model under validation", mr$score_name),
    fmt_row("Model type", mr$model_type),
    fmt_row("Source publication", mr$source_paper),
    fmt_row("DOI", if (!is.null(mr$doi) && nzchar(mr$doi)) mr$doi),
    fmt_row("Time at risk", if (!is.null(mr$time_at_risk_days))
      paste0(mr$time_at_risk_days, " days")))

  # --- Cohorts -------------------------------------------------------------
  # Concept ID 0 is the template's TODO placeholder (concept set not yet
  # verified against the live vocabulary) — never publish it as if it were a
  # real definition.
  real_ids <- function(ids) {
    ids <- unlist(ids)
    ids[!is.null(ids) & ids != 0]
  }
  cohort_block <- function(name, ch) {
    if (is.null(ch) || is.null(ch$cohort_id)) return(NULL)
    ids <- real_ids(ch$index_event$ancestor_concept_ids)
    paste0(
      "**", name, "** (`", ch$sql_file, "`)",
      if (!is.null(ch$min_age_at_index) && ch$min_age_at_index > 0)
        paste0(" — age ≥ ", ch$min_age_at_index, " at index"),
      if (length(ids) > 0)
        paste0("; index event: ", ch$index_event$domain,
               " concept ancestors ", paste(ids, collapse = ", "))
      else
        "; index event concept set pending vocabulary verification",
      if (length(real_ids(ch$washout$ancestor_concept_ids)) > 0)
        paste0("; washout: prior qualifying condition within ",
               ch$washout$lookback_days, " days excluded"))
  }
  outcome_line <- if (!is.null(p$outcome) && !is.null(p$outcome$cohort_id)) {
    ids <- real_ids(p$outcome$ancestor_concept_ids)
    paste0("**Outcome** (`", p$outcome$sql_file, "`)",
           if (length(ids) > 0)
             paste0(" — anchor concept ancestors ",
                    paste(ids, collapse = ", "),
                    " (see the SQL file for the full concept set)")
           else
             " — outcome concept set pending vocabulary verification")
  }
  cohort_lines <- Filter(Negate(is.null), list(
    cohort_block("Target cohort", p$target),
    outcome_line,
    cohort_block("Comparator cohort", p$comparator)))

  # --- Enabled analyses (drives workflow/08 Section 7) ---------------------
  enabled <- names(Filter(isTRUE, p$analyses))
  enabled <- enabled[enabled %in% names(analysis_labels)]  # keep workflow order
  enabled <- names(analysis_labels)[names(analysis_labels) %in% enabled]
  analysis_lines <- if (length(enabled) > 0) {
    paste0(seq_along(enabled) + 5, ". ", analysis_labels[enabled], collapse = "\n")
  } else {
    "_No analysis blocks are enabled yet in `study_params.yaml`._"
  }

  paste0(
    header,
    "\n## Study design\n\n",
    "| | |\n|---|---|\n", paste(design_rows, collapse = "\n"), "\n",
    if (length(model_rows) > 0)
      paste0("\n## Model under validation\n\n| | |\n|---|---|\n",
             paste(model_rows, collapse = "\n"), "\n"),
    "\n## Cohorts\n\n",
    paste0("- ", unlist(cohort_lines), collapse = "\n"), "\n",
    "\n## Analysis pipeline (workflow/08)\n\n",
    "All analyses run on an OMOP CDM v5.4 database via the OHDSI HADES ",
    "toolstack, driven entirely by `study_params.yaml`:\n\n",
    pipeline_preamble, "\n", analysis_lines, "\n",
    investigators_md,
    "\n---\n_Generated from `study_params.yaml` and ",
    "`workflow/08_run_analysis_and_manuscript_report.R` on ",
    format(Sys.Date()), "._\n")
}

# `%||%` — yaml::read_yaml returns NULL for missing keys; this keeps the
# rendering code free of repetitive is.null() guards.
`%||%` <- function(a, b) if (is.null(a)) b else a

# ============================================================
# Section 4 — Push to OSF (create home wiki or add a new version)
# ============================================================
push_wiki <- function(guid, content) {
  # Find the existing home wiki page, if any
  resp <- httr::GET(paste0(api, "/nodes/", guid, "/wikis/"), auth)
  httr::stop_for_status(resp, task = paste("list wikis for", guid))
  pages <- jsonlite::fromJSON(httr::content(resp, "text", encoding = "UTF-8"),
                              simplifyVector = FALSE)$data
  home_id <- NULL
  for (pg in pages) if (identical(pg$attributes$name, "home")) home_id <- pg$id

  if (is.null(home_id)) {
    # First write: creating the page sets its initial content
    body <- list(data = list(type = "wikis",
                             attributes = list(name = "home", content = content)))
    resp <- httr::POST(paste0(api, "/nodes/", guid, "/wikis/"), auth,
                       body = jsonlite::toJSON(body, auto_unbox = TRUE),
                       httr::content_type("application/json"))
    httr::stop_for_status(resp, task = paste("create home wiki for", guid))
  } else {
    # Subsequent writes: each push is a new version, history is preserved
    body <- list(data = list(type = "wiki-versions",
                             attributes = list(content = content)))
    resp <- httr::POST(paste0(api, "/wikis/", home_id, "/versions/"), auth,
                       body = jsonlite::toJSON(body, auto_unbox = TRUE),
                       httr::content_type("application/json"))
    httr::stop_for_status(resp, task = paste("update home wiki for", guid))
  }
}

# ============================================================
# Section 5 — Render and push every project
# ============================================================
wiki_dir <- file.path(workspace_root, "osf", "wiki")
dir.create(wiki_dir, showWarnings = FALSE)

targets <- state |> filter(!is.na(osf_guid), nzchar(osf_guid))
if (!is.null(study_filter)) {
  targets <- targets |> filter(study_dir == study_filter)
  if (nrow(targets) == 0) stop("No OSF-registered study matches --study=", study_filter)
}

for (i in seq_len(nrow(targets))) {
  study <- targets$study_dir[i]
  guid  <- targets$osf_guid[i]
  md    <- render_wiki(study)

  # Local copy first so the exact pushed content is always reviewable in git
  write_lines(md, file.path(wiki_dir, paste0(study, ".md")))

  if (dry_run) {
    message("[dry-run] Rendered osf/wiki/", study, ".md (not pushed)")
    next
  }
  message("Pushing home wiki: ", study, " (https://osf.io/", guid, ")")
  push_wiki(guid, md)
}

message(if (dry_run) "Dry run complete — pages rendered to osf/wiki/ only."
        else "Wiki update complete.")
