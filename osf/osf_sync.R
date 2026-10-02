# =============================================================================
# osf/osf_sync.R — Create and maintain per-study OSF projects
#
# Purpose:
#   Mirrors the workspace study registry (studies.yaml) onto the Open Science
#   Framework (osf.io): one PRIVATE OSF project per registered study, with
#   protocol documents uploaded and versioned automatically.
#
# Inputs:
#   studies.yaml          — workspace study registry (source of truth for the
#                           study list; descriptions become OSF descriptions)
#   osf/osf_projects.csv  — per-study OSF state: study_dir, osf_guid, sync flag.
#                           New studies found in studies.yaml are appended
#                           automatically with sync = TRUE.
#   osf/osf_files.csv     — protocol file → study mapping. Re-running after a
#                           protocol is revised uploads a NEW VERSION on OSF
#                           (same-named uploads are versioned, never lost).
#   OSF_PAT               — personal access token (scope: osf.full_write).
#                           Read from the environment, falling back to the
#                           OSF_PAT= line in the workspace .env file.
#
# Outputs / side effects:
#   - Creates missing OSF projects (PRIVATE; visibility is never changed here —
#     making a project public or minting a DOI is a manual step on osf.io).
#   - Writes newly assigned OSF GUIDs back into osf/osf_projects.csv. Commit
#     that file after a run so the GUIDs are shared with collaborators.
#   - Uploads every file listed in osf/osf_files.csv to its study's project
#     (conflicts = "overwrite" → OSF stores it as a new version).
#
# Usage:
#   Rscript osf/osf_sync.R              # full sync
#   Rscript osf/osf_sync.R --dry-run    # show planned actions, no API calls
#
# Prerequisites:
#   - osfr installed via renv (renv::install("osfr"); renv::snapshot())
#   - OSF_PAT set in .env (see .env.example for token creation instructions)
# =============================================================================

# Package selection per workspace Rule 2: osfr is the rOpenSci CRAN client for
# the OSF API v2; yaml/readr/dplyr are already in the workspace lockfile.
library(osfr)
library(yaml)
library(readr)
library(dplyr)
library(httr)      # node title PATCH — osfr 0.2.9 cannot update node attributes
library(jsonlite)

# ============================================================
# Section 1 — Locate the workspace root
# ============================================================
# The script must work both via `Rscript osf/osf_sync.R` (any CWD) and
# interactively from the workspace root, so we resolve the script's own path
# from --file= when available and fall back to the working directory.
resolve_workspace_root <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- sub("^--file=", "", grep("^--file=", args, value = TRUE))
  candidate <- if (length(file_arg) == 1) {
    normalizePath(file.path(dirname(file_arg), ".."))  # osf/ -> workspace root
  } else {
    normalizePath(getwd())                             # interactive session
  }
  # studies.yaml is the registry every workspace tool keys off — its presence
  # confirms we resolved the right directory.
  if (!file.exists(file.path(candidate, "studies.yaml"))) {
    stop("Cannot locate studies.yaml from '", candidate,
         "'. Run as: Rscript osf/osf_sync.R from the workspace root.")
  }
  candidate
}

workspace_root <- resolve_workspace_root()
projects_csv   <- file.path(workspace_root, "osf", "osf_projects.csv")
files_csv      <- file.path(workspace_root, "osf", "osf_files.csv")
dry_run        <- "--dry-run" %in% commandArgs(trailingOnly = TRUE)

# ============================================================
# Section 2 — Authenticate against OSF
# ============================================================
# Token lookup order: (1) the OSF_PAT= line of the workspace .env, then
# (2) the OSF_PAT environment variable. The FILE is checked first on purpose:
# the devcontainer captures .env into its environment at creation, so after a
# token is edited/regenerated the env var is stale until the container is
# rebuilt — reading the file directly always picks up the current value. The
# parse reads ONLY the one variable it needs — it never prints the value and
# never exports the rest of the .env file.
read_env_fallback <- function(name, env_file) {
  if (!file.exists(env_file)) return("")
  lines <- readLines(env_file, warn = FALSE)
  hit <- grep(paste0("^", name, "="), lines, value = TRUE)
  if (length(hit) == 0) return("")
  # Strip the KEY= prefix and any surrounding quotes
  gsub("^['\"]|['\"]$", "", sub(paste0("^", name, "="), "", hit[1]))
}

