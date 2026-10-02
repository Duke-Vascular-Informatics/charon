#!/usr/bin/env Rscript
# =============================================================================
# phenotype_library/scripts/push_dvi_concept_sets.R
#
# PURPOSE
# -------
# ONE-OFF, EXPLICITLY-INVOKED writer that creates label-prefixed concept sets
# (see ATLAS_LABEL_PREFIX below — "[DVI]" here is just this template's
# placeholder; use your own lab's label) on a shared OHDSI ATLAS WebAPI
# (the public demo instance has security disabled -> anonymous write; a
# private instance would need its own auth handled separately) from
# status:verified entries in phenotype_library/catalog.yaml that do not
# already have a tagged counterpart.
#
# This is the "deliberate, separate, one-off ATLAS-write action" that
# catalog.yaml / check_dvi.R describe. It is NOT wired into any search /
# refresh / sync path — it runs only when a human runs it directly, and it
# HARD-REFUSES to create anything whose target name does not literally start
# with ATLAS_LABEL_PREFIX.
#
# SAFETY GUARDS
# -------------
#   * Dry-run is the DEFAULT. Writes happen only with --commit.
#   * Every target name must start with ATLAS_LABEL_PREFIX or that entry is
#     refused (checked at plan time AND again immediately before each write).
#   * Duplicate protection is CONCEPT-BASED, not name-based: an entry is
#     skipped if >= DUP_FRAC of its concept ids are already covered by an
#     existing tagged concept set (per MEMBERS_CACHE from
#     fetch_dvi_members.R), or if a tagged set with the exact target name
#     already exists.
#   * Analytic building-block entries (BUILD_BLOCKS below) are excluded —
#     replace the placeholder list with your own catalog's internal-scaffold
#     entry ids, if any.
#   * Entries with a structured `exclusion_concept_sets:` field are DEFERRED
#     by default (see --with-exclusions to create them WITH their exclusions).
#
# PREREQUISITES
#   * Fresh cache: Rscript phenotype_library/scripts/check_dvi.R --refresh
#   * Membership cache: Rscript phenotype_library/scripts/fetch_dvi_members.R
#
# USAGE (run from workspace root):
#   Rscript phenotype_library/scripts/push_dvi_concept_sets.R                 # dry-run
#   Rscript phenotype_library/scripts/push_dvi_concept_sets.R --commit        # create CREATE rows
#   Rscript phenotype_library/scripts/push_dvi_concept_sets.R --commit --limit 1
#   Rscript phenotype_library/scripts/push_dvi_concept_sets.R --only tbad,copd
#   Rscript phenotype_library/scripts/push_dvi_concept_sets.R --with-exclusions --only seroma --commit
#
# On --commit, a machine-readable {entry_id -> dvi_id} map is written to
# /tmp/dvi_created.json for the catalog external_alignment backfill.
#
# REQUIREMENTS: yaml, jsonlite; curl on PATH; network access to ATLAS.
# =============================================================================

suppressWarnings(suppressMessages({ library(yaml); library(jsonlite) }))
`%||%` <- function(x, y) if (is.null(x)) y else x

BASE_URL           <- "https://atlas-demo.ohdsi.org/WebAPI"  # public OHDSI demo instance; point at your own if you have one
ATLAS_LABEL_PREFIX <- "[DVI]"  # TODO: replace with your own lab's label, e.g. "[MYLAB]"
DUP_FRAC      <- 0.5   # skip if >= this fraction of a candidate's concepts already in a tagged set
MEMBERS_CACHE <- "/tmp/dvi_members.json"
CREATED_MAP   <- "/tmp/dvi_created.json"
CHECKED_DATE  <- format(Sys.Date(), "%Y-%m-%d")

# Analytic building-blocks: granular scaffolding, not standalone phenotypes —
# excluded from push since they aren't meant to become their own ATLAS sets.
# Placeholder example below; replace with your own catalog's internal-scaffold
# entry ids (or an empty vector if you have none).
BUILD_BLOCKS <- c(
  "example_building_block"
)

args      <- commandArgs(trailingOnly = TRUE)
COMMIT    <- "--commit" %in% args
WITH_EXCL <- "--with-exclusions" %in% args
LIMIT     <- { i <- match("--limit", args); if (!is.na(i)) as.integer(args[i + 1]) else NA_integer_ }
ONLY      <- { i <- match("--only",  args); if (!is.na(i)) strsplit(args[i + 1], ",")[[1]] else NULL }

find_workspace_root <- function() {
  for (p in c(getwd(), file.path(getwd(), ".."))) {
    if (file.exists(file.path(p, "phenotype_library", "catalog.yaml"))) return(normalizePath(p))
  }
  stop("Run from the workspace root (where phenotype_library/ lives).")
}

root  <- find_workspace_root()
cat_y <- yaml::read_yaml(file.path(root, "phenotype_library", "catalog.yaml"))
dvi_y <- yaml::read_yaml(file.path(root, "phenotype_library", "dvi_index.yaml"))
existing_names <- tolower(trimws(vapply(dvi_y$concept_sets %||% list(),
                                        function(e) e$name %||% "", character(1))))
