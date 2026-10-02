source("renv/activate.R")

# Load .env if present — institution-specific settings (never committed).
#
# Precedence: the REAL process environment wins over the .env file. We only
# set a variable from .env when it is not already present in the environment.
# This matches standard dotenv behaviour and is critical inside the dev
# container: docker-compose sets MSSQL_HOST=mssql_dev (and OMOP_SERVER) so R can
# reach the SQL Server *service*, while .env keeps MSSQL_HOST=localhost for
# host-side execution. If .env blindly overrode the environment, every script
# run from the workspace root would connect to localhost:1433 inside the
# container and fail with a confusing "connection refused" / "cannot open
# database" error (this is exactly what broke the vocabulary loader). Honouring
# the real environment first preserves the container value.
local({
  env_file <- file.path(getwd(), ".env")
  if (file.exists(env_file)) {
    lines <- readLines(env_file, warn = FALSE)
    lines <- lines[!grepl("^\\s*#", lines) & nchar(trimws(lines)) > 0]
    for (line in lines) {
      eq <- regexpr("=", line, fixed = TRUE)
      if (eq < 2L) next
      key <- trimws(substr(line, 1L, eq - 1L))
      val <- trimws(substr(line, eq + 1L, nchar(line)))
      val <- gsub('^["\']|["\']$', "", val)  # strip optional surrounding quotes
      # Do not clobber a variable already set in the real environment
      # (e.g. MSSQL_HOST=mssql_dev injected by docker-compose in the container).
      if (nzchar(Sys.getenv(key))) next
      do.call(Sys.setenv, structure(list(val), names = key))
    }
  }
})

# CRAN mirror — reads CRAN_MIRROR from .env / environment; falls back to cloud.r-project.org
options(repos = c(CRAN = Sys.getenv("CRAN_MIRROR", unset = "https://cloud.r-project.org")))
