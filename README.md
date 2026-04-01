# GitHub Actions Lockdown Script

Forked a repo and suddenly dozens of GitHub Actions workflows started appearing or queuing?  
This script is the one-command cleanup: it quickly locks down Actions in your fork (or any repo you can access) by disabling repo Actions, disabling workflows, and canceling pending runs.

## Requirements

- `gh` (GitHub CLI) authenticated (`gh auth login`)
- Token with `repo` scope for private repos (public repos typically work with standard scopes)

## Usage

```bash
./disable-actions-interactive.sh
```

Or target a repo directly:

```bash
./disable-actions-interactive.sh --repo OWNER/REPO
./disable-actions-interactive.sh --repo https://github.com/OWNER/REPO
```

Skip confirmation:

```bash
./disable-actions-interactive.sh --repo OWNER/REPO --yes
```

## What it can do

- Disable repository-level GitHub Actions
- Disable all workflows (`disabled_manually`)
- Cancel queued/in-progress runs

Default interactive option is **Full lockdown**.