osf_pat <- read_env_fallback("OSF_PAT", file.path(workspace_root, ".env"))
if (!nzchar(osf_pat)) {
  osf_pat <- Sys.getenv("OSF_PAT", unset = "")
}
osf_pat <- trimws(osf_pat)  # guard against trailing whitespace from paste
# A dry run makes no API calls, so it may proceed without a token — useful
# for previewing the plan before the OSF account is even set up.
if (!nzchar(osf_pat) || osf_pat == "your_osf_token_here") {
  if (!dry_run) {
    stop("OSF_PAT is not set. Create a token (scope: osf.full_write) at ",
         "https://osf.io/settings/tokens and add it to the workspace .env ",
         "(see .env.example).")
  }
  message("[dry-run] OSF_PAT not set — continuing without authentication.")
} else if (!dry_run) {
  osf_auth(token = osf_pat)
  # Verify the token actually works BEFORE creating anything — a bad token
  # would otherwise surface mid-run as a cryptic per-project error. A 401
  # here means the token was mis-copied, revoked, or regenerated; create a
  # fresh one (scope: osf.full_write) at https://osf.io/settings/tokens.
  me <- tryCatch(
    osf_retrieve_user("me"),
    error = function(e) {
      stop("OSF rejected the token in OSF_PAT (", conditionMessage(e), "). ",
           "Re-copy or regenerate it at https://osf.io/settings/tokens ",
           "(scope: osf.full_write).")
    }
  )
  message("Authenticated to OSF as: ", me$name)
}

# ============================================================
# Section 3 — Reconcile studies.yaml with the OSF project state
# ============================================================
registry <- yaml::read_yaml(file.path(workspace_root, "studies.yaml"))

# One row per registered study: dir is the join key used everywhere in this
# workspace; description becomes the OSF project description.
studies <- bind_rows(lapply(registry$studies, function(s) {
  tibble(study_dir = s$dir, description = s$description)
}))

state <- read_csv(projects_csv, col_types = cols(.default = col_character())) |>
  mutate(sync = toupper(sync) == "TRUE")

# Auto-register: any study present in studies.yaml but missing from the state
# file gets appended with sync = TRUE, so newly created studies are picked up
# on the next run without editing osf_projects.csv by hand.
new_studies <- setdiff(studies$study_dir, state$study_dir)
if (length(new_studies) > 0) {
  message("Registering new studies from studies.yaml: ",
          paste(new_studies, collapse = ", "))
  state <- bind_rows(state, tibble(study_dir = new_studies, title = NA_character_,
                                   osf_guid = NA_character_,
                                   sync = TRUE, notes = NA_character_))
}

# Display title for a study: the human-readable title column when set,
# otherwise the repo/folder name. Fill in the title column for every new
# study — OSF project titles should describe the study, not the repo.
display_title <- function(dir) {
  t <- state$title[state$study_dir == dir]
  if (length(t) == 1 && !is.na(t) && nzchar(t)) t else dir
}

# ============================================================
# Section 4 — Create missing OSF projects (PRIVATE)
# ============================================================
to_create <- state |>
  filter(sync, is.na(osf_guid) | !nzchar(osf_guid)) |>
  pull(study_dir)

for (dir in to_create) {
  desc <- studies$description[studies$study_dir == dir]
  desc <- if (length(desc) == 1) desc else ""
  if (dry_run) {
    message("[dry-run] Would create PRIVATE OSF project: ", display_title(dir))
    next
  }
  message("Creating PRIVATE OSF project: ", display_title(dir))
  # public = FALSE is deliberate and load-bearing: IRB documents may be
  # attached before the team decides what is public-facing. Visibility is
  # only ever changed manually on osf.io.
  node <- osf_create_project(title = display_title(dir), description = desc,
                             public = FALSE)
  state$osf_guid[state$study_dir == dir] <- node$id
  message("  -> created https://osf.io/", node$id)
}

