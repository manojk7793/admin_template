#!/usr/bin/env bash
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || exit 1

export PATH="$HOME/.local/bin:$PATH"

mkdir -p tasks/pending tasks/processing tasks/done tasks/failed logs

# Check required commands.
for cmd in agent git flock php gh; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command missing: $cmd"
        exit 1
    fi
done

# Verify Git repository and GitHub configuration.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Not inside a Git repository."
    exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
    echo "Git remote 'origin' is missing."
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "Sign in to GitHub CLI using: gh auth login"
    exit 1
fi

# Prevent multiple task runners.
exec 9>"$PROJECT_DIR/tasks/.runner.lock"
if ! flock -n 9; then
    echo "Another task runner is already running."
    exit 1
fi

# Require a clean working tree.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is not clean."
    echo "Review, commit, or safely stash your changes before running."
    exit 1
fi

# Discover pending tasks.
shopt -s nullglob
tasks=(tasks/pending/*.md)

if [[ ${#tasks[@]} -eq 0 ]]; then
    echo "No pending tasks found in tasks/pending/."
    exit 0
fi

# Interactive task selection.
echo
echo "======================================"
echo "       SELECT A TASK TO EXECUTE"
echo "======================================"

PS3="Enter task number (or choose Cancel): "

select task in "${tasks[@]}" "Cancel"; do
    if [[ -z "${REPLY:-}" ]] ||
       ! [[ "$REPLY" =~ ^[0-9]+$ ]] ||
       (( REPLY < 1 || REPLY > ${#tasks[@]} + 1 )); then
        echo "Invalid selection. Try again."
        continue
    fi

    if (( REPLY == ${#tasks[@]} + 1 )); then
        echo "Task execution cancelled."
        exit 0
    fi

    break
done

filename="$(basename "$task")"
processing="tasks/processing/$filename"
task_name="${filename%.md}"

# Make a safe Git branch name from the task filename.
slug="$(printf '%s' "$task_name" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"

timestamp="$(date +%Y%m%d-%H%M%S)"
branch="ai-task-${slug}-${timestamp}"
log="logs/${slug}-${timestamp}.log"

echo
echo "Selected task: $filename"

# Select the PR base branch.
BASE_BRANCH="${BASE_BRANCH:-}"

if [[ -z "$BASE_BRANCH" ]]; then
    read -r -p "Base branch [main]: " entered_branch
    BASE_BRANCH="${entered_branch:-main}"
fi

if [[ ! "$BASE_BRANCH" =~ ^[a-zA-Z0-9._/-]+$ ]] ||
   [[ "$BASE_BRANCH" == -* ]] ||
   [[ "$BASE_BRANCH" == *".."* ]]; then
    echo "Invalid base branch name."
    exit 1
fi

echo "Base branch: $BASE_BRANCH"

# Fetch the selected base branch.
if ! git fetch origin "$BASE_BRANCH"; then
    echo "Could not fetch origin/$BASE_BRANCH."
    exit 1
fi

# Switch to the local base branch or create it from origin.
if git show-ref --verify --quiet "refs/heads/$BASE_BRANCH"; then
    if ! git switch "$BASE_BRANCH"; then
        echo "Could not switch to $BASE_BRANCH."
        exit 1
    fi
else
    if ! git switch --track -c "$BASE_BRANCH" "origin/$BASE_BRANCH"; then
        echo "Could not create local base branch $BASE_BRANCH."
        exit 1
    fi
fi

if ! git pull --ff-only origin "$BASE_BRANCH"; then
    echo "Could not update $BASE_BRANCH safely."
    exit 1
fi

# Move the selected task into processing.
if ! mv -- "$task" "$processing"; then
    echo "Could not move task to processing."
    exit 1
fi

# Create a feature branch from the selected base branch.
if ! git switch -c "$branch" "$BASE_BRANCH"; then
    mv -- "$processing" "tasks/pending/$filename"
    echo "Could not create feature branch."
    exit 1
fi

# Mark the task failed if the agent or tests fail.
mark_failed() {
    if [[ -f "$processing" ]]; then
        mv -- "$processing" "tasks/failed/$filename" ||
            echo "Warning: could not move task to failed/"
    fi
}

# Prepare the agent prompt.
prompt="$(cat "$processing")

Follow the instructions in .cursor/rules/.
Inspect the existing code before editing.
Implement only the task requirements.
Add or update relevant automated tests.
Do not deploy, access production systems, or expose secrets.
Do not commit or merge changes yourself.
Report modified files, commands run, test results, and remaining issues."

echo "Feature branch: $branch"
echo "Starting task: $filename"
echo "Log file: $log"

# Run Cursor Agent.
if ! agent -p --trust --output-format text "$prompt" > "$log" 2>&1; then
    echo "Agent failed. Check $log"
    mark_failed
    exit 1
fi

# Run Laravel tests.
if ! php artisan test >> "$log" 2>&1; then
    echo "Laravel tests failed. Check $log"
    mark_failed
    exit 1
fi

# Build frontend if a build script exists.
if [[ -f package.json ]] &&
   npm run 2>/dev/null | grep -qE '^[[:space:]]+build([[:space:]]|$)'; then
    if ! npm run build >> "$log" 2>&1; then
        echo "Frontend build failed. Check $log"
        mark_failed
        exit 1
    fi
fi

# Mark implementation complete.
if ! mv -- "$processing" "tasks/done/$filename"; then
    echo "Could not move task to done."
    exit 1
fi

# Stage task changes and implementation, excluding logs and lock file.
if ! git add -A -- . \
    ':(exclude)logs/**' \
    ':(exclude)tasks/.runner.lock'; then
    echo "Could not stage changes."
    exit 1
fi

if git diff --cached --quiet; then
    echo "No changes to commit."
    echo "Review the agent output in $log."
    exit 1
fi

# Commit changes.
if ! git commit -m "Implement ${task_name}"; then
    echo "Commit failed. Review branch $branch."
    exit 1
fi

# Push feature branch.
if ! git push -u origin "$branch"; then
    echo "Push failed. Feature branch: $branch"
    exit 1
fi

# Create pull request and capture its URL.
pr_title="Implement ${task_name}"
pr_body="## Summary

Automated implementation of task: ${filename}

## Validation
- Laravel tests passed.
- Frontend build checked when available.

Please review the code and test results before merging.

Task log: ${log}"

echo
echo "Creating pull request..."

if pr_url="$(gh pr create \
    --base "$BASE_BRANCH" \
    --head "$branch" \
    --title "$pr_title" \
    --body "$pr_body")"; then
    echo
    echo "======================================"
    echo "TASK COMPLETED SUCCESSFULLY"
    echo "======================================"
    echo "Task: $filename"
    echo "Base branch: $BASE_BRANCH"
    echo "Feature branch: $branch"
    echo "Pull request: $pr_url"
    echo "Log: $log"
else
    echo "Could not create the pull request automatically."
    echo "Branch pushed: $branch"
    echo "Create the PR manually on GitHub."
    exit 1
fi
