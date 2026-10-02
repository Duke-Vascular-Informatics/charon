#!/usr/bin/env bash
set -euo pipefail

# Bootstrap Claude headless helper for editor sessions.
if [[ -f /workspace/infrastructure/scripts/setup-claude-headless.sh ]]; then
  bash /workspace/infrastructure/scripts/setup-claude-headless.sh
fi

# Restore renv packages at the workspace root so that all infrastructure scripts
# (e.g. infrastructure/scripts/setup_omop_vocab_schema.R) can load DatabaseConnector,
# SqlRender, ETLSyntheaBuilder, etc. without needing to cd into a study subfolder first.
#
# The workspace renv.lock is kept in sync with synthea-omop-template/renv.lock and
# contains the full HADES + tidyverse stack.  After the first restore the shared
# renv_cache Docker volume makes subsequent restores near-instant (re-link from cache).
if [[ -f /workspace/renv/activate.R ]] && command -v R >/dev/null 2>&1; then
  (
    cd /workspace
    R -e "source('renv/activate.R'); renv::restore(prompt = FALSE)"
  )
fi

# If synthea-omop-template is present as a submodule and has its own renv.lock with
# packages that differ from the workspace lock, restore those too.  Packages already
# in the shared cache are not re-downloaded.
study_dir="/workspace/synthea-omop-template"
if [[ -d "$study_dir" ]] && [[ -f "$study_dir/renv.lock" ]] && command -v R >/dev/null 2>&1; then
  (
    cd "$study_dir"
    R -e "if (file.exists('renv/activate.R')) { source('renv/activate.R'); renv::restore(prompt = FALSE) }"
  )
fi