# Persist GUIDs immediately so a failure later in the run never orphans a
# created project (re-running would otherwise create duplicates).
if (!dry_run) {
  write_csv(state, projects_csv, na = "")
}

# ============================================================
# Section 4b — Reconcile titles on existing projects
# ============================================================
# The title column in osf_projects.csv is authoritative: when it differs from
# the live OSF title, the node is renamed. osfr 0.2.9 cannot update node
# attributes, so this goes through the OSF v2 node endpoint directly. The
# current title is fetched first so re-runs with no changes make no writes.
api_v2 <- "https://api.osf.io/v2"
auth_hdr <- httr::add_headers(Authorization = paste("Bearer", osf_pat))

titled <- state |>
  filter(sync, !is.na(osf_guid), nzchar(osf_guid), !is.na(title), nzchar(title))

for (i in seq_len(nrow(titled))) {
  guid <- titled$osf_guid[i]
  want <- titled$title[i]
  if (dry_run) {
    message("[dry-run] Would ensure title of ", titled$study_dir[i], " is: ", want)
    next
  }
  resp <- httr::GET(paste0(api_v2, "/nodes/", guid, "/"), auth_hdr)
  httr::stop_for_status(resp, task = paste("fetch node", guid))
  current <- jsonlite::fromJSON(
    httr::content(resp, "text", encoding = "UTF-8"))$data$attributes$title
  if (identical(current, want)) next
  message("Retitling ", titled$study_dir[i], ": '", current, "' -> '", want, "'")
  body <- list(data = list(id = guid, type = "nodes",
                           attributes = list(title = want)))
  resp <- httr::PATCH(paste0(api_v2, "/nodes/", guid, "/"), auth_hdr,
                      body = jsonlite::toJSON(body, auto_unbox = TRUE),
                      httr::content_type("application/json"))
  httr::stop_for_status(resp, task = paste("retitle node", guid))
}

# ============================================================
# Section 5 — Upload / version protocol files
# ============================================================
uploads <- read_csv(files_csv, col_types = cols(.default = col_character()))

for (i in seq_len(nrow(uploads))) {
  row        <- uploads[i, ]
  local_path <- file.path(workspace_root, row$local_path)
  guid       <- state$osf_guid[state$study_dir == row$study_dir]

  if (!file.exists(local_path)) {
    warning("Skipping missing file: ", row$local_path)
    next
  }
  if (dry_run) {
    # In a dry run, projects flagged for creation above don't have GUIDs yet —
    # report the upload as planned rather than warning about a missing project.
    will_have_project <- row$study_dir %in% state$study_dir[state$sync]
    if (will_have_project) {
      message("[dry-run] Would upload '", row$local_path, "' -> ", row$study_dir)
    } else {
      message("[dry-run] Skipping '", row$local_path, "': study '", row$study_dir,
              "' has sync = FALSE.")
    }
    next
  }
  if (length(guid) == 0 || is.na(guid) || !nzchar(guid)) {
    warning("Skipping '", row$local_path, "': study '", row$study_dir,
            "' has no OSF project yet (sync = FALSE or creation failed).")
    next
  }
  message("Uploading '", basename(local_path), "' -> ", row$study_dir,
          " (https://osf.io/", guid, ")")
  node <- osf_retrieve_node(guid)
  # conflicts = "overwrite" makes OSF store a NEW VERSION of a same-named
  # file rather than failing — this is how protocol revisions accumulate a
  # visible version history on the project page.
  osf_upload(node, path = local_path, conflicts = "overwrite")
}

message(if (dry_run) "Dry run complete — no API calls made." else "OSF sync complete.")