if (!file.exists(MEMBERS_CACHE))
  stop(sprintf("Missing %s — run fetch_dvi_members.R first.", MEMBERS_CACHE))
members <- fromJSON(MEMBERS_CACHE, simplifyVector = FALSE)

# ---- helpers ---------------------------------------------------------------
# ATLAS export breaks on \ / : * ? < > | " (see feedback_atlas_naming). Replace
# only those; leave legitimate hyphens/em-dashes intact.
sanitize_name <- function(s) {
  s <- gsub("\\s*/\\s*", "-", s)            # slash -> hyphen (DVI convention: no spaces)
  s <- gsub('[\\\\:*?<>|"]', "-", s)         # other illegal chars -> hyphen
  s <- gsub("\\s+", " ", s)
  trimws(s)
}

# Include-concepts of an entry (verified concept ids only).
entry_concept_ids <- function(e) {
  ids <- integer(0)
  for (it in e$concept_sets %||% list()) {
    cid <- suppressWarnings(as.integer(it$concept_id))
    if (!is.na(cid) && cid != 0 && !is.null(it$vocab_query_date)) ids <- c(ids, cid)
  }
  sort(unique(ids))
}
entry_has_own_conceptset <- function(e) length(entry_concept_ids(e)) > 0
has_structured_exclusions <- function(e) !is.null(e$exclusion_concept_sets) && length(e$exclusion_concept_sets) > 0

# Excluded-concepts of an entry (from exclusion_concept_sets), verified only.
entry_exclusion_ids <- function(e) {
  ids <- integer(0)
  for (it in e$exclusion_concept_sets %||% list()) {
    cid <- suppressWarnings(as.integer(it$concept_id))
    if (!is.na(cid) && cid != 0) ids <- c(ids, cid)
  }
  sort(unique(ids))
}

best_dup <- function(cids) {
  best <- NULL; best_frac <- 0
  for (m in members) {
    e_ids <- unlist(m$concept_ids)
    if (length(e_ids) == 0) next
    frac <- length(intersect(cids, e_ids)) / length(cids)
    if (frac > best_frac) { best_frac <- frac
      best <- list(name = m$name, id = m$id, frac = frac, inter = length(intersect(cids, e_ids))) }
  }
  best
}

# Build the ATLAS items array: included concepts + (optionally) excluded ones.
build_items <- function(e, with_excl = FALSE) {
  items <- list()
  for (it in e$concept_sets %||% list()) {
    cid <- suppressWarnings(as.integer(it$concept_id))
    if (is.na(cid) || cid == 0 || is.null(it$vocab_query_date)) next
    inc_desc <- isTRUE(it$include_descendants) || identical(it$include_descendants, "true")
    items[[length(items) + 1]] <- list(conceptId = cid, isExcluded = 0L,
      includeDescendants = if (inc_desc) 1L else 0L, includeMapped = 0L)
  }
  if (with_excl) for (it in e$exclusion_concept_sets %||% list()) {
    cid <- suppressWarnings(as.integer(it$concept_id))
    if (is.na(cid) || cid == 0) next
    inc_desc <- isTRUE(it$include_descendants) || identical(it$include_descendants, "true")
    items[[length(items) + 1]] <- list(conceptId = cid, isExcluded = 1L,
      includeDescendants = if (inc_desc) 1L else 0L, includeMapped = 0L)
  }
  items
}

curl_json <- function(method, url, body_file = NULL) {
  resp <- tempfile(fileext = ".resp")
  a <- c("-s", "-o", resp, "-w", "%{http_code}", "-X", method,
         "-H", "Content-Type: application/json", "-H", "Accept: application/json")
  if (!is.null(body_file)) a <- c(a, "--data-binary", paste0("@", body_file))
  a <- c(a, url)
  # system()/system2 run through a shell WITHOUT quoting, so any arg with a
  # space (headers, media types) would be word-split. shQuote each arg.
  code <- paste(system(paste("curl", paste(shQuote(a), collapse = " ")), intern = TRUE), collapse = "")
  body <- if (file.exists(resp)) paste(readLines(resp, warn = FALSE), collapse = "\n") else ""
  list(code = code, body = body)
}

