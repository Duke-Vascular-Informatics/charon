#!/usr/bin/env bash
set -euo pipefail

# Install a stable headless Claude wrapper that resolves the extension-bundled binary.
cat >/usr/local/bin/claude <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

binary=""
for p in /root/.vscode-server/extensions/anthropic.claude-code-*/resources/native-binary/claude; do
  if [[ -x "$p" ]]; then
    binary="$p"
    break
  fi
done

if [[ -z "$binary" ]]; then
  echo "Claude binary not found. Ensure the anthropic.claude-code extension is installed in this container." >&2
  exit 1
fi

exec "$binary" "$@"
EOF

chmod +x /usr/local/bin/claude

# Provide a stable API-key helper so Claude can authenticate even when
# extension child processes do not inherit shell environment variables.
cat >/usr/local/bin/anthropic-api-key-helper <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  printf "%s" "${ANTHROPIC_API_KEY}"
  exit 0
fi

if [[ -f /workspace/.env ]]; then
  key=$(grep -E '^ANTHROPIC_API_KEY=' /workspace/.env | tail -n 1 | cut -d '=' -f2- | tr -d '\r' || true)
  key="${key%\"}"
  key="${key#\"}"
  key="${key%\'}"
  key="${key#\'}"
  if [[ -n "$key" ]]; then
    printf "%s" "$key"
    exit 0
  fi
fi

echo "ANTHROPIC_API_KEY not found in environment or /workspace/.env" >&2
exit 1
EOF

chmod +x /usr/local/bin/anthropic-api-key-helper

# Configure Claude's user settings so extension sessions use API-key auth
# without prompting for OAuth in the UI.
mkdir -p /root/.claude
cat >/root/.claude/settings.json <<'EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "apiKeyHelper": "/usr/local/bin/anthropic-api-key-helper",
  "forceLoginMethod": "console"
}
EOF

# Quick non-interactive health check if API key exists.
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  claude --bare -p "Reply with exactly: headless_ok" >/tmp/claude_headless_check.txt 2>/tmp/claude_headless_check.err || true
fi
