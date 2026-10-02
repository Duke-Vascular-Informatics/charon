# Troubleshooting: OMOP Vocabulary Load

Use this when Step 9 fails or stalls.

## Quick Checks

1. Confirm SQL Server is running from host:

```bash
docker compose ps
```

2. Confirm mount exists inside container:

```bash
ls -la /omop_vocab/
```

3. Confirm credentials are valid:
- Check `.env` at `<workspace-root>/.env`
- Ensure password matches SQL Server container env

## Retry Loader

```bash
Rscript infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template
```

## Verify Load

```bash
# Run from inside the study repo (so config.R and R/ helpers resolve)
Rscript -e '
  source("config.R")       # get_validation_config()
  source("R/drivers.R")    # ensure_jdbc_bundle()
  source("R/connection.R") # build_connection_details()
  config <- get_validation_config()
  conn <- DatabaseConnector::connect(build_connection_details(config))
  result <- DatabaseConnector::querySql(conn, "SELECT COUNT(*) AS n FROM omop_vocab.concept")
  print(result)
  DatabaseConnector::disconnect(conn)
'
```

Expected concept row count is usually around 2M (varies by vocabulary version).

## Common Failure Patterns

- `Login failed for user 'sa'`: incorrect `MSSQL_SA_PASSWORD` in `.env`
- `Cannot open database "omop_synth" requested by the login` / `Database 'omop_synth' does not exist`:
  the shared database is normally created automatically by the Step 9 vocabulary
  loader (see `GETTING_STARTED.md` Step 7, "The shared database is created
  automatically"). If it still doesn't exist, create it manually — see
  [SETUP.md → "Create the shared database"](SETUP.md#create-the-shared-database):
  ```bash
  docker exec mssql_dev /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U SA -P "$MSSQL_SA_PASSWORD" -C \
    -Q "IF DB_ID('omop_synth') IS NULL CREATE DATABASE omop_synth;"
  ```
- `Invalid object name omop_vocab.concept`: schema not loaded yet
- Loader cannot find CSV files: `<workspace-root>/omop_vocab` path mismatch or missing extract
- Extremely slow load: one-time expected cost can be 30-60 minutes
