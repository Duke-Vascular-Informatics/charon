# Getting Started: Workspace-First Workflow

> **Start here if you are new.**
>
> Follow the steps in order. Each step is a hard prerequisite for the next.

This guide sets up the `<workspace-root>` on your computer — a shared
environment that handles R, SQL Server, and all OHDSI analysis tools automatically.
You do not need prior command-line experience; this guide will tell you exactly
where and how to run any commands that are required.

Detailed references:
- GitHub auth details: [GIT_GITHUB_AUTH.md](GIT_GITHUB_AUTH.md)
- Vocabulary load troubleshooting: [TROUBLESHOOTING_VOCAB_LOAD.md](TROUBLESHOOTING_VOCAB_LOAD.md)
- ETL troubleshooting: [TROUBLESHOOTING_ETL.md](TROUBLESHOOTING_ETL.md)

**Total time (first setup):** ~1.5–2 hours  
— 10 min installs + 2 min clone + 15–25 min .env + container build + 30–60 min vocabulary load  
**Repeat-study time:** ~10–20 minutes (packages and SQL Server already running)  
**Requires:** ~35 GB disk space, **16 GB RAM strongly recommended** (8 GB is the bare
minimum and risks an out-of-memory failure during the vocabulary load — see Step 3.1),
active internet

**Setup order — do not skip ahead:**
1. Create a GitHub account
2. Install Git
3. Install Docker Desktop
4. Install VS Code and the Dev Containers extension
5. Clone the `<workspace-root>` repository
6. Configure your `.env` file and build the dev container
7. Verify your environment
8. Download OMOP vocabulary files
9. Load vocabulary into SQL Server
10. Create your analysis-core study repo and your report repo
11. Define your study (cohort SQL, covariates, parameters) and run the workflow

