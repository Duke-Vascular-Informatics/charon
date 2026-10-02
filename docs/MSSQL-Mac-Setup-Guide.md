# MSSQL Server 2022 — Docker Dev Setup on macOS (Apple Silicon)

## Prerequisites

Install the following if you haven't already:

| Tool | Install |
|------|---------|
| **Docker Desktop** | [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/) |
| **VS Code** | [code.visualstudio.com](https://code.visualstudio.com/) |
| **mssql VS Code extension** | Search `ms-mssql.mssql` in the VS Code Extensions panel |

> **Apple Silicon note:** SQL Server 2022 ships a native `linux/arm64` image — no Rosetta emulation or Azure SQL Edge workaround needed.

---

## Project Structure

Place these files in your project folder:

```
your-project/
├── docker-compose.yml
├── .env                  ← created from .env.example (never commit this)
├── .env.example
└── init-scripts/         ← optional: .sql files run on first start
    └── 01_create_db.sql
```

---

## Step 1 — Configure your environment

```bash
cp .env.example .env
```

Open `.env` and set a strong `MSSQL_SA_PASSWORD`. The password must meet SQL Server complexity requirements:

- At least 8 characters
- Mix of uppercase, lowercase, digit, and special character

**Example:** `MyDev@Passw0rd2024`

---

## Step 2 — Start the container

```bash
docker compose up -d
```

The first run pulls the image (~300 MB). Subsequent starts are fast.

Check that the container is healthy:

```bash
docker compose ps
```

You should see `mssql_dev` with status `healthy` after about 30–60 seconds.

---

## Step 3 — Verify with sqlcmd (optional)

Run a quick test query inside the container:

```bash
docker exec -it mssql_dev \
  /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "YourStrong!Passw0rd" \
  -Q "SELECT @@VERSION" -No -C
```

You should see the SQL Server 2022 version string.

---

## Step 4 — Connect from VS Code

1. Open VS Code and click the **SQL Server** icon in the Activity Bar (installed with the mssql extension)
2. Click **Add Connection**
3. Fill in the connection details:

| Field | Value |
|-------|-------|
| Server | `localhost,1433` |
| Authentication Type | SQL Login |
| User name | `sa` |
| Password | *(your MSSQL_SA_PASSWORD)* |
| Database | *(leave blank for master, or specify your DB)* |
| Trust server certificate | ✅ Enabled (required for local dev) |

4. Give it a friendly name like `Local Dev MSSQL`
5. Click **Connect** — you should see your databases in the sidebar

---

## Optional: Run init scripts on first start

Place `.sql` files in the `init-scripts/` folder to auto-execute when the container is first created. Name them with a numeric prefix to control execution order:

```
init-scripts/
├── 01_create_databases.sql
├── 02_create_schemas.sql
└── 03_seed_data.sql
```

> **Note:** Init scripts only run when the named Docker volume (`mssql_dev_data`) doesn't exist yet. To re-run them, you must remove the volume (see Useful Commands below).

---

## Useful Commands

```bash
# Start the server
docker compose up -d

# Stop the server (data is preserved in the volume)
docker compose stop

# View logs
docker compose logs -f mssql

# Open an interactive sqlcmd session
docker exec -it mssql_dev \
  /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "YourStrong!Passw0rd" -No -C

# Remove container AND all data (full reset)
docker compose down -v

# Backup a database
docker exec mssql_dev \
  /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "YourStrong!Passw0rd" \
  -Q "BACKUP DATABASE [YourDB] TO DISK = '/var/opt/mssql/backup/YourDB.bak'" \
  -No -C
```

---

## Migrating Databases from Windows

To move a database from your Windows environment:

**Option A — Backup & Restore (recommended)**

1. On Windows: right-click the database in SSMS → Tasks → Back Up → create a `.bak` file
2. Copy the `.bak` file to your Mac
3. Copy it into the container:
   ```bash
   docker cp YourDB.bak mssql_dev:/var/opt/mssql/backup/YourDB.bak
   ```
4. Restore it:
   ```bash
   docker exec -it mssql_dev \
     /opt/mssql-tools18/bin/sqlcmd \
     -S localhost -U sa -P "YourStrong!Passw0rd" \
     -Q "RESTORE DATABASE [YourDB] FROM DISK = '/var/opt/mssql/backup/YourDB.bak' WITH MOVE 'YourDB' TO '/var/opt/mssql/data/YourDB.mdf', MOVE 'YourDB_log' TO '/var/opt/mssql/data/YourDB_log.ldf'" \
     -No -C
   ```

**Option B — Generate Scripts**

In SSMS on Windows: right-click database → Tasks → Generate Scripts → include schema and data. Run the resulting `.sql` file against your Mac container via VS Code.

---

## Troubleshooting

**Container exits immediately**
- Check your `MSSQL_SA_PASSWORD` meets complexity requirements — a weak password is the most common cause of startup failure.
- Run `docker compose logs mssql` for details.

**Connection refused in VS Code**
- Wait a full 30–60 seconds after `docker compose up` for SQL Server to be ready.
- Make sure port 1433 isn't blocked or already used: `lsof -i :1433`

**"Login failed for user 'sa'"**
- Double-check the password in VS Code matches what's in your `.env` file exactly.

**Image pull issues**
- Make sure Docker Desktop is running and you're connected to the internet for the initial pull.
