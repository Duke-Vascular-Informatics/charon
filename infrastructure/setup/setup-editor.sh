#!/usr/bin/env bash
set -euo pipefail

# Load workspace defaults from .env when available. Values already present in the
# process environment take precedence over file-defined values.
if [[ -f /workspace/.env ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and blank lines.
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue

    # Accept KEY=VALUE entries without executing shell code.
    if [[ "$line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*= ]]; then
      key_part="${line%%=*}"
      key="${key_part#"${key_part%%[![:space:]]*}"}"
      key="${key%"${key##*[![:space:]]}"}"
      value="${line#*=}"
      value="${value%$'\r'}"

      # Preserve existing environment values from the container runtime.
      if [[ -z "${!key+x}" ]]; then
        export "$key=$value"
      fi
    fi
  done < /workspace/.env
fi

# Normalize database host defaults for container-internal workflows.
export MSSQL_HOST="${MSSQL_HOST:-${DEVCONTAINER_MSSQL_HOST:-mssql_dev}}"
export OMOP_SERVER="${OMOP_SERVER:-${DEVCONTAINER_OMOP_SERVER:-$MSSQL_HOST}}"

post_create_script="/workspace/infrastructure/scripts/post-create-workspace.sh"

if [[ ! -f "$post_create_script" ]]; then
  echo "Missing post-create script: $post_create_script" >&2
  exit 1
fi

bash "$post_create_script"
