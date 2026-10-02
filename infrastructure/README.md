# infrastructure/

Workspace-level infrastructure automation and one-time setup utilities.

These scripts are intentionally kept at the workspace root so study repositories
(e.g., `synthea-omop-template/`) remain focused on analysis design and execution.

## setup/

- `setup_docker_and_vocab.sh`
  Automated host setup for Docker SQL Server + OMOP vocabulary scaffolding (macOS/Linux).
- `setup_docker_and_vocab.ps1`
  Automated host setup for Docker SQL Server + OMOP vocabulary scaffolding (Windows PowerShell).

## scripts/

- `setup_omop_vocab_schema.R`
  One-time loader that creates and populates the shared `omop_vocab` schema.

## Usage

From workspace root:

```bash
# Linux/macOS host bootstrap
bash infrastructure/setup/setup_docker_and_vocab.sh

# Windows PowerShell host bootstrap
powershell -ExecutionPolicy Bypass -File infrastructure/setup/setup_docker_and_vocab.ps1

# One-time vocabulary load for a study repo
Rscript infrastructure/scripts/setup_omop_vocab_schema.R --study-dir synthea-omop-template
```
