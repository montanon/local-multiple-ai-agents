#!/bin/zsh

# Git worktree helper script.
# Use it like this:
# gwt feature-name

cwt() {
    # Exit immediately on error
    set -e
    
    # Get the current Git project directory (must be inside a Git repo)
    local project_dir=$(git rev-parse --show-toplevel)
    
    # Get the base name of the current project folder
    local project_name=$(basename "$project_dir")
    
    # Get the desired feature/branch name from the first argument
    local feature_name="$1"
    
    # Fail fast if no feature name was provided
    if [ -z "$feature_name" ]; then
        echo "❌ Usage: cwt <feature-name>"
        return 1
    fi
    
    # Define the parent folder where all worktrees go, beside the main repo
    local worktree_parent="$(dirname "$project_dir")/${project_name}-worktrees"
    
    # Define the full path of the new worktree folder
    local worktree_path="${worktree_parent}/${feature_name}"
    
    # Create the parent worktrees folder if it doesn't exist
    mkdir -p "$worktree_parent"
    
    # Create the worktree and the branch
    git -C "$project_dir" worktree add -b "$feature_name" "$worktree_path"
    
    # Copy .env if it exists
    if [ -f "$project_dir/.env" ]; then
        cp "$project_dir/.env" "$worktree_path/.env"
        echo "📝 Copied .env into worktree."
    fi
    
    # List of hidden folders to copy if they exist
    local hidden_dirs=(.instrumental .claude .cursor)
    
    for dir in "${hidden_dirs[@]}"; do
        if [ -d "$project_dir/$dir" ]; then
            cp -R "$project_dir/$dir" "$worktree_path/$dir"
            echo "📂 Copied $dir into worktree."
        fi
    done
    
    # Open the worktree in Cursor
    cursor "$worktree_path" &
    
    echo "✅ Created worktree at: $worktree_path"
    echo "🚀 Opening in Cursor..."
}

dwt() {
  emulate -L zsh                 # localize zsh behavior
  setopt local_options           # options only within this function
  setopt local_traps             # traps only within this function
  setopt err_return pipe_fail no_unset   # safer than `set -euo pipefail` in zsh

  # must be inside a worktree
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null || true)
  if [[ -z "$git_dir" || "$git_dir" != *.git/worktrees/* ]]; then
    print -r -- "❌ You don't appear to be in a git worktree."
    print -r -- "💡 Run this from within a worktree directory."
    return 1
  fi

  local worktree_path git_common_dir main_repo worktree_name branch_name lock
  worktree_path=$(git rev-parse --show-toplevel)
  git_common_dir=$(git rev-parse --git-common-dir)
  main_repo=$(dirname "$git_common_dir")
  worktree_name=$(basename "$worktree_path")
  branch_name=$(git branch --show-current 2>/dev/null || true)
  lock="$main_repo/.git/index.lock"

  print -r -- "🗂️  Worktree: $worktree_name"
  print -r -- "📁 Path:     $worktree_path"
  print -r -- "🏠 Main repo: $main_repo"
  print -r -- ""

  read -r "?⚠️  Delete this worktree? [y/N]: " confirmation
  [[ "$confirmation" =~ '^[Yy]$' ]] || { print -r -- "❌ Cancelled."; return 0; }

  # helper: remove stale lock only if no process holds it
  local _cleanup_needed=0
  _remove_stale_lock() {
    if [[ -e "$lock" ]]; then
      if command -v lsof >/dev/null 2>&1 && lsof "$lock" >/dev/null 2>&1; then
        # in-use; do nothing
        :
      else
        rm -f -- "$lock"
      fi
    fi
  }

  # localize traps so they don't persist
  trap '_remove_stale_lock' INT TERM

  # preflight: clear stale lock (don’t touch if in use)
  if [[ -e "$lock" ]]; then
    if command -v lsof >/dev/null 2>&1 && lsof "$lock" >/dev/null 2>&1; then
      print -r -- "⏳ Git index in use at $lock. Close editors/terminals and retry."
      return 1
    else
      print -r -- "🧹 Removing stale index.lock"
      rm -f -- "$lock"
    fi
  fi

  # Do operations without changing the caller's directory
  if ! git -C "$main_repo" worktree remove "$worktree_path" --force; then
    print -r -- "❌ Failed to remove worktree."
    return 1
  fi
  print -r -- "🗑️  Removed worktree: $worktree_path"

  git -C "$main_repo" worktree prune >/dev/null 2>&1 || true

  if [[ -n "$branch_name" ]]; then
    read -r "?🌿 Delete branch '$branch_name' too? [y/N]: " bc
    if [[ "$bc" =~ '^[Yy]$' ]]; then
      # don’t delete if checked out elsewhere
      if git -C "$main_repo" worktree list | awk '{print $3}' | grep -qx "$branch_name"; then
        print -r -- "⚠️  Branch '$branch_name' is checked out in another worktree. Not deleting."
      else
        git -C "$main_repo" branch -D "$branch_name" || {
          print -r -- "⚠️  Could not delete branch '$branch_name'."
        }
        print -r -- "🗑️  Deleted branch: $branch_name"
      fi
    else
      print -r -- "🌿 Kept branch: $branch_name"
    fi
  else
    print -r -- "ℹ️  Detached HEAD; no branch to delete."
  fi

  # Post-op: if a lock shows up, surface info without deleting
  if [[ -e "$lock" ]]; then
    print -r -- "⚠️  index.lock exists after dwt: $lock"
    command -v lsof >/dev/null 2>&1 && lsof "$lock" || true
    print -r -- "   If no holder is listed, it's stale; remove with: rm '$lock'"
  fi

  print -r -- "✅ Done."
}