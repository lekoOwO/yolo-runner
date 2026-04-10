#!/usr/bin/env bash
set -euo pipefail

# Merge latest v* tag from remote 'runner' into current branch.
# Rules:
# - Always preserve local README.md (keep ours)
# - Always preserve local workflow files under .github/workflows/ (keep ours)
# - Preserve files that exist locally but are not present in the runner repo at that tag
# - For other conflicted files, accept remote (theirs)

usage() {
  cat <<EOF
Usage: $0 [--push [remote [branch]]] [--dry-run]
  --push : push after successful merge. Optionally provide remote and branch.
  --dry-run : show what would happen without committing (will still attempt a merge with --no-commit).
EOF
}

DRY_RUN=0
PUSH=0
PUSH_REMOTE=origin
PUSH_BRANCH=HEAD

forced_local=()
accepted_remote=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --push) PUSH=1; shift; if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then PUSH_REMOTE="$1"; shift; fi; if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then PUSH_BRANCH="$1"; shift; fi ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

echo "Fetching tags from remote 'runner'..."
git fetch runner --tags

LATEST_TAG=$(git ls-remote --tags --refs runner 'v*' | awk '{print $2}' | sed 's#refs/tags/##' | sed 's/\^{}//' | sort -V | tail -n1 || true)

if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" = "" ]; then
  echo "No runner tag starting with 'v' found on remote 'runner'" >&2
  exit 3
fi

echo "Latest runner tag: $LATEST_TAG"

echo "Attempting merge (no commit) of $LATEST_TAG..."
set +e
# If a merge is already in progress (MERGE_HEAD exists), detect whether it has unresolved files
if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  echo "Detected an existing in-progress merge (MERGE_HEAD present)."
  unmerged=$(git diff --name-only --diff-filter=U || true)
  if [ -z "$unmerged" ]; then
    echo "No unmerged files found — treating as merged (will finalize below)."
    MERGE_RC=0
  else
    echo "Unmerged files present; will run conflict resolution." 
    MERGE_RC=1
  fi
else
  git merge --no-commit --no-ff "$LATEST_TAG"
  MERGE_RC=$?
fi
set -e

if [ $MERGE_RC -eq 0 ]; then
  echo "Merged cleanly."
  if [ $DRY_RUN -ne 1 ]; then
    git commit -m "Merge runner $LATEST_TAG"
  else
    echo "Dry-run enabled: not committing.";
  fi
else
  echo "Merge produced conflicts; resolving per rules..."

  TMP_RUNNER_FILES=$(mktemp)
  git ls-tree -r --name-only "$LATEST_TAG" > "$TMP_RUNNER_FILES"

  conflicted_files=$(git diff --name-only --diff-filter=U || true)

  forced_local=()
  accepted_remote=()

  for f in $conflicted_files; do
    # Always prefer local for README.md
    if [ "$f" = "README.md" ]; then
      echo "Preserving local README.md"
      git checkout --ours -- "$f"
      git add "$f"
      forced_local+=("$f")
      continue
    fi

    # Always prefer local for workflows
    case "$f" in
      .github/workflows/*)
        echo "Preserving local workflow: $f"
        # If the file existed in HEAD (ours) then checkout ours, otherwise ensure it's removed (preserve local deletion)
        if git ls-tree -r --name-only HEAD | grep -Fxq -- "$f"; then
          git checkout --ours -- "$f" || true
          git add "$f" || true
        else
          git rm -f -- "$f" || true
        fi
        forced_local+=("$f")
        continue
        ;;
    esac

    # If file does NOT exist in runner tag, preserve local (this repo-specific file)
    if ! grep -Fxq -- "$f" "$TMP_RUNNER_FILES"; then
      echo "Preserving local-only file: $f"
      git checkout --ours -- "$f"
      git add "$f"
      forced_local+=("$f")
      continue
    fi

    # Otherwise accept remote
    echo "Accepting remote version for: $f"
    git checkout --theirs -- "$f"
    git add "$f"
    accepted_remote+=("$f")
  done

  rm -f "$TMP_RUNNER_FILES"

  if [ $DRY_RUN -ne 1 ]; then
    git commit -m "Merge runner $LATEST_TAG — resolve conflicts: preserve local README/workflows/local-only files"
  else
    echo "Dry-run: not committing merge.";
  fi
fi

echo
echo "=== Merge Summary ==="
echo "Merged tag: $LATEST_TAG"
echo "Commit: $(git --no-pager log -1 --pretty=format:'%h %s')"
echo
if [ "${#forced_local[@]}" -gt 0 ]; then
  echo "Files preserved from local (ours):"
  for p in "${forced_local[@]}"; do echo " - $p"; done
else
  echo "No files forced to local." 
fi

if [ "${#accepted_remote[@]}" -gt 0 ]; then
  echo "Files accepted from remote (theirs):"
  for p in "${accepted_remote[@]}"; do echo " - $p"; done
else
  echo "No conflicted files accepted from remote." 
fi

echo
echo "Git status:"; git status --porcelain

if [ $PUSH -eq 1 ]; then
  echo "Pushing to $PUSH_REMOTE $PUSH_BRANCH..."
  git push "$PUSH_REMOTE" "$PUSH_BRANCH"
fi

exit 0
