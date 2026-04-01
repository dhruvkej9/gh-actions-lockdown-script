#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Interactive GitHub Actions lockdown script.

Usage:
  ./disable-actions-interactive.sh
  ./disable-actions-interactive.sh --repo OWNER/REPO
  ./disable-actions-interactive.sh --repo https://github.com/OWNER/REPO
  ./disable-actions-interactive.sh --repo OWNER/REPO --yes

Options:
  -r, --repo   Target repository (OWNER/REPO or GitHub URL)
  -y, --yes    Skip confirmation prompt
  -h, --help   Show this help
EOF
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

normalize_repo() {
  local input="$1"
  input="${input#https://github.com/}"
  input="${input#http://github.com/}"
  input="${input#github.com/}"
  input="${input%.git}"
  echo "$input"
}

valid_repo_format() {
  local r="$1"
  [[ "$r" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]
}

disable_repo_actions() {
  local repo="$1"
  gh api -X PUT "repos/$repo/actions/permissions" --input - <<'JSON' >/dev/null
{"enabled":false}
JSON
  echo "Repository-level Actions disabled."
}

disable_all_workflows() {
  local repo="$1"
  local disabled=0 already=0 failed=0
  local id name state err

  mapfile -t rows < <(gh api "repos/$repo/actions/workflows" --paginate --jq '.workflows[] | [.id, .name, .state] | @tsv')
  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "No workflows found."
    return 0
  fi

  for row in "${rows[@]}"; do
    IFS=$'\t' read -r id name state <<<"$row"
    if [[ "$state" == "disabled_manually" ]]; then
      ((already+=1))
      continue
    fi
    if gh api -X PUT "repos/$repo/actions/workflows/$id/disable" >/dev/null 2>"/tmp/disable-wf-$id.err"; then
      ((disabled+=1))
    else
      err="$(cat "/tmp/disable-wf-$id.err" || true)"
      if grep -qi "not active" <<<"$err"; then
        ((already+=1))
      else
        ((failed+=1))
        echo "Failed to disable workflow '$name' (id: $id): $err" >&2
      fi
    fi
    rm -f "/tmp/disable-wf-$id.err" || true
  done

  echo "Workflows updated: disabled=$disabled already_disabled=$already failed=$failed"
}

cancel_active_runs() {
  local repo="$1"
  local canceled=0 failed=0
  local id name status

  mapfile -t rows < <(gh run list -R "$repo" --limit 200 --json databaseId,status,workflowName --jq '.[] | select(.status=="queued" or .status=="in_progress" or .status=="waiting" or .status=="requested") | [.databaseId, .workflowName, .status] | @tsv')
  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "No queued/in-progress runs found."
    return 0
  fi

  for row in "${rows[@]}"; do
    IFS=$'\t' read -r id name status <<<"$row"
    if gh run cancel "$id" -R "$repo" >/dev/null 2>&1; then
      ((canceled+=1))
    else
      ((failed+=1))
      echo "Failed to cancel run $id ($name, $status)." >&2
    fi
  done

  echo "Run cancellation: canceled=$canceled failed=$failed"
}

show_summary() {
  local repo="$1"
  local enabled
  enabled="$(gh api "repos/$repo/actions/permissions" --jq '.enabled' 2>/dev/null || echo "unknown")"
  echo
  echo "Summary for $repo"
  echo "Actions enabled: $enabled"
  echo "Workflow states:"
  gh api "repos/$repo/actions/workflows" --paginate --jq '.workflows[].state' \
    | sort | uniq -c | awk '{print "  " $2 ": " $1}'
}

pick_repo_interactively() {
  local repo input owner
  owner="$(gh api user --jq '.login')"

  while true; do
    read -r -p "Repository (OWNER/REPO, URL, or '?' to list your repos): " input
    input="$(normalize_repo "$input")"

    if [[ "$input" == "?" ]]; then
      echo "Showing up to 100 repos for @$owner:"
      gh repo list "$owner" --limit 100 --json nameWithOwner,isPrivate --jq '.[] | "\(.nameWithOwner)\t(private=\(.isPrivate))"'
      continue
    fi

    if ! valid_repo_format "$input"; then
      echo "Invalid format. Example: dhruvkej9/opencode"
      continue
    fi

    if gh repo view "$input" >/dev/null 2>&1; then
      repo="$input"
      break
    fi

    echo "Cannot access repo '$input' with current auth. Try another."
  done

  echo "$repo"
}

repo_arg=""
assume_yes=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--repo)
      [[ $# -lt 2 ]] && { echo "--repo requires a value" >&2; exit 1; }
      repo_arg="$2"
      shift 2
      ;;
    -y|--yes)
      assume_yes=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

need_cmd gh

if ! gh auth status >/dev/null 2>&1; then
  echo "You are not logged into GitHub CLI. Run: gh auth login" >&2
  exit 1
fi

if [[ -n "$repo_arg" ]]; then
  repo="$(normalize_repo "$repo_arg")"
  if ! valid_repo_format "$repo"; then
    echo "Invalid repository format: $repo_arg" >&2
    exit 1
  fi
  if ! gh repo view "$repo" >/dev/null 2>&1; then
    echo "Cannot access repository: $repo" >&2
    exit 1
  fi
else
  repo="$(pick_repo_interactively)"
fi

echo
echo "Target repo: $repo"
echo "Choose operation:"
echo "  1) Full lockdown (recommended): disable repo Actions + disable all workflows + cancel queued runs"
echo "  2) Disable repo-level Actions only"
echo "  3) Disable all workflows only"
echo "  4) Cancel queued/in-progress runs only"
read -r -p "Choice [1]: " choice
choice="${choice:-1}"

if [[ "$assume_yes" -ne 1 ]]; then
  read -r -p "Proceed with choice $choice on $repo? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
  fi
fi

case "$choice" in
  1)
    disable_repo_actions "$repo"
    disable_all_workflows "$repo"
    cancel_active_runs "$repo"
    ;;
  2)
    disable_repo_actions "$repo"
    ;;
  3)
    disable_all_workflows "$repo"
    ;;
  4)
    cancel_active_runs "$repo"
    ;;
  *)
    echo "Invalid choice: $choice" >&2
    exit 1
    ;;
esac

show_summary "$repo"