> **Steps 1–9 are the same regardless of which study template you end up
> using.** Step 10 is where the path branches — see
> [Step 10.0: Choose Your Templates](#step-100-choose-your-templates-and-create-your-repos)
> below. This guide documents the legacy `synthea-omop-template` path
> (Steps 10–11) in full, because it is still the most detailed
> reference for the underlying OMOP concepts (cohorts, covariates, vocabulary
> lookup) even for a study built on `strategus-study-template` instead — that
> template has its own `CHECKLIST.md` and `docs/UsingThisTemplate.md` for the
> Strategus-specific mechanics. **Every study, on either path, also gets a
> separate report repo** built from `omop-report-template` — see Step 10.4.

---

## About terminals

Several steps use short commands. This guide uses two different "terminals"
depending on where you are in setup:

**Your system terminal** (used only in Steps 2 and 8):
- **Mac:** open the **Terminal** app (search "Terminal" in Spotlight with `Cmd+Space`)
- **Windows:** open **PowerShell** (press `Win`, type `powershell`, press Enter)

**The VS Code container terminal** (used in Steps 7 onward, after the container builds):
Inside VS Code, press `` Ctrl+` `` (Windows/Linux) or `` Cmd+` `` (Mac) to open a
terminal panel at the bottom of the screen. Once the dev container is running, this
terminal is *inside* the container where R and all analysis tools are installed.

---

## Step 1: Create a GitHub Account (2 minutes)

GitHub is where the workspace code lives and where you will push your study code.

If you already have a GitHub account, skip to Step 2.

1. Go to [github.com](https://github.com) and click **Sign up**
2. Choose a username, enter your institutional email, and complete verification
3. Select the **Free** plan

> You will create a GitHub Personal Access Token (PAT) in Step 6 when you
> configure your secrets file — no need to do anything else here.

---

## Step 2: Install Git (5 minutes)

Git tracks every change to your study code and enables collaboration.

### 2.1 Download and install

- Go to [git-scm.com/downloads](https://git-scm.com/downloads)
- Download and run the installer for your operating system
- On Windows, accept the default options

### 2.2 Set your name and email (one-time)

Git needs to know who you are so it can label your changes.

Open your **system terminal** (see the "About terminals" section above) and run
these three lines one at a time, replacing the example values with your own:

```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@org.edu"
git config --global init.defaultBranch main
```

---

## Step 3: Install Docker Desktop (5 minutes)

Docker Desktop runs the SQL Server database and the R analysis environment.
It must be running before you open the workspace.

- Go to [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/)
- Download and run the installer for your operating system
- Launch Docker Desktop and wait until the icon in your menu bar / taskbar shows **"Engine running"**

> **Apple Silicon (M1/M2/M3/M4):** Docker Desktop runs natively — no Rosetta needed.

### 3.1 Configure disk and memory limits

After installing Docker Desktop, open **Settings → Resources → Advanced** and set:

| Setting | Recommended value | Why |
|---|---|---|
| **Virtual disk limit** | **80 GB** | The workspace needs ~30–35 GB (images + SQL Server + vocabulary). The default can be 200+ GB and will grow unchecked with failed builds. 80 GB leaves headroom for build cache. |
| **Memory** | **16 GB** (12 GB minimum) | The one-time vocabulary load (Step 9) reads multi-GB CSVs fully into R memory — the 6.3M-row CONCEPT table alone peaks near 12 GB. At 8 GB the loader is OOM-killed mid-load (a silent exit with no error). The loader caps SQL Server's memory automatically to maximise headroom, but 16 GB is the reliable target. If your machine has only 16 GB physical RAM, give Docker 12 GB and leave the rest for the OS. |

> **The loaded vocabulary persists** on a Docker volume — it survives container
> rebuilds and Docker restarts, so you only load it once (Step 9). It is **not**
> lost on a normal rebuild.

> **If Docker is already using too much disk** (e.g., 100+ GB from prior failed builds),
> reclaim build cache and unused images with:
> ```bash
> docker image prune -a
> docker builder prune -a
> ```
>
> ⚠️ **Do not run `docker system prune --volumes`** unless you intend to wipe the
> database. The `--volumes` flag deletes the SQL Server data volume — including the
> loaded OMOP vocabulary — and it is **not** re-downloaded automatically; you would
> have to repeat the 30–60 minute Step 9 load. Only use `--volumes` as a deliberate
> full reset, and re-run Step 9 afterwards.

---

## Step 4: Install VS Code and the Dev Containers Extension (5 minutes)

VS Code is the code editor that hosts the dev container.

> **AI coding assistant:** Claude Code is installed automatically when the dev
> container builds in Step 6 — no manual installation needed here.

### 4.1 Install VS Code

- Go to [code.visualstudio.com](https://code.visualstudio.com)
- Download and run the installer for your operating system
- Launch VS Code

### 4.2 Install the Dev Containers extension

Inside VS Code:
1. Click the **Extensions** icon in the left sidebar (it looks like four squares)
2. In the search box, type `ms-vscode-remote.remote-containers`
3. Click **Install** on the **Dev Containers** extension by Microsoft

---

## Step 5: Clone the Workspace Repository (2 minutes)

"Cloning" downloads a copy of the workspace code to your computer.

### Option A: Clone via VS Code (recommended — no terminal needed)

1. Open VS Code
2. Click the **Source Control** icon in the left sidebar (it looks like a branch)
3. Click **Clone Repository**
4. Paste this URL:
   ```
   https://github.com/<your-org>/<your-workspace-repo>.git
   ```
5. Choose a folder where you want to keep your research code (e.g., your home folder or Documents)
6. Click **Open** when VS Code offers to open the cloned repository

### Option B: Clone via terminal

Open your **system terminal**, navigate to where you want to keep your code,
and run:

```bash
git clone https://github.com/<your-org>/<your-workspace-repo>.git
```

---

## Step 6: Configure Your `.env` File and Build the Dev Container (15–25 minutes)

This step creates your local secrets file, fills in three required values, and
builds the dev container. Do all sub-steps in order.

### 6.1 Create your `.env` file

VS Code should now show the `<workspace-root>` folder in the file explorer
(left sidebar). You will see a file called `.env.example`.

**In VS Code's file explorer:**
1. Right-click `.env.example` and select **Copy**
2. Right-click an empty area in the same folder and select **Paste**
3. A copy appears — right-click it and select **Rename**
4. Name it `.env` (remove `.example` from the end) and press Enter

This creates a private secrets file that the dev container will read at startup.
Keep `.env.example` in place as a reference.

> `.env` is gitignored — it will never be accidentally committed to GitHub.

### 6.2 Set your Anthropic API key

In VS Code's file explorer, click `.env` to open it.

Find the line:

```
ANTHROPIC_API_KEY=your_anthropic_api_key_here
```

Replace `your_anthropic_api_key_here` with your key from
[console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys).

### 6.3 Create a GitHub Personal Access Token and paste it

Find the line:

```
GH_TOKEN=your_github_pat_here
```

You need to create a token on GitHub and paste it here. This token lets your
AI coding assistant commit and push code on your behalf, and lets R install packages
from GitHub without hitting rate limits.

**Create the token (takes 2 minutes):**

1. Go to [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new)
2. Name it something recognizable, e.g. your workspace repo's name
3. Set expiration to **90 days** (you can regenerate it when it expires)
4. Under **Repository permissions**, set:
   - **Contents:** Read-only
   - **Pull requests:** Read and write
5. Click **Generate token** — copy the value immediately (you cannot view it again)

Back in `.env`, replace `your_github_pat_here` with the token you just copied.

### 6.4 Set your SQL Server password

Find the line:

```
MSSQL_SA_PASSWORD=YourStrong@Passw0rd
```

Replace it with a strong password you choose. Requirements:
- At least 8 characters with a mix of upper, lower, digit, and special character (`@`, `#`, `$`, `%`)
- Do NOT use `!`
- Example: `SqlServer@2024`

**Save and close `.env`** (press `Ctrl+S` / `Cmd+S`).

### 6.5 Build the dev container

Make sure Docker Desktop is running (check your menu bar / taskbar).

In VS Code, press `Ctrl+Shift+P` (Windows/Linux) or `Cmd+Shift+P` (Mac) to open
the command palette, type `Dev Containers: Reopen in Container`, and press Enter.

VS Code may also show a pop-up notification — **"Folder contains a Dev Container.
Reopen in Container?"** — in which case you can just click that.

**What happens during the first build (10–20 minutes):**

1. Downloads the R 4.5 + Java 17 base image
2. Installs system tools and the Claude Code AI assistant
3. Starts the SQL Server database container
4. Installs the full R package library (HADES + tidyverse)

A progress indicator appears in the bottom-right corner. When it finishes, the
VS Code status bar at the bottom shows the container name.

> **First build takes 10–20 minutes.** Later rebuilds take under a minute because
>
> **Claude Code defaults to Haiku** to keep token costs low. Haiku handles most
> routine tasks (file edits, git, running scripts). Switch to Sonnet with
> `/model sonnet` when writing new analysis code or debugging complex errors.
> See `CLAUDE.md` → "Model Selection" for full guidance.
> packages are cached.

---

## Step 7: Verify Your Environment (2 minutes)

Once the build completes, confirm everything is working.

Open the **VS Code container terminal** (`` Ctrl+` `` / `` Cmd+` ``) and run:

```bash
echo $IN_DEV_CONTAINER          # Should print: true
R --version                     # Should show: R version 4.5.x
echo $MSSQL_HOST                # Should print: mssql_dev
docker ps                       # Should show mssql_dev as healthy
```

> If `$MSSQL_HOST` prints nothing (empty), see
> [Troubleshooting: "Connection refused" on `localhost:1433`](#connection-refused-on-localhost1433)
> below — it usually means the container needs to be rebuilt.

### Authenticate git for your AI assistant

Run this once so the AI coding assistant can commit and push on your behalf:

```bash
gh auth login --with-token <<< "$GH_TOKEN"
gh auth status          # Should show: Logged in to github.com
```

### Enable the Zotero reference library (2 minutes, optional but recommended)

The workspace ships a shared MCP server configuration (`.mcp.json`) that lets an
AI assistant read the lab's Zotero group library — so it can pull references
into a report instead of you pasting citations by hand. The configuration is
shared; **the credentials are personal and never committed.**

1. Create a **read-only** personal API key at
   <https://www.zotero.org/settings/keys>.
2. Get the group library ID from the URL `zotero.org/groups/<ID>/library` —
   ask if you're unsure which group.
3. Add both to the `.env` you created in Step 6 (the variable names are already
   stubbed in `.env.example`):

   ```bash
   ZOTERO_API_KEY=<your personal key>
   ZOTERO_GROUP_ID=<the lab group id>
   ```

4. Rebuild the container so the variables are picked up
   (`Cmd+Shift+P` → **Dev Containers: Rebuild Container**), then confirm:

   ```bash
   [ -n "$ZOTERO_API_KEY" ] && echo "Zotero configured" || echo "Not set — check .env, then rebuild"
   ```

Skipping this is harmless — the Zotero server just won't start. Full details,
including how to verify from an assistant session, are in
[SETUP.md → Step 5b](SETUP.md#step-5b--mcp-servers-shared-config-personal-credentials).

> **Keep reference PDFs in Zotero, not in a repo's `docs/` folder.** `docs/` is
> for workspace and study documentation. Papers belong in the group library,
> where they're shared, versioned, and reachable from an analysis session — and
> out of git.

### The shared database is created automatically

The SQL Server container is now running. You do **not** need to create the
`omop_synth` database manually — the vocabulary loader in Step 9 creates it
automatically on first run (it is idempotent and does nothing if the database
already exists). Just proceed to Step 8.

> All commands from this point forward run in the **VS Code container terminal**
> unless stated otherwise.

---

## Step 8: Download OMOP Vocabulary Files (30–60 minutes, one-time)

The OMOP vocabulary maps clinical codes to standard concepts. Download it once;
it does not need to be repeated for each new study.

### 8.1 Download from Athena

1. Go to [athena.ohdsi.org](https://athena.ohdsi.org) and sign in (free account)
2. Click **Download** → **Create new download**
3. Select these vocabulary bundles:

| Vocabulary | Required | Notes |
|---|---|---|
| **SNOMED** | ✅ | Primary clinical vocabulary |
| **RxNorm** | ✅ | Drug ingredients |
| **RxNorm Extension** | ⭐ | Drugs not in RxNorm |
| **LOINC** | ✅ | Lab measurements |
| **ICD10CM** | ✅ | US diagnoses |
| **CPT4** | ⭐ | US procedures (requires UMLS key) |
| **HCPCS** | ⭐ | US outpatient procedures |
| **ICD10PCS** | ⭐ | US inpatient procedures |
| **Visit** | ✅ | Visit types |
| **Gender / Race / Ethnicity** | ✅ | Demographics |
| **UCUM** | ✅ | Units of measure |

4. Accept the license and click **Download**

### 8.2 Extract into the workspace

Once the zip file downloads:

**Mac:** Double-click the zip file to extract it. Then move the resulting folder
into your `<workspace-root>/` folder and rename it `omop_vocab`.

**Windows:** Right-click the zip file and select **Extract All**. Move the
extracted folder into `<workspace-root>/` and rename it `omop_vocab`.

The folder should contain a file called `CONCEPT.csv` directly inside `omop_vocab/`.

### 8.3 Optional: Rebuild CPT-4 codes

**Skip this section if you did not select CPT-4 in your Athena download.**

> **Why a separate step?** CPT-4 procedure codes are owned by the American Medical
> Association and cannot be distributed directly by Athena. The Athena download
> includes a small Java utility (`cpt4.jar`) that fetches them from the U.S. National
> Library of Medicine (NLM) API — but you need a free NLM/UMLS account to use it.
>
> **Can I skip this for now?** Yes. You can load the vocabulary without CPT-4 and
> re-run this step later. Procedures coded only as CPT-4 will show as unmapped until
> then; SNOMED-CT equivalents cover most common procedures.

#### Part A — Get a free UMLS API key

1. Go to [uts.nlm.nih.gov](https://uts.nlm.nih.gov) and click **Sign Up** (top right)
2. Fill in your details using your institutional email — approval is usually same-day;
   check your inbox for a confirmation email and click the link inside it
3. After confirming, log back in at [uts.nlm.nih.gov](https://uts.nlm.nih.gov)
4. Click your name (top right) → **My Profile**
5. On the profile page, find the **API Key** section — your key is the long string of
   letters and numbers next to the label. Copy it.

> Your API key looks like: `a1b2c3d4-e5f6-7890-abcd-ef1234567890`  
> Keep it safe — it authenticates downloads from the NLM on your behalf.

#### Part B — Run the rebuild script from inside the dev container

The dev container already has Java 17 installed and has `omop_vocab/` mounted at
`/omop_vocab`. Running the script from there is simpler than installing Java on
your host machine.

In the **VS Code container terminal**:

```bash
cd /omop_vocab

# Paste your UMLS API key in place of YOUR_API_KEY_HERE
bash cpt.sh YOUR_API_KEY_HERE
```

**What the script does:**
1. Connects to the NLM API and authenticates with your key
2. Downloads all CPT-4 concept rows
3. Saves them to `CONCEPT_CPT4.csv` in the same folder
4. Appends the CPT-4 rows into `CONCEPT.csv`

**Expected output (success):**
```
Generating CPT4 file...
Downloading CPT4 batch 1 of N...
...
CPT4 file generated successfully.
```

The script takes **5–15 minutes** and requires an active internet connection.
Do not close the terminal or interrupt it mid-run — the Athena script itself warns
that interruption can corrupt `CONCEPT.csv`.

**After the script finishes**, confirm `CONCEPT_CPT4.csv` was created:

```bash
ls -lh /omop_vocab/CONCEPT_CPT4.csv
# Should show a file of several MB
```

> **Already ran this once?** If `CONCEPT_CPT4.csv` already exists in `omop_vocab/`,
> the CPT-4 rows are already in `CONCEPT.csv`. You do not need to re-run the script
> unless you are rebuilding the vocabulary from scratch.

---

## Step 9: Load OMOP Vocabulary into SQL Server (30–60 minutes, one-time)

The vocabulary files on disk need to be loaded into the database. This is a
one-time step per machine.

All commands in this step run in the **VS Code container terminal**, from the
workspace root.

### 9.1 Run the vocabulary loader

```bash
Rscript infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template
```

This single command handles everything automatically — there is no manual
database-creation step:

1. **Creates the `omop_synth` database** if it does not already exist.
2. **Checks available RAM** and warns if there is less than ~12 GB (below which
   the load risks running out of memory — raise Docker's memory to 16 GB first).
3. **Caps SQL Server's memory** for the duration of the load so its buffer pool
   cannot starve the R loader, then restores a balanced value for analysis when
   done.
4. **Loads all vocabulary tables** from `omop_vocab/` and builds indexes.

Expect 30–60 minutes. It reads multi-GB CSVs into memory (CONCEPT_ANCESTOR alone
is ~75M rows), so leave it running and do not interrupt it.

**Expected output (tail):**
```
[INFO] ✓ Target database 'omop_synth' present (created if missing)
[INFO] ✓ SQL Server memory capped at 2048 MB for the load ...
...
[INFO] ✓ Vocabulary loaded successfully into 'omop_vocab'
[INFO] ✓ SQL Server memory restored to N MB for analysis workloads
=== Setup complete ===
```

> **If it exits silently with no error** part-way through (e.g. while loading
> CONCEPT), that is the Linux OOM killer — your Docker memory is too low. Raise
> Docker Desktop → Resources → Memory to 16 GB, restart, and re-run. The loader
> is safe to re-run: it skips automatically once the vocabulary is fully loaded.

If loading fails or stalls, see [TROUBLESHOOTING_VOCAB_LOAD.md](TROUBLESHOOTING_VOCAB_LOAD.md).

---

## Step 10: Create Your Study Repositories (10 minutes)

A study today is normally **two repos**: an analysis-core repo (cohorts,
covariates, the pipeline that produces results) and a report repo (the
manuscript, built from those results). See `README.md`'s
"Multi-Repo Analysis Pipeline" section for the full picture.

### Step 10.0: Choose Your Templates and Create Your Repos

**Analysis core — pick one:**

| Template | Use when |
|---|---|
| [`strategus-study-template`](https://github.com/Duke-Vascular-Informatics/strategus-study-template) **(default for new studies)** | Cohort logic can be expressed as declarative circe cohort definitions run by OHDSI Strategus. Has its own `CHECKLIST.md` and `docs/UsingThisTemplate.md` — follow those instead of Steps 10.1–11 below once your repo is created. |
| `synthea-omop-template` (legacy — this guide covers it in full below) | You need the numbered `workflow/01–09` scaffold in the same repo as the analysis (Synthea generation + ETL + QC alongside the analysis code), or you're building a `-synth` data-generation-only repo. |

If in doubt, use `strategus-study-template` and read its README's "Lineage"
and "Quick start" sections — Steps 10.1–11 below are written for the legacy
`synthea-omop-template` path.

**Report repo — always create one, regardless of which analysis-core
template you chose:** [`omop-report-template`](https://github.com/Duke-Vascular-Informatics/omop-report-template).
See Step 10.5 below.

### 10.1 Create the analysis-core repo on GitHub

1. Go to the study template: [github.com/Duke-Vascular-Informatics/synthea-omop-template](https://github.com/Duke-Vascular-Informatics/synthea-omop-template)
   (or [strategus-study-template](https://github.com/Duke-Vascular-Informatics/strategus-study-template) — see Step 10.0)
2. Click **Use this template** → **Create a new repository**
3. Name it descriptively (e.g., `colectomy-ssi-omop`)
4. Set visibility to **Private**
5. Click **Create repository from template**

### 10.2 Clone inside the workspace

In the **VS Code container terminal**:

```bash
git clone https://github.com/<your-org>/<your-study>.git
cd <your-study>
```

### 10.3 Create your personal working branch

Every collaborator works on a branch named after their GitHub username. This keeps
your changes separate from `main` until they are ready to review and merge.

```bash
# Your working branch = your GitHub username (auto-detected)
BRANCH=$(gh api user --jq .login)
echo "Your working branch will be: $BRANCH"

git checkout -b "$BRANCH"
git push -u origin "$BRANCH"
```

> **Why use your GitHub username as the branch name?** It makes it immediately clear
> whose work is on which branch, and the AI coding assistant can detect it automatically
> with `gh api user --jq .login` — no hardcoded names needed in any instructions.

All future commits, pushes, and pull requests go to **this branch — your branch**.
Never push directly to `main`, and **never push to another collaborator's branch**
(e.g., if you see a branch named `jsmith` or another username, that belongs to
someone else — do not check it out, commit to it, or push to it).

### 10.4 Keep your branch current (do this regularly)

The workspace owner merges infrastructure fixes, Dockerfile updates, and shared
phenotype definitions into `main` frequently. **Pull updates at the start of every
work session** to avoid building on stale code or a broken container image:

```bash
BRANCH=$(gh api user --jq .login)

# In the workspace root:
cd /workspace
git checkout main && git pull origin main
git checkout "$BRANCH" && git rebase main
git push origin "$BRANCH"

# In your study repo:
cd /workspace/<your-study>
git checkout main && git pull origin main
git checkout "$BRANCH" && git rebase main
git push origin "$BRANCH"
```

> **Why this matters:** the dev container's Dockerfile, R package list, and shared
> scripts all live in the workspace repo. If you skip pulling updates, you may hit
> build errors or connection issues that have already been fixed on `main`.

Your study repo sits directly inside the workspace:

```
<workspace-root>/
  .env
  docker-compose.yml
  omop_vocab/
  <your-study>/          ← your study lives here
    config.R
    study_params.yaml
    cohorts/
    workflow/
```

### 10.5 Create your report repo

Do this now, alongside the analysis-core repo, rather than after Step 11 —
the extract step you'll wire up in Step 11 writes exactly the artifacts this
repo reads.

1. Go to [github.com/Duke-Vascular-Informatics/omop-report-template](https://github.com/Duke-Vascular-Informatics/omop-report-template)
2. Click **Use this template** → **Create a new repository**
3. Name it `<your-study>-report` — the `-report` suffix on your analysis-core
   repo's name
4. Set visibility to **Private**
5. Click **Create repository from template**, then clone it as a **sibling**
   of your analysis-core repo (not nested inside it):

   ```bash
   cd /workspace
   git clone https://github.com/<your-org>/<your-study>-report.git
   cd <your-study>-report
   BRANCH=$(gh api user --jq .login)
   git checkout -b "$BRANCH"
   git push -u origin "$BRANCH"
   ```

6. Work through its `CHECKLIST.md` (Path A — new report repo) once your
   analysis-core repo has an `output/` folder to point it at (Step 11 below)

Your workspace now has both repos side by side:

```
<workspace-root>/
  <your-study>/            ← analysis-core repo
    output/                ← <your-study>-report reads this
  <your-study>-report/     ← report repo (sibling, not nested)
```

**This repo renders from result artifacts only — no database connection,
ever.** If you find yourself wanting to add `DatabaseConnector` or
`connection_details` inside `<your-study>-report`, that query belongs in
`<your-study>`'s `R/extract_report_inputs.R` instead. See
`omop-report-template`'s README and `docs/MIGRATION_PLAN_REPO_SPLIT.md` for why.

---

## Step 11: Run the Study Workflow (2–3 hours total)

The `workflow/` folder inside your study repo contains nine numbered scripts that
run in order. Some require you to edit files first; others run without any changes.

All commands below run in the **VS Code container terminal**. Make sure you are
in your study folder first:

```bash
cd /workspace/<your-study>
```

---

### Workflow 01 — Environment setup

Run once when you first open the study repo. Installs any missing R packages,
checks the database connection, and provisions the JDBC driver.

```bash
Rscript workflow/01_setup_synthea_etl_qc_env.R
```

---

### Workflow 02 — Define your study ✏️ *Edit before running*

This is the main step where you describe your study — what population you are
studying, what outcome you are looking for, and what covariates to include.

**Before running, edit these files in VS Code:**

**`study_params.yaml`** — open it in VS Code's file explorer and fill in:
- `study_name`, `cdm_schema`, `results_schema`, `cohort_table`, `output_folder`
- The `study_design` (e.g. `cohort_characterization`, `prognostic_model`)
- Enable the analyses you want by setting their flags to `true`

**`cohorts/`** — open the SQL files and replace every `concept_id = 0`
placeholder with the correct OMOP concept IDs for your clinical definition.
Ask your AI coding assistant to look these up — it will run vocabulary
queries and document each ID.

**`covariates/covariates.csv` and `covariate_concepts.csv`** — add the
patient features your study needs.

Once edited, run the validation script:

```bash
Rscript workflow/02_define_omop_cohort_outcome_covariates.R
```

This checks all your files for placeholder values and prints `[OK]` / `[WARN]` /
`[FAIL]` for each item. Fix any `[FAIL]` items before continuing.

---

### Workflow 03 — Validate Synthea module

Checks that the synthetic disease module used to generate test data is valid.
No editing needed.

```bash
Rscript workflow/03_generate_synthea_module_artifacts.R
```

---

### Workflow 04 — Generate synthetic patients

Creates synthetic patient data for testing your analysis on the local database.
No editing needed.

```bash
bash workflow/04_generate_synthea_csv.sh
```

> **Windows:** use `powershell -ExecutionPolicy Bypass -File workflow/04_generate_synthea_csv.ps1` instead.

---

### Workflow 05 — Load synthetic data into the database

Converts the synthetic CSV data into OMOP CDM tables in SQL Server.
No editing needed.

```bash
Rscript workflow/05_etl_csv_to_omop.R
```

If this fails, see [TROUBLESHOOTING_ETL.md](TROUBLESHOOTING_ETL.md).

---

### Workflow 06 — Quality check

Runs data quality checks on the newly loaded data and validates that your
phenotype definitions find patients. No editing needed.

```bash
Rscript workflow/06_quality_check_defined_phenotypes.R
```

---

### Workflow 07 — Analysis environment setup ✏️ *Optional edit*

Checks that all R packages your analysis needs are installed. The default
configuration covers most studies. Only edit this file if your analysis
requires packages not already included.

```bash
Rscript workflow/07_setup_analysis_env.R
```

---

### Workflow 08 — Run analysis and generate report ✏️ *Optional edit*

Runs the analysis and produces your output files and manuscript report.
For most studies, **no code editing is needed** — the analysis type is
controlled entirely by the `analyses:` flags you set in `study_params.yaml`
in Workflow 02.

> **Important:** run this in a fresh terminal session. Close any existing
> R sessions before running.

```bash
Rscript workflow/08_run_analysis_and_manuscript_report.R
```

Outputs are written to `output/<study_name>/`.

---

### Workflow 09 — Build transportable code packet

Packages your analysis code, R packages, and configuration into a
self-contained bundle ready to share with a data partner.

```bash
bash workflow/09_build_portable_analysis_bundle.sh
```

> **Windows:** use `powershell -ExecutionPolicy Bypass -File workflow/09_build_portable_analysis_bundle.ps1` instead.

This creates a `portable/` folder inside your study repo.

---

## Troubleshooting

- Infrastructure and container setup: [SETUP.md](SETUP.md)
- Vocabulary loading failures: [TROUBLESHOOTING_VOCAB_LOAD.md](TROUBLESHOOTING_VOCAB_LOAD.md)
- Synthetic data and ETL failures: [TROUBLESHOOTING_ETL.md](TROUBLESHOOTING_ETL.md)

### Docker using too much disk space

Docker Desktop's virtual disk grows with every build attempt (including failed
ones) and does not shrink automatically. If Docker is using 100+ GB, run:

```bash
docker system prune -a --volumes
docker builder prune -a
```

Then set the virtual disk limit to **60 GB** in Docker Desktop → Settings →
Resources → Advanced (see [Step 3.1](#31-configure-disk-and-memory-limits)).

### "Connection refused" on `localhost:1433`

If an R script fails with an error like:

```
Error in rJava::.jcall(...) :
  com.microsoft.sqlserver.jdbc.SQLServerException: The TCP/IP connection to
  the host localhost, port 1433 has failed. Connection refused.
```

This means the script tried to connect to `localhost` instead of the shared
SQL Server container (`mssql_dev`). Inside the dev container, `localhost`
refers to the container itself — not the database.

**Cause:** your dev container was built before `.devcontainer/docker-compose.yml`
was updated to set `MSSQL_HOST=mssql_dev` automatically. Environment variable
changes in `docker-compose.yml` only take effect after a container **rebuild**
— reopening the folder is not enough.

> **`MSSQL_HOST` is not set in `.env`** (by design). Inside the dev container,
> `docker-compose.yml` sets it to `mssql_dev` (via `DEVCONTAINER_MSSQL_HOST`); on
> the host, `config.R` defaults to `localhost`. Do **not** add `MSSQL_HOST=localhost`
> to `.env` — that would override the container value and force every in-container
> script to connect to `localhost:1433` (connection refused). The fix below
> (rebuild) makes the docker-compose value take effect.

**Fix:**

1. Pull the latest changes to the workspace `main` branch:
   ```bash
   git checkout main && git pull origin main
   ```
   (then rebase your working branch onto `main` — see the "Version Control"
   section in the workspace `CLAUDE.md`)
2. Rebuild the dev container: `Cmd+Shift+P` / `Ctrl+Shift+P` →
   **"Dev Containers: Rebuild Container"**
3. After the rebuild, re-run the Step 7 checks:
   ```bash
   echo $MSSQL_HOST     # Should print: mssql_dev
   docker ps            # Should show mssql_dev as healthy
   ```

If `mssql_dev` does not appear in `docker ps` after rebuilding, the SQL Server
service itself isn't running — start it from a **host** terminal (not the
container terminal) at the workspace root:

```bash
docker compose up -d
```

---

## Key Files

**Workspace root**

| File | Purpose |
|---|---|
| `docker-compose.yml` | SQL Server container |
| `.env` | Your secrets (never commit) |
| `.env.example` | Reference template for `.env` |
| `omop_vocab/` | OMOP vocabulary CSVs (never commit) |
| `renv.lock` | R package list — restored on container build |
| `infrastructure/scripts/` | Vocabulary loader and workspace scripts |

**Analysis-core repo (`<your-study>/`, legacy `synthea-omop-template` layout)**

| File | Purpose |
|---|---|
| `study_params.yaml` | Your study settings — edit this |
| `cohorts/*.sql` | Cohort definitions — edit these |
| `covariates/*.csv` | Covariate definitions — edit these |
| `workflow/01–09` | Analysis pipeline — do not edit |
| `output/` | Analysis results (gitignored) — read by `<your-study>-report` |
| `portable/` | Transportable bundle for sharing |

**Report repo (`<your-study>-report/`, from `omop-report-template`)**

| File | Purpose |
|---|---|
| `GenerateReport.R` | Entry point — `Rscript GenerateReport.R` |
| `config.R` | Reads `report_inputs/_report_config.yaml` — no `study_params.yaml` here |
| `R/report_dispatch.R`, `R/report_helpers.R` | Your report composition — edit these |
| `prcc_data/` | Institution's secure-environment data export drop-zone (gitignored except its README) |
| `reports/` | Rendered `.docx` output (gitignored) |

---

## Version Info

- **R version:** 4.5.x
- **Java:** 17 (Eclipse Adoptium)
- **SQL Server:** Azure SQL Edge (ARM64) or SQL Server 2022 (AMD64)
- **OMOP CDM:** v5.4
