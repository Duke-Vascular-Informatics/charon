# Git and GitHub Authentication (Detailed)

This guide expands the authentication steps in `GETTING_STARTED.md` (Steps 6–7).

If SSH works on your host but fails inside a VS Code dev container, see the
SSH forwarding section in [GETTING_STARTED.md](GETTING_STARTED.md) (Step 7.5).

---

## AI Agent GitHub Access

Your AI coding assistant (Claude Code, GitHub Copilot, or similar) runs `git` and `gh`
commands in the terminal using **your** credentials. It has no independent GitHub account.

For the agent to commit, push, and open pull requests, two things must be in place:

| What the agent does | Credential it uses |
|---|---|
| `git push`, `git pull`, `git clone` | SSH key (preferred) or HTTPS token |
| `gh pr create`, `gh pr merge`, `gh issue list` | GitHub CLI — `gh auth login` |

**Quick setup (run once on your host machine):**

```bash
# 1. Authenticate the GitHub CLI
gh auth login
# → Choose: GitHub.com → HTTPS → Login with a web browser

# 2. Confirm both git and gh are ready
gh auth status
git config --global user.name
git config --global user.email
```

**Inside the dev container** — the container has `gh` pre-installed but starts
unauthenticated. Re-authenticate once after first build:

```bash
# Option A: interactive login inside the container
gh auth login

# Option B: copy your host token (avoids a second browser auth)
# On HOST:
gh auth token          # copy the printed token

# In CONTAINER:
gh auth login --with-token <<< "<paste token here>"
gh auth status
```

SSH-based `git push` inside the container requires SSH agent forwarding
(see Step 7.5 in [GETTING_STARTED.md](GETTING_STARTED.md)).

### What the agent can and cannot do

Once credentials are in place, the agent can:
- Stage, commit, and push changes to your working branch
- Open pull requests (`gh pr create --base main --head <branch>`)
- Merge pull requests (`gh pr merge --squash --admin`)
- Check CI status (`gh pr checks`) and list open issues

The agent will always show you the command before running a push or merge,
and will ask for confirmation. It will not push to `main` directly (protected branch)
and will not delete your permanent working branch.

---

## SSH Authentication (Recommended)

```bash
# Generate a key (press Enter for defaults)
ssh-keygen -t ed25519 -C "your.email@org.edu"

# Start ssh-agent and add key
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519

# Copy public key and add it in GitHub
cat ~/.ssh/id_ed25519.pub

# Test connection
ssh -T git@github.com
```

Add the copied key in GitHub:
- GitHub -> Settings -> SSH and GPG keys -> New SSH key

Expected test output includes:
- `Hi <username>! You've successfully authenticated...`

## HTTPS + Token-Backed Authentication

If you use GitHub CLI:

```bash
gh auth login
gh auth status
```

If you do not use GitHub CLI:
- Use HTTPS remotes
- Sign in when prompted by your credential manager or Git client

## Check Current Remote Type

```bash
git remote -v
```

- SSH remote example: `git@github.com:org/repo.git`
- HTTPS remote example: `https://github.com/org/repo.git`

## Switch Remote Type

```bash
# Switch to SSH
git remote set-url origin git@github.com:<org>/<repo>.git

# Switch to HTTPS
git remote set-url origin https://github.com/<org>/<repo>.git
```