create_concept_set <- function(target_name, items) {
  bf <- tempfile(fileext = ".json")
  writeLines(toJSON(list(name = target_name), auto_unbox = TRUE), bf)
  r1 <- curl_json("POST", paste0(BASE_URL, "/conceptset/"), bf)
  if (!startsWith(r1$code, "20")) stop(sprintf("create HTTP %s: %s", r1$code, substr(r1$body, 1, 300)))
  new_id <- tryCatch(fromJSON(r1$body)$id, error = function(e) NA)
  if (is.na(new_id)) stop(sprintf("create returned no id: %s", substr(r1$body, 1, 300)))
  bf2 <- tempfile(fileext = ".json")
  writeLines(toJSON(items, auto_unbox = TRUE), bf2)
  r2 <- curl_json("PUT", sprintf("%s/conceptset/%d/items", BASE_URL, new_id), bf2)
  if (!startsWith(r2$code, "20")) stop(sprintf("items PUT HTTP %s (set %d): %s", r2$code, new_id, substr(r2$body, 1, 300)))
  r3 <- curl_json("GET", sprintf("%s/conceptset/%d/items", BASE_URL, new_id))
  list(id = new_id, n_saved = tryCatch(length(fromJSON(r3$body, simplifyVector = FALSE)), error = function(e) NA))
}

# ---- plan ------------------------------------------------------------------
rows <- list()
for (e in cat_y$entries %||% list()) {
  id <- e$id %||% "?"
  if (!is.null(ONLY) && !(id %in% ONLY)) next
  if ((e$status %||% "") != "verified")  next
  if (startsWith(id, "cohort_atlas_tagged_")) next  # id convention for entries that already mirror a tagged ATLAS cohort
  if (!entry_has_own_conceptset(e))      next
  cids   <- entry_concept_ids(e)
  target <- paste0(ATLAS_LABEL_PREFIX, " ", sanitize_name(e$name %||% id))
  dup    <- best_dup(cids)
  excl   <- has_structured_exclusions(e)

  action <- "CREATE"; detail <- ""
  if (!startsWith(target, ATLAS_LABEL_PREFIX))          { action <- "REFUSE-wrong-prefix" }
  else if (id %in% BUILD_BLOCKS)                         { action <- "skip-buildblock" }
  else if (tolower(trimws(target)) %in% existing_names) { action <- "skip-existing-name" }
  else if (!is.null(dup) && dup$frac >= DUP_FRAC)       { action <- "skip-existing-concepts"
                                                          detail <- sprintf("%d/%d in %s", dup$inter, length(cids), dup$name) }
  else if (excl && !WITH_EXCL)                          { action <- "DEFER-exclusions" }
  else if (excl && WITH_EXCL)                           { detail <- sprintf("+%d excluded", length(entry_exclusion_ids(e))) }

  rows[[length(rows) + 1]] <- list(id = id, target = target, n = length(cids),
                                    action = action, detail = detail, entry = e, with_excl = excl && WITH_EXCL)
}

fmt <- function(r) sprintf("  %-34s | n=%-2d | %s%s", r$id, r$n, r$target,
                           if (nzchar(r$detail)) paste0("   [", r$detail, "]") else "")
by  <- function(a) Filter(function(r) r$action == a, rows)

cat(sprintf("\n%s%s — %d verified concept-set entries in scope\n",
            if (COMMIT) "COMMIT MODE" else "DRY RUN (no writes)",
            if (WITH_EXCL) " [--with-exclusions]" else "", length(rows)))
cat(strrep("=", 78), "\n")
for (a in c("CREATE", "DEFER-exclusions", "skip-existing-concepts", "skip-existing-name",
            "skip-buildblock", "REFUSE-wrong-prefix")) {
  grp <- by(a)
  if (length(grp)) { cat(sprintf("\n%s (%d):\n", a, length(grp))); for (r in grp) cat(fmt(r), "\n") }
}
creates <- by("CREATE")
cat(sprintf("\n--> %d CREATE | %d deferred(excl) | %d skip(concepts) | %d skip(name) | %d building-block\n",
            length(creates), length(by("DEFER-exclusions")), length(by("skip-existing-concepts")),
            length(by("skip-existing-name")), length(by("skip-buildblock"))))

if (!COMMIT) { cat("\nDry run only. Re-run with --commit to create the CREATE rows.\n"); quit(status = 0) }

# ---- commit ----------------------------------------------------------------
if (!is.na(LIMIT)) creates <- head(creates, LIMIT)
cat(sprintf("\nCreating %d label-tagged concept set(s) on %s ...\n", length(creates), BASE_URL))
results <- list()
for (r in creates) {
  if (!startsWith(r$target, ATLAS_LABEL_PREFIX)) { cat(sprintf("  REFUSED (wrong prefix): %s\n", r$target)); next }
  res <- tryCatch(create_concept_set(r$target, build_items(r$entry, r$with_excl)),
                  error = function(e) { cat(sprintf("  ERROR %s: %s\n", r$id, conditionMessage(e))); NULL })
  if (!is.null(res)) {
    cat(sprintf("  OK  id=%-9d items=%s  %s  <- %s\n", res$id, res$n_saved, r$target, r$id))
    results[[length(results) + 1]] <- list(entry_id = r$id, dvi_id = res$id, name = r$target, n = res$n_saved)
  }
}
if (length(results)) {
  writeLines(toJSON(results, auto_unbox = TRUE, pretty = TRUE), CREATED_MAP)
  cat(sprintf("\nCreated %d set(s). Map -> %s (for catalog external_alignment backfill).\n", length(results), CREATED_MAP))
}
