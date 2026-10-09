# Getting Started: Workspace-First Workflow

> **Start here after reading the [README](../README.md).** Follow the steps in
> order; each is a prerequisite for the next.

This guide takes you from a blank machine to a working workspace: a SQL Server
database with the OMOP vocabulary loaded, a dev container with R, Java and
HADES, and your first study repos.

**Assumed background:** you know OMOP/OHDSI basics (CDM tables, concept IDs,
Athena), can read R and Python, and know what Java is used for here (JDBC).
You are expected to be comfortable with git and a terminal. **Not assumed:**
anything about this project — if a term is unfamiliar, see the
[README glossary](../README.md#glossary).

Detailed references:
- GitHub auth details: [GIT_GITHUB_AUTH.md](GIT_GITHUB_AUTH.md)
- Vocabulary load troubleshooting: [TROUBLESHOOTING_VOCAB_LOAD.md](TROUBLESHOOTING_VOCAB_LOAD.md)
- ETL troubleshooting: [TROUBLESHOOTING_ETL.md](TROUBLESHOOTING_ETL.md)

**Total time (first setup):** ~1.5–2 hours — 15 min installs and clone, 15–25
min `.env` and container build, 30–60 min vocabulary load.
**Repeat-study time:** ~10–20 minutes (packages cached, SQL Server already
running; start at Step 10).
**Before you start:** find out which R, Java and Python versions your secure
analytics environment uses ([Step 6.0](#60-match-the-container-to-your-secure-environment-before-the-first-build)).
**Requires:** ~35 GB of disk, **16 GB RAM allocated to Docker** (12 GB is the
minimum; below that the vocabulary load is killed by the OS with no error —
see Step 3.1), and internet access.

**What you will build, in order:**

1. A GitHub account
2. Git
3. Docker Desktop
4. VS Code and the Dev Containers extension
5. A clone of the workspace repo
6. A `.env` file, and the dev container
7. A verified environment
8. OMOP vocabulary files (from Athena)
9. The vocabulary loaded into SQL Server
10. Your study repos (analysis-core and report)
11. A study running end to end

> **Steps 1–9 are identical for every study.** Step 10 creates your repos:
> the **analysis-core** repo (`strategus-study-template`) holds *all* of the
> analysis, and the **report** repo (`omop-report-template`) holds the
> manuscript; each template has its own `CHECKLIST.md` you follow from there.
> Step 11 covers `synthea-omop-template`, which is used **only** to generate
> analysis-specific synthetic data in a `-synth` repo. If you will only
> *consume* a synthetic dataset that already exists, skip Step 11 (see
> [`synthetic_data/README.md`](../synthetic_data/README.md)).

---

## Primer: Git, GitHub, cloning and VS Code

You do not need to be a git expert, but you do need this mental model, because
the whole workspace is built on it.

**Why version control matters for observational research.** A published
estimate is only as trustworthy as your ability to show exactly how it was
produced. Git records every change to code, cohort definitions and concept
sets as a permanent, attributed, timestamped history. That gives you:

- **Transparency** — anyone can see who changed a cohort's inclusion criteria,
  when, and why (the commit message and PR description).
- **Reproducibility** — a result can be tied to one exact commit, so "the code
  that produced Table 2" is a specific, retrievable version, not "whatever was
  on my laptop". Combined with the pinned `renv.lock`, the code *and* its
  package versions can be rebuilt later.
- **Review** — changes reach `main` only through a pull request, so a second
  person sees every change to a definition before it becomes the shared one.
- **Safe collaboration** — each person works on their own branch, so
  experiments never overwrite a colleague's work, and any mistake can be
  undone.

**The vocabulary you need:**

| Term | Meaning |
|---|---|
| **Repository (repo)** | A project folder plus its full change history. |
| **Git vs GitHub** | Git is the tool that tracks history on your machine. GitHub is the website that hosts shared copies and runs pull requests. |
| **Clone** | Download a repo, history included, to your computer. Cloning a repo creates a folder with a hidden `.git/` inside. |
| **Commit** | A saved snapshot with a message explaining the change. |
| **Branch** | A parallel line of commits. Yours is named after your GitHub username. |
| **Push / pull** | Send your commits to GitHub / fetch others' commits from it. |
| **Pull request (PR)** | A proposal to merge your branch into `main`, where it is reviewed. |
| **Submodule** | A repo pinned inside another repo. The four templates are submodules of the workspace. |

The everyday loop is: pull the latest `main` → make changes on your branch →
commit with a clear message → push → open a PR. Never edit `main` directly,
and never commit secrets or data (`.env`, `omop_vocab/` and any `output/`
folder are gitignored for this reason). Your AI assistant runs these same git
commands for you using your credentials, so you remain the author of record;
read what it proposes before approving a push.

**Why VS Code.** VS Code is the editor, but its real job here is hosting the
**dev container**: with the Dev Containers extension it opens this workspace
*inside* the Docker container, so your editor, terminal and R session all run
in the same pinned environment as your collaborators. It also has built-in git
(the Source Control panel) if you prefer a UI to the command line.

---

## About terminals

This guide uses two different terminals:

- **Your system terminal** — Terminal.app (Mac) or PowerShell (Windows).
  Used only in Steps 2 and 8, before the container exists.
- **The container terminal** — a terminal inside VS Code (`` Ctrl+` `` /
  `` Cmd+` ``) after the dev container is running. This shell is *inside* the
  container, where R, Java and the HADES packages live. Everything from
  Step 7 onward runs here unless stated.

---

## Step 1: Create a GitHub Account (2 minutes)

Your GitHub **username becomes your working-branch name** in every repo, and
your assistant uses it to detect which branch is yours, so pick one you are
happy to keep.

1. Sign up at [github.com](https://github.com) with your institutional email
   (the Free plan is enough).
2. Ask the workspace maintainer to add you as a collaborator on the workspace
   repo and on any study repos you will work in.

You will create a personal access token in Step 6.

---

## Step 2: Install Git (5 minutes)

1. Install from [git-scm.com/downloads](https://git-scm.com/downloads)
   (accept the defaults on Windows).
2. In your **system terminal**, set your identity:

```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@org.edu"
git config --global init.defaultBranch main
```

---

## Step 3: Install Docker Desktop (5 minutes)

Docker runs both the SQL Server database and the dev container, so it must be
running whenever you work.

Install from [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/),
launch it, and wait for **"Engine running"**. Apple Silicon is supported
natively; the database image (`azure-sql-edge`) is ARM64-native.

### 3.1 Configure disk and memory limits

In **Settings → Resources → Advanced**:

| Setting | Value | Why |
|---|---|---|
| **Virtual disk limit** | **60–80 GB** | The workspace uses ~35 GB (image, loaded vocabulary, R packages). Extra room is for build cache. The default can be 200+ GB and grows unchecked when builds fail. |
| **Memory** | **16 GB** (12 GB minimum) | The vocabulary loader reads multi-GB CSVs fully into R — the 6.3M-row `CONCEPT` table alone peaks near 12 GB. At 8 GB the Linux OOM killer ends the loader silently. If your machine has 16 GB total, give Docker 12 GB. |

> **The loaded vocabulary persists** on a Docker volume (`mssql_dev_data`). It
> survives container rebuilds and Docker restarts, so you load it once.

> **Reclaiming disk.** If Docker is using 100+ GB from old builds, clear the
> build cache and unused images only:
> ```bash
> docker image prune -a
> docker builder prune -a
> ```
> ⚠️ **Never add `--volumes`** (e.g. `docker system prune --volumes`) unless you
> intend a full reset. It deletes the SQL Server data volume, including the
> loaded vocabulary, and nothing re-downloads it — you would repeat Steps 8–9.

---

## Step 4: Install VS Code and the Dev Containers Extension (5 minutes)

1. Install VS Code from [code.visualstudio.com](https://code.visualstudio.com).
2. In the Extensions panel, install **Dev Containers**
   (`ms-vscode-remote.remote-containers`).

The Claude Code assistant is installed automatically when the container
builds — nothing to do here.

---

## Step 5: Clone the Workspace Repository (2 minutes)

The workspace repo is the infrastructure repo (your lab's copy of charon). From
your **system terminal**, in the folder where you keep code:

```bash
git clone --recurse-submodules https://github.com/<your-org>/<your-workspace-repo>.git
cd <your-workspace-repo>
```

`--recurse-submodules` also fetches the four template submodules
(`synthea-omop-template`, `omop-etl-template`, `strategus-study-template`,
`omop-report-template`). If you cloned without it, run
`git submodule update --init`. This folder is your **workspace root**
(`<workspace-root>` in these docs); inside the container it appears as
`/workspace`.

You can also clone from VS Code (**Source Control → Clone Repository**).

---

## Step 6: Configure Your .env File and Build the Dev Container (15–25 minutes)

### 6.1 Create `.env`

`.env` holds your secrets and is gitignored. Copy the template:

```bash
cp .env.example .env
```

(Windows PowerShell: `Copy-Item .env.example .env`.) Keep `.env.example` as a
reference. Open `.env` in VS Code and set the three values below. The other
variables have working defaults for local development; leave them.

### 6.2 `ANTHROPIC_API_KEY`

Your key from [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys).
It lets Claude Code run inside the container.

### 6.3 `GH_TOKEN`

A GitHub personal access token. One token serves two purposes: it lets the
assistant commit, push and open PRs as you, and the container reuses it as
`GITHUB_PAT` so `renv` can restore HADES packages hosted on GitHub without
hitting the 60-requests-per-hour anonymous rate limit (which a shared
university network exhausts quickly, failing the container build).

1. Go to [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new).
2. Name it after the workspace repo; expiration 90 days.
3. Repository permissions: **Contents: Read-only**, **Pull requests: Read and write**.
4. Generate, copy it immediately, and paste it into `.env`.

### 6.4 `MSSQL_SA_PASSWORD`

The password for the SQL Server `SA` account, which you choose. It needs 8+
characters with upper, lower, digit and a symbol (`@ # $ %`). **Do not use
`!`.** It must stay the same for the life of the database volume — changing
it later causes "Login failed for user 'SA'" (see
[SETUP.md](SETUP.md#troubleshooting)).

Save `.env`.

### 6.0 Match the container to your secure environment (before the first build)

Code you write here is later **run in your institution's secure analytics
environment**, so the container must use the same R, Java and Python versions
that environment provides. The defaults (R 4.5.2, Java 17, Python 3.12) are
those of the environment charon was originally built for — they are almost
certainly **not** yours. Mismatches cause real failures: packages locked for
one R version that won't install on another, `rJava`/JDBC behaviour that
differs by Java version, and Python models (pickles) that only load under the
library versions that created them.

**1. Find your secure environment's versions.** Ask its administrators, or run
these there:

```bash
R -e 'R.version.string'      # R version
java -version                # Java (JDK) version
python3 --version            # Python version (and `pip list` for scikit-learn, numpy, pandas)
```

Also note how packages get there (an internal CRAN/Posit mirror, a frozen
snapshot date, prebuilt binaries only), because the pinned `renv.lock` must be
installable from it.

**2. Set the versions in `.env`** (uncomment and edit the three lines in the
"Toolchain versions" block of `.env.example`'s copy):

```
R_VERSION=4.4.3
JAVA_VERSION=11
PYTHON_VERSION=3.11
```

- `R_VERSION` must be a tag of [`rocker/r-ver`](https://hub.docker.com/r/rocker/r-ver/tags).
  If the exact patch release you need isn't published, use the closest one
  with the same minor version. The tag also fixes the Ubuntu release.
- `JAVA_VERSION` is an OpenJDK major version (8, 11, 17, 21…) that is available
  from `apt` on that Ubuntu release. If the build fails with "Unable to locate
  package openjdk-N-jdk-headless", that version isn't offered there; pick a
  different `R_VERSION` or JDK.
- `PYTHON_VERSION` is any CPython that `uv` can install. The virtualenv at
  `/opt/mlenv` also pins `scikit-learn==1.2.2` and `numpy<2.0` in
  `.devcontainer/Dockerfile`; change those to your secure environment's
  versions (or to whatever version created any stored model you will load).

**3. If you changed `R_VERSION`, reconcile `renv.lock`.** The workspace
`renv.lock` records R 4.5.2 and the package versions built for it. After
the first build with your R version, run in the container terminal:

```r
renv::status()      # shows packages out of sync with the lockfile or the R version
renv::restore()     # if packages fail to install, an older R may need older package versions
renv::snapshot()    # once working, record the new R version and package set
```

Commit the updated `renv.lock` in a PR. Study repos have their own lockfiles
(Strategus repos pin a large set), so repeat this in each repo you use. Where a
locked package version cannot be installed on your R version, pick the newest
version that your secure environment's package source also offers.

**4. Record the decision** in `WORKSPACE_ROSTER.md` ("Secure-environment
toolchain") so collaborators and future you know what the container targets.

**5. Verify after the build** (Step 7): `R --version`, `java -version`,
`/opt/mlenv/bin/python --version` should each print your versions. Change
versions **before** you start real work and rebuild with
**Dev Containers: Rebuild Container**; switching mid-study changes the
environment your earlier results were produced in.

### 6.5 Build the container

With Docker running, in VS Code open the workspace folder, press
`Ctrl/Cmd+Shift+P`, and run **Dev Containers: Reopen in Container**.

The first build takes 10–20 minutes:

1. Builds the image: R (`rocker/r-ver:$R_VERSION`), the JDK, system libraries,
   a Python virtualenv at `/opt/mlenv`, and Claude Code — at the versions you
   set in 6.0 (defaults: R 4.5.2, Java 17, Python 3.12).
2. Starts the SQL Server container (`mssql_dev`) alongside the dev container
   on a shared Docker network.
3. Restores the workspace `renv.lock` (full HADES + tidyverse stack). Packages
   are cached in a Docker volume, so later rebuilds take about a minute.

> **Claude Code model:** the container defaults to Haiku to keep costs low. It
> handles file edits, git and running scripts well. Switch with `/model sonnet`
> when writing new analysis code or debugging, and `/model opus` for study
> design. See `CLAUDE.md` → "Claude Code Model Selection".

---

## Step 7: Verify Your Environment (2 minutes)

In the **container terminal**:

```bash
echo $IN_DEV_CONTAINER          # Should print: true
R --version                     # Should show your R_VERSION (default 4.5.2)
java -version                   # Should show your JAVA_VERSION (default 17)
/opt/mlenv/bin/python --version # Should show your PYTHON_VERSION (default 3.12)
echo $MSSQL_HOST                # Should print: mssql_dev
```

`docker ps` should also list `mssql_dev` as healthy (the host's Docker
socket is mounted into the container, so this works from inside).

Authenticate `gh` for your assistant:

```bash
gh auth login --with-token <<< "$GH_TOKEN"
gh auth status          # Should show: Logged in to github.com
```

> If `$MSSQL_HOST` is empty, or R reports "connection refused" on
> `localhost:1433`, see
> [Troubleshooting](#connection-refused-on-localhost1433).

**You do not create the database by hand.** The vocabulary loader in Step 9
creates `omop_synth` if it is missing.

### Optional: Zotero reference library

If your workspace root contains an `.mcp.json`, it configures an MCP server
that lets the assistant read your lab's Zotero group library. To enable it, set
`ZOTERO_API_KEY` (a personal, read-only key from
[zotero.org/settings/keys](https://www.zotero.org/settings/keys)) and
`ZOTERO_GROUP_ID` (from `zotero.org/groups/<ID>/library`) in `.env`, then
**Dev Containers: Rebuild Container**. Details:
[SETUP.md → Step 5b](SETUP.md#step-5b--mcp-servers-shared-config-personal-credentials).
If there is no `.mcp.json`, skip this; nothing else depends on it.

Keep reference PDFs in Zotero, not in a repo's `docs/` folder.

---

## Step 8: Download OMOP Vocabulary Files (30–60 minutes, one-time)

Every study on this machine reads the same loaded vocabulary, so you do this
once. **The vocabulary files are licensed and are never committed or shared**;
each person downloads their own.

### 8.1 Download from Athena

1. Sign in at [athena.ohdsi.org](https://athena.ohdsi.org) → **Download** →
   **Create new download**.
2. Select these vocabularies:

| Vocabulary | Required | Notes |
|---|---|---|
| SNOMED | ✅ | Primary clinical vocabulary |
| RxNorm | ✅ | Drug ingredients |
| RxNorm Extension | ⭐ | Drugs not in RxNorm |
| LOINC | ✅ | Measurements |
| ICD10CM | ✅ | US diagnoses |
| CPT4 | ⭐ | US procedures (needs UMLS key — 8.3) |
| HCPCS | ⭐ | US outpatient procedures |
| ICD10PCS | ⭐ | US inpatient procedures |
| Visit | ✅ | Visit types |
| Gender / Race / Ethnicity | ✅ | Demographics |
| UCUM | ✅ | Units |

3. Accept the license and download (a 2–5 GB zip).

### 8.2 Place it in the workspace

Extract the zip so that the **CSV files sit directly inside** a folder named
`omop_vocab/` at the workspace root — `omop_vocab/CONCEPT.csv`, not
`omop_vocab/<download-name>/CONCEPT.csv`. The container mounts this folder
read-only at `/omop_vocab`. (If the folder did not exist when the container
started, rebuild the container so the mount appears.)

### 8.3 Optional: rebuild CPT-4

**Skip this if you did not select CPT4.** CPT-4 is owned by the AMA, so Athena
ships only a Java utility (`cpt4.jar`, run by `cpt.sh`) that fetches the codes
from the NLM using your free UMLS account.

1. Create a UMLS account at [uts.nlm.nih.gov](https://uts.nlm.nih.gov)
   (approval is usually same-day), then copy the API key from
   **My Profile**.
2. In the **container terminal** (Java is already installed there):

```bash
cd /omop_vocab
bash cpt.sh YOUR_API_KEY_HERE
```

This takes 5–15 minutes and writes `CONCEPT_CPT4.csv`, appending the rows to
`CONCEPT.csv`. **Do not interrupt it** — the script warns that doing so can
corrupt `CONCEPT.csv`. Check with `ls -lh /omop_vocab/CONCEPT_CPT4.csv`
(several MB). Skipping this is safe; CPT-4-only procedures will just be
unmapped until you run it, and SNOMED covers most common procedures.

---

## Step 9: Load OMOP Vocabulary into SQL Server (30–60 minutes, one-time)

From the workspace root, in the **container terminal**:

```bash
Rscript infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template
```

The loader does everything, including database creation:

1. Creates the `omop_synth` database if missing.
2. Checks RAM and warns below ~12 GB.
3. Caps SQL Server's memory during the load so it cannot starve R, then
   restores a balanced value afterward.
4. Creates the `omop_vocab` schema and the vocabulary tables, bulk-loads the
   CSVs, and builds indexes.

(`--study-dir` just tells the script which repo's helper code to use; leave it
as shown.) `CONCEPT_ANCESTOR` alone is ~75M rows, so leave it running.

**Expected tail of the output:**
```
[INFO] ✓ Vocabulary loaded successfully into 'omop_vocab'
=== Setup complete ===
```

> A silent exit partway through is the Linux OOM killer: raise Docker's memory
> to 16 GB, restart, and re-run. The loader is safe to re-run and skips once
> the vocabulary is fully loaded.

If it fails or stalls, see [TROUBLESHOOTING_VOCAB_LOAD.md](TROUBLESHOOTING_VOCAB_LOAD.md).

**Sanity check** — look up a concept (this script ships in
`synthea-omop-template/scripts/`, so run it from there, or ask your assistant
to run `/concept-lookup diabetes mellitus Condition`):

```bash
cd synthea-omop-template && Rscript scripts/concept_lookup.R "diabetes mellitus" Condition
```

You should get SNOMED standard concepts labelled `[vocab query]`.

---

## Step 10: Create Your Study Repositories (10 minutes)

Pick the repos you need. Most studies need the first two; the third is only for
generating a new synthetic dataset.

| Repo | Create from | When |
|---|---|---|
| `<study>` — analysis-core | [`strategus-study-template`](https://github.com/Duke-Vascular-Informatics/strategus-study-template) | Always |
| `<study>-report` — report | [`omop-report-template`](https://github.com/Duke-Vascular-Informatics/omop-report-template) | Always, even for a purely descriptive study |
| `<study>-synth` — synthetic data generation only | [`synthea-omop-template`](https://github.com/Duke-Vascular-Informatics/synthea-omop-template) | Only if no entry in `synthetic_data/registry.yaml` fits — check first with `Rscript synthetic_data/scripts/lookup_dataset.R --disease "<term>"` |

For why a study is split this way, see the README's
[What a study looks like](../README.md#what-a-study-looks-like).

### 10.1 Create each repo on GitHub

For each repo above: open its template on GitHub → **Use this template** →
**Create a new repository**; name it per the table; set visibility to
**Private**.

### 10.2 Clone inside the workspace

In the **container terminal**, from `/workspace`. Clone as **siblings**, never
nested in each other:

```bash
cd /workspace
git clone https://github.com/<your-org>/<study>.git
git clone https://github.com/<your-org>/<study>-report.git
```

Add each folder name to the workspace `.gitignore` (they are separate repos)
and register them in `studies.yaml`.

### 10.3 Create your personal working branch (in every repo)

Everyone works on a branch named after their GitHub username:

```bash
cd /workspace/<study>
BRANCH=$(gh api user --jq .login)
git checkout -b "$BRANCH"
git push -u origin "$BRANCH"
```

Repeat in `<study>-report` (and the workspace repo itself if you will edit it).
All commits go to your branch and reach `main` only through a pull request
(squash merge). **Never push to `main`, and never push to another person's
branch** — if you see a branch named after someone else, leave it alone.

### 10.4 Keep your branch current

Infrastructure fixes land in `main` often. At the start of each session, in
every repo you work in:

```bash
BRANCH=$(gh api user --jq .login)
git checkout main && git pull origin main
git checkout "$BRANCH" && git rebase main
git push origin "$BRANCH"
```

After **your own PR is squash-merged**, do **not** rebase — the squash rewrote
your commits, so rebasing produces spurious conflicts. Instead follow
"After a PR is merged into main" in [`CLAUDE.md`](../CLAUDE.md).

### 10.5 Set up the analysis-core and report repos

Now follow each template's own instructions — they are the source of truth for
that repo:

- **`<study>`:** read `README.md`, then `docs/STRATEGUS_CONVENTIONS.md` (ten
  minutes; every item is a bug that cost a real study weeks), then work through
  `CHECKLIST.md` Path A.
- **`<study>-report`:** `CHECKLIST.md` Path A, once `<study>/output/` exists.
  **The report repo never connects to a database.** If you want to add a query
  there, put it in `<study>/R/extract_report_inputs.R` instead.

Before writing any cohort or concept set, read
[`phenotype_library/README.md`](../phenotype_library/README.md): you must check
the OHDSI Phenotype Library, your lab's ATLAS definitions, and the local
catalog before running a live vocabulary query ([Rule 1](../README.md#rules-you-must-follow)).

```
/workspace/
├── <study>/            ← analysis-core; output/ is read by the report repo
└── <study>-report/     ← report repo (sibling)
```

---

## Step 11: Run the Study Workflow (2–3 hours total)

> **Which repo is this for?** Step 11 applies only to a **`-synth` repo**
> (`synthea-omop-template`), whose sole purpose is to generate an
> analysis-specific synthetic dataset (Workflows 01–06). It contains no
> analysis: the analysis runs in your Strategus analysis-core repo, following
> its `CHECKLIST.md`, and the manuscript in your report repo. A `-synth`
> repo's job ends when the dataset is built, quality-checked and registered.

All commands run in the **container terminal** from the repo's folder:

```bash
cd /workspace/<study>-synth
```

### Workflow 01 — Environment setup

Run once per repo. Restores packages, provisions the JDBC driver, and opens a
test connection.

```bash
Rscript workflow/01_setup_synthea_etl_qc_env.R
```

### Workflow 02 — What the dataset must support ✏️ *Edit `consumers.yaml` first*

A `-synth` repo defines no cohorts, outcomes or covariates of its own. What the dataset must
contain is defined by the studies that will use it, so list them in `consumers.yaml` (their
cohort definitions in their own Strategus repos are read directly; nothing is copied here). Also
set `study_params.yaml` (`study_name`, `cdm_schema`, and the database description). Then run:

```bash
Rscript scripts/check_setup.R                                    # [OK] / [WARN] / [FAIL] checklist
Rscript workflow/02_define_omop_cohort_outcome_covariates.R      # lists each study's cohorts
```

Workflow 02 needs no database. It prints each consuming study's target, outcome and covariate
cohorts and warns about anything that would stop later checks (study repo not cloned, missing
cohort JSON, unresolvable target or outcome id). The same list drives Workflow 03 and 06.

### Workflow 03 — Validate Synthea module, check it covers the consuming studies

Checks the Synthea disease module (the JSON state machine that decides what synthetic patients
get), then checks — before any data is generated — that the custom module **and** Synthea's
built-in modules can produce the cohorts of every study in `consumers.yaml`
(`--enforce_coverage=true` stops on a gap). No edits.

```bash
Rscript workflow/03_generate_synthea_module_artifacts.R
```

### Workflow 04 — Generate synthetic patients

Runs Synthea (a Java program) to produce synthetic patient CSVs. No edits.

```bash
bash workflow/04_generate_synthea_csv.sh
```

> Windows: `powershell -ExecutionPolicy Bypass -File workflow/04_generate_synthea_csv.ps1`.
> Do not run `.sh`/`.ps1` files with `Rscript`.

### Workflow 05 — Load into OMOP CDM

Converts the CSVs to OMOP CDM v5.4 tables in SQL Server, linking to the shared
`omop_vocab` schema rather than reloading it. No edits. On failure see
[TROUBLESHOOTING_ETL.md](TROUBLESHOOTING_ETL.md).

```bash
Rscript workflow/05_etl_csv_to_omop.R
```

### Workflow 06 — Quality check

Runs data-quality checks and confirms your phenotype definitions find patients.

```bash
Rscript workflow/06_quality_check_defined_phenotypes.R
```

This is the last step of a `-synth` repo. Register the dataset in
`synthetic_data/registry.yaml` so your analysis-core repo (and other studies)
can use it — see [`synthetic_data/README.md`](../synthetic_data/README.md) for how
an analysis-core repo points at a registered dataset.

---

## Troubleshooting

- Infrastructure and container: [SETUP.md](SETUP.md)
- Vocabulary load: [TROUBLESHOOTING_VOCAB_LOAD.md](TROUBLESHOOTING_VOCAB_LOAD.md)
- Synthetic data and ETL: [TROUBLESHOOTING_ETL.md](TROUBLESHOOTING_ETL.md)

### Docker using too much disk space

Docker's virtual disk grows with every build, including failed ones, and never
shrinks on its own. Clear build cache and unused images — **without** touching
volumes:

```bash
docker image prune -a
docker builder prune -a
```

Then set the virtual disk limit as in
[Step 3.1](#31-configure-disk-and-memory-limits). Do **not** use `--volumes`
unless you intend to wipe the database and reload the vocabulary.

### "Connection refused" on `localhost:1433`

Typical error:

```
com.microsoft.sqlserver.jdbc.SQLServerException: The TCP/IP connection to
the host localhost, port 1433 has failed. Connection refused.
```

Inside the container, `localhost` is the container itself, not the database.
The database is the `mssql_dev` host; `MSSQL_HOST=mssql_dev` is injected by
`.devcontainer/docker-compose.yml`, and only changes after a **rebuild**, not a
reopen.

> **Do not set `MSSQL_HOST` in `.env`.** Adding `MSSQL_HOST=localhost` there
> would override the container value and break every in-container script. (On
> the host, `config.R` defaults to `localhost` automatically.)

Fix:

1. Update to the latest `main` (`git checkout main && git pull origin main`),
   then rebase your branch.
2. **Dev Containers: Rebuild Container**.
3. Re-run the Step 7 checks (`echo $MSSQL_HOST` → `mssql_dev`).

If `mssql_dev` is not running, start it from a **host** terminal at the
workspace root:

```bash
docker compose up -d
```

---

## Key Files

**Workspace root**

| File | Purpose |
|---|---|
| `docker-compose.yml` | SQL Server container |
| `.env` | Your secrets — never commit |
| `.env.example` | Reference template for `.env` |
| `omop_vocab/` | Vocabulary CSVs — never commit |
| `renv.lock` | Shared R package lockfile, restored on build |
| `infrastructure/scripts/` | Vocabulary loader and workspace scripts |
| `phenotype_library/catalog.yaml` | Verified concept sets |
| `studies.yaml` | Registry of your study repos |

**Analysis-core repo (`strategus-study-template` layout)**

| File | Purpose |
|---|---|
| `inst/cohorts/*.json` | circe cohort definitions |
| `CreateStrategusAnalysisSpecification.R` | Builds the analysis spec |
| `StrategusCodeToRun.R` | Runs it against the CDM |
| `output/` | Results (gitignored); read by the report repo |

**Report repo (`omop-report-template` layout)**

| File | Purpose |
|---|---|
| `GenerateReport.R` | Entry point: `Rscript GenerateReport.R` |
| `R/report_dispatch.R`, `R/report_helpers.R` | Your report composition — edit these |
| `export_data/` | Drop-zone for exports from a secure environment (gitignored) |
| `reports/` | Rendered `.docx` (gitignored) |

---

## Version Info

- **R / Java / Python:** whatever you set in `.env` per Step 6.0 to match your secure analytics environment (defaults: R 4.5.2, Java 17, Python 3.12 at `/opt/mlenv`)
- **SQL Server:** Azure SQL Edge (ARM64) or SQL Server 2022 (AMD64)
- **OMOP CDM:** v5.4
