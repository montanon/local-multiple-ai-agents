#!/bin/zsh

# ============================================================================
# Git Worktree Helper Script
# ============================================================================
# A comprehensive toolkit for managing git worktrees with safety and ease.
#
# Available Functions:
#   cwt - Create a new git worktree
#   dwt - Delete a git worktree
#   lwt - List all git worktrees
#   swt - Switch between git worktrees
#   uwt - Update/pull git worktrees
#
# For help: run any function with -h or --help flag
# Or run: _gwt_help
# ============================================================================

# ============================================================================
# CONFIGURATION SYSTEM
# ============================================================================

_load_gwt_config() {
  emulate -L zsh
  setopt local_options no_unset

  # Get the git repo root
  local project_dir
  if ! project_dir=$(git rev-parse --show-toplevel 2>/dev/null); then
    return 1
  fi

  local config_file="$project_dir/.git-worktree-config"

  # Set sensible defaults
  export GWT_EDITOR="${GWT_EDITOR:-cursor}"
  export GWT_COPY_FILES="${GWT_COPY_FILES:-.env}"
  export GWT_COPY_DIRS="${GWT_COPY_DIRS:-.instrumental,.claude,.cursor}"
  export GWT_AUTO_OPEN="${GWT_AUTO_OPEN:-true}"
  export GWT_WORKTREE_PATH="${GWT_WORKTREE_PATH:-}"

  # Load config file if it exists
  if [[ -f "$config_file" ]]; then
    while IFS='=' read -r key value; do
      # Skip empty lines and comments
      [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue

      # Trim whitespace
      key="${key##[[:space:]]}"
      key="${key%%[[:space:]]}"
      value="${value##[[:space:]]}"
      value="${value%%[[:space:]]}"

      # Skip if no value
      [[ -z "$value" ]] && continue

      # Set configuration based on key
      case "$key" in
        EDITOR) GWT_EDITOR="$value" ;;
        COPY_FILES) GWT_COPY_FILES="$value" ;;
        COPY_DIRS) GWT_COPY_DIRS="$value" ;;
        AUTO_OPEN) GWT_AUTO_OPEN="$value" ;;
        WORKTREE_PATH) GWT_WORKTREE_PATH="$value" ;;
        *) print -r -- "Warning: Unknown config key '$key' in $config_file" >&2 ;;
      esac
    done < "$config_file"
  fi

  # Validate AUTO_OPEN
  if [[ ! "$GWT_AUTO_OPEN" =~ ^(true|false|yes|no|1|0)$ ]]; then
    print -r -- "Warning: Invalid AUTO_OPEN value '$GWT_AUTO_OPEN'. Using 'true'" >&2
    GWT_AUTO_OPEN="true"
  fi

  # Normalize AUTO_OPEN to true/false
  case "$GWT_AUTO_OPEN" in
    yes|1) GWT_AUTO_OPEN="true" ;;
    no|0) GWT_AUTO_OPEN="false" ;;
  esac

  # Validate WORKTREE_PATH pattern (basic check for unsafe characters)
  if [[ -n "$GWT_WORKTREE_PATH" ]]; then
    if [[ "$GWT_WORKTREE_PATH" == *";"* ]] || \
       [[ "$GWT_WORKTREE_PATH" == *"&"* ]] || \
       [[ "$GWT_WORKTREE_PATH" == *'$('* ]] || \
       [[ "$GWT_WORKTREE_PATH" == *'`'* ]] || \
       [[ "$GWT_WORKTREE_PATH" == *'<'* ]] || \
       [[ "$GWT_WORKTREE_PATH" == *'>'* ]]; then
      print -r -- "Error: WORKTREE_PATH contains unsafe characters" >&2
      print -r -- "Falling back to default pattern" >&2
      GWT_WORKTREE_PATH=""
    fi
  fi

  return 0
}

# ============================================================================
# CREATE WORKTREE (cwt)
# ============================================================================

cwt() {
  # Localize zsh behavior for safety
  emulate -L zsh
  setopt local_options local_traps
  setopt err_return pipe_fail no_unset

  # --- Helper Functions ---

  # Show usage information
  local _show_usage() {
    cat <<'EOF'
Usage: cwt [OPTIONS] <feature-name>

Create a new git worktree with a new or existing branch.

OPTIONS:
    -e, --existing      Checkout existing branch instead of creating new one
    -n, --no-open       Skip opening the worktree in editor
    -h, --help          Show this help message

ENVIRONMENT VARIABLES:
    GWT_EDITOR          Editor to open worktree in (default: cursor)

EXAMPLES:
    cwt feature-123                 # Create new branch and worktree
    cwt -e main                     # Checkout existing 'main' branch
    cwt -e origin/feature-456       # Checkout remote branch
    cwt -n hotfix                   # Create worktree without opening editor
EOF
  }

  # Validate feature/branch name
  local _validate_name() {
    local name="$1"

    # Check for empty name
    if [[ -z "$name" ]]; then
      print -r -- "Error: Feature name cannot be empty."
      return 1
    fi

    # Check for spaces
    if [[ "$name" =~ [[:space:]] ]]; then
      print -r -- "Error: Feature name cannot contain spaces."
      return 1
    fi

    # Check for invalid git ref characters and shell metacharacters
    if [[ "$name" =~ [\~\^:\?\*\[\$\|\&] ]] || \
       [[ "$name" =~ '@{' ]] || \
       [[ "$name" =~ [.][.] ]] || \
       [[ "$name" =~ '//' ]] || \
       [[ "$name" == *\\* ]] || \
       [[ "$name" == *'`'* ]] || \
       [[ "$name" == *'<'* ]] || \
       [[ "$name" == *'>'* ]] || \
       [[ "$name" == *';'* ]]; then
      print -r -- "Error: Feature name contains invalid characters for git branch names."
      print -r -- "Avoid: \\ ~ ^ : ? * [ @{ .. // \$ | & ; < > \`"
      return 1
    fi

    # Cannot start with . or end with .lock
    if [[ "$name" == .* ]] || [[ "$name" == *.lock ]]; then
      print -r -- "Error: Feature name cannot start with '.' or end with '.lock'."
      return 1
    fi

    # Cannot end with . or /
    if [[ "$name" == *. ]] || [[ "$name" == */ ]]; then
      print -r -- "Error: Feature name cannot end with '.' or '/'."
      return 1
    fi

    return 0
  }

  # Check if editor is available
  local _check_editor() {
    local editor="$1"

    if ! command -v "$editor" >/dev/null 2>&1; then
      print -r -- "Warning: Editor '$editor' not found in PATH."
      print -r -- "Skipping editor launch."
      return 1
    fi

    return 0
  }

  # Cleanup function for partial failures
  local cleanup_worktree_path=""
  local cleanup_branch_name=""
  local cleanup_needed=0

  local _cleanup() {
    if [[ $cleanup_needed -eq 1 ]] && [[ -n "$cleanup_worktree_path" ]]; then
      print -r -- ""
      print -r -- "Cleaning up partial worktree creation..."

      # Remove worktree if it exists
      if [[ -d "$cleanup_worktree_path" ]]; then
        git worktree remove "$cleanup_worktree_path" --force 2>/dev/null || {
          rm -rf "$cleanup_worktree_path" 2>/dev/null || true
        }
        print -r -- "Removed worktree: $cleanup_worktree_path"
      fi

      # Remove branch if it was created
      if [[ -n "$cleanup_branch_name" ]]; then
        git branch -D "$cleanup_branch_name" 2>/dev/null && \
          print -r -- "Removed branch: $cleanup_branch_name" || true
      fi
    fi
  }

  trap _cleanup INT TERM EXIT

  # --- Load Configuration ---

  _load_gwt_config || true

  # --- Argument Parsing ---

  local flag_existing=0
  local flag_no_open=0
  local feature_name=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        _show_usage
        trap - INT TERM EXIT
        return 0
        ;;
      -e|--existing)
        flag_existing=1
        shift
        ;;
      -n|--no-open)
        flag_no_open=1
        shift
        ;;
      -*)
        print -r -- "Error: Unknown option: $1"
        print -r -- ""
        _show_usage
        trap - INT TERM EXIT
        return 1
        ;;
      *)
        if [[ -z "$feature_name" ]]; then
          feature_name="$1"
          shift
        else
          print -r -- "Error: Too many arguments."
          print -r -- ""
          _show_usage
          trap - INT TERM EXIT
          return 1
        fi
        ;;
    esac
  done

  # --- Validation ---

  # Check if feature name was provided
  if [[ -z "$feature_name" ]]; then
    print -r -- "Error: Feature name is required."
    print -r -- ""
    _show_usage
    trap - INT TERM EXIT
    return 1
  fi

  # Validate we're in a git repo
  local project_dir
  if ! project_dir=$(git rev-parse --show-toplevel 2>/dev/null); then
    print -r -- "Error: Not inside a git repository."
    trap - INT TERM EXIT
    return 1
  fi

  # Validate feature name
  if ! _validate_name "$feature_name"; then
    trap - INT TERM EXIT
    return 1
  fi

  # Get project name
  local project_name=$(basename "$project_dir")

  # Define paths
  local worktree_parent="$(dirname "$project_dir")/${project_name}-worktrees"
  local worktree_path="${worktree_parent}/${feature_name}"

  # Check if worktree already exists
  if [[ -d "$worktree_path" ]]; then
    print -r -- "Error: Worktree already exists at: $worktree_path"
    trap - INT TERM EXIT
    return 1
  fi

  # Check if worktree is already registered with git
  if git -C "$project_dir" worktree list | grep -q "$worktree_path"; then
    print -r -- "Error: Worktree path already registered with git: $worktree_path"
    trap - INT TERM EXIT
    return 1
  fi

  # --- Branch Handling ---

  local branch_ref="$feature_name"
  local branch_name="$feature_name"
  local create_branch=1

  if [[ $flag_existing -eq 1 ]]; then
    # User wants to checkout existing branch
    create_branch=0

    # Check if it's a remote branch
    if [[ "$feature_name" == origin/* ]] || [[ "$feature_name" == */* ]]; then
      # Remote branch reference
      if ! git -C "$project_dir" show-ref --verify "refs/remotes/$feature_name" >/dev/null 2>&1; then
        print -r -- "Error: Remote branch '$feature_name' does not exist."
        print -r -- "Try: git fetch origin"
        trap - INT TERM EXIT
        return 1
      fi
      branch_ref="$feature_name"
      branch_name="${feature_name#origin/}"
      branch_name="${branch_name##*/}"
    else
      # Local branch
      if ! git -C "$project_dir" show-ref --verify "refs/heads/$feature_name" >/dev/null 2>&1; then
        print -r -- "Error: Local branch '$feature_name' does not exist."
        print -r -- "Use 'cwt $feature_name' without -e flag to create a new branch."
        trap - INT TERM EXIT
        return 1
      fi
    fi
  else
    # Creating new branch - check if it already exists
    if git -C "$project_dir" show-ref --verify "refs/heads/$feature_name" >/dev/null 2>&1; then
      print -r -- "Error: Branch '$feature_name' already exists."
      print -r -- "Use 'cwt -e $feature_name' to checkout the existing branch."
      trap - INT TERM EXIT
      return 1
    fi

    # Check if remote branch exists
    if git -C "$project_dir" show-ref --verify "refs/remotes/origin/$feature_name" >/dev/null 2>&1; then
      print -r -- "Error: Remote branch 'origin/$feature_name' already exists."
      print -r -- "Use 'cwt -e origin/$feature_name' to checkout the remote branch."
      trap - INT TERM EXIT
      return 1
    fi
  fi

  # --- Create Worktree ---

  # Create parent directory
  if ! mkdir -p "$worktree_parent"; then
    print -r -- "Error: Failed to create worktree parent directory: $worktree_parent"
    trap - INT TERM EXIT
    return 1
  fi

  # Enable cleanup in case of failure
  cleanup_worktree_path="$worktree_path"
  if [[ $create_branch -eq 1 ]]; then
    cleanup_branch_name="$feature_name"
  fi
  cleanup_needed=1

  # Create the worktree
  if [[ $create_branch -eq 1 ]]; then
    if ! git -C "$project_dir" worktree add -b "$feature_name" "$worktree_path"; then
      print -r -- "Error: Failed to create worktree with new branch."
      return 1
    fi
    print -r -- "Created new branch: $feature_name"
  else
    if ! git -C "$project_dir" worktree add "$worktree_path" "$branch_ref"; then
      print -r -- "Error: Failed to create worktree for existing branch."
      return 1
    fi
    print -r -- "Checked out existing branch: $branch_name"
  fi

  # --- Copy Configuration Files ---

  # Copy files from config
  IFS=',' read -rA files_to_copy <<< "$GWT_COPY_FILES"
  for file in "${files_to_copy[@]}"; do
    file="${file##[[:space:]]}"
    file="${file%%[[:space:]]}"
    if [[ -f "$project_dir/$file" ]]; then
      if cp "$project_dir/$file" "$worktree_path/$file" 2>/dev/null; then
        print -r -- "Copied $file into worktree."
      else
        print -r -- "Warning: Failed to copy $file file."
      fi
    fi
  done

  # Copy directories from config
  IFS=',' read -rA dirs_to_copy <<< "$GWT_COPY_DIRS"
  for dir in "${dirs_to_copy[@]}"; do
    dir="${dir##[[:space:]]}"
    dir="${dir%%[[:space:]]}"
    if [[ -d "$project_dir/$dir" ]]; then
      if cp -R "$project_dir/$dir" "$worktree_path/$dir" 2>/dev/null; then
        print -r -- "Copied $dir into worktree."
      else
        print -r -- "Warning: Failed to copy $dir directory."
      fi
    fi
  done

  # --- Open in Editor ---

  if [[ $flag_no_open -eq 0 ]] && [[ "$GWT_AUTO_OPEN" == "true" ]]; then
    # Determine editor
    local editor="$GWT_EDITOR"

    if _check_editor "$editor"; then
      "$editor" "$worktree_path" &
      print -r -- "Opening in $editor..."
    fi
  fi

  # Success - disable cleanup
  cleanup_needed=0
  trap - INT TERM EXIT

  print -r -- "Created worktree at: $worktree_path"
}

# ============================================================================
# DELETE WORKTREE (dwt)
# ============================================================================

dwt() {
  emulate -L zsh
  setopt local_options
  setopt local_traps
  setopt err_return pipe_fail no_unset

  # Parse flags
  local force_mode=0
  local show_help=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force)
        force_mode=1
        shift
        ;;
      -h|--help)
        show_help=1
        shift
        ;;
      *)
        print -r -- "Error: Unknown option: $1"
        print -r -- "Use -h or --help for usage information."
        return 1
        ;;
    esac
  done

  # Show help if requested
  if [[ $show_help -eq 1 ]]; then
    print -r -- "Usage: dwt [OPTIONS]"
    print -r -- ""
    print -r -- "Delete the current git worktree and optionally its associated branch."
    print -r -- ""
    print -r -- "Options:"
    print -r -- "  -f, --force    Skip all confirmations (for scripting)"
    print -r -- "  -h, --help     Show this help message"
    print -r -- ""
    print -r -- "This command must be run from within a git worktree directory."
    return 0
  fi

  # must be inside a worktree
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null || true)
  if [[ -z "$git_dir" || "$git_dir" != *.git/worktrees/* ]]; then
    print -r -- "You don't appear to be in a git worktree."
    print -r -- "Run this from within a worktree directory."
    return 1
  fi

  local worktree_path git_common_dir main_repo worktree_name branch_name lock
  worktree_path=$(git rev-parse --show-toplevel)
  git_common_dir=$(git rev-parse --git-common-dir)
  main_repo=$(dirname "$git_common_dir")
  worktree_name=$(basename "$worktree_path")
  branch_name=$(git branch --show-current 2>/dev/null || true)
  lock="$main_repo/.git/index.lock"

  # Check for uncommitted changes
  local has_uncommitted=0
  local uncommitted_msg=""
  local files_count=0

  if [[ -d "$worktree_path" ]]; then
    files_count=$(find "$worktree_path" -type f 2>/dev/null | wc -l | tr -d ' ')
  fi

  if git -C "$worktree_path" diff-index --quiet HEAD -- 2>/dev/null; then
    :  # no uncommitted changes
  else
    has_uncommitted=1
    local modified_count=$(git -C "$worktree_path" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
    local staged_count=$(git -C "$worktree_path" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
    local untracked_count=$(git -C "$worktree_path" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')

    uncommitted_msg="UNCOMMITTED CHANGES DETECTED:"
    [[ $modified_count -gt 0 ]] && uncommitted_msg="$uncommitted_msg\n   Modified files: $modified_count"
    [[ $staged_count -gt 0 ]] && uncommitted_msg="$uncommitted_msg\n   Staged files: $staged_count"
    [[ $untracked_count -gt 0 ]] && uncommitted_msg="$uncommitted_msg\n   Untracked files: $untracked_count"
  fi

  # Display summary
  print -r -- "Worktree: $worktree_name"
  print -r -- "Path:     $worktree_path"
  print -r -- "Main repo: $main_repo"

  if [[ -n "$branch_name" ]]; then
    print -r -- "Branch:   $branch_name"
  else
    print -r -- "State:    Detached HEAD (no branch)"
  fi

  print -r -- "Files:    $files_count"

  if [[ $has_uncommitted -eq 1 ]]; then
    print -r -- ""
    print -r -- "$uncommitted_msg"
  fi

  print -r -- ""

  # Confirmation (skip if force mode)
  if [[ $force_mode -eq 0 ]]; then
    local confirmation
    read -r "?Delete this worktree? [y/N]: " confirmation
    [[ "$confirmation" =~ ^[Yy]$ ]] || { print -r -- "Cancelled."; return 0; }
  fi

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

  # preflight: clear stale lock (don't touch if in use)
  if [[ -e "$lock" ]]; then
    if command -v lsof >/dev/null 2>&1 && lsof "$lock" >/dev/null 2>&1; then
      print -r -- "Git index in use at $lock. Close editors/terminals and retry."
      return 1
    else
      print -r -- "Removing stale index.lock"
      rm -f -- "$lock"
    fi
  fi

  # Do operations without changing the caller's directory
  if ! git -C "$main_repo" worktree remove "$worktree_path" --force; then
    print -r -- "Failed to remove worktree."
    return 1
  fi
  print -r -- "Removed worktree: $worktree_path"

  git -C "$main_repo" worktree prune >/dev/null 2>&1 || true

  if [[ -n "$branch_name" ]]; then
    local bc
    if [[ $force_mode -eq 1 ]]; then
      bc="y"
    else
      read -r "?Delete branch '$branch_name' too? [y/N]: " bc
    fi

    if [[ "$bc" =~ ^[Yy]$ ]]; then
      # don't delete if checked out elsewhere
      if git -C "$main_repo" worktree list | awk '{print $3}' | grep -qx "$branch_name"; then
        print -r -- "Branch '$branch_name' is checked out in another worktree. Not deleting."
      else
        git -C "$main_repo" branch -D "$branch_name" || {
          print -r -- "Could not delete branch '$branch_name'."
        }
        print -r -- "Deleted branch: $branch_name"
      fi
    else
      print -r -- "Kept branch: $branch_name"
    fi
  else
    print -r -- "Detached HEAD - no branch associated with this worktree."
  fi

  # Post-op: if a lock shows up, surface info without deleting
  if [[ -e "$lock" ]]; then
    print -r -- "index.lock exists after dwt: $lock"
    command -v lsof >/dev/null 2>&1 && lsof "$lock" || true
    print -r -- "   If no holder is listed, it's stale; remove with: rm '$lock'"
  fi

  print -r -- "Done."
}

# ============================================================================
# LIST WORKTREES (lwt)
# ============================================================================

lwt() {
  emulate -L zsh
  setopt local_options
  setopt err_return pipe_fail no_unset

  # Handle help flag
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print -r -- "Usage: lwt"
    print -r -- ""
    print -r -- "List all git worktrees with detailed information:"
    print -r -- "  - Worktree path"
    print -r -- "  - Branch name"
    print -r -- "  - Git status (clean/dirty)"
    print -r -- "  - Last commit info"
    print -r -- ""
    print -r -- "The current worktree is highlighted with [CURRENT]"
    return 0
  fi

  # Check if we're in a git repository
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    print -r -- "Not in a git repository."
    return 1
  fi

  local current_path git_common_dir worktrees_output
  current_path=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)

  # Get worktree list
  worktrees_output=$(git worktree list --porcelain 2>/dev/null)

  if [[ -z "$worktrees_output" ]]; then
    print -r -- "No worktrees found."
    return 0
  fi

  # Header
  print -r -- ""
  print -r -- "=========================================================================="
  print -r -- "  GIT WORKTREES"
  print -r -- "=========================================================================="
  print -r -- ""

  # Parse worktree list
  local worktree_path="" branch="" head="" is_current=0
  while IFS= read -r line; do
    if [[ "$line" == worktree\ * ]]; then
      # New worktree entry - process previous one if exists
      if [[ -n "$worktree_path" ]]; then
        _lwt_display_worktree "$worktree_path" "$branch" "$head" "$is_current"
      fi

      # Start new entry
      worktree_path="${line#worktree }"
      branch=""
      head=""
      is_current=0
      [[ "$worktree_path" == "$current_path" ]] && is_current=1

    elif [[ "$line" == branch\ * ]]; then
      branch="${line#branch refs/heads/}"
    elif [[ "$line" == HEAD\ * ]]; then
      head="${line#HEAD }"
    elif [[ "$line" == detached ]]; then
      branch="(detached)"
    fi
  done <<< "$worktrees_output"

  # Display last worktree
  if [[ -n "$worktree_path" ]]; then
    _lwt_display_worktree "$worktree_path" "$branch" "$head" "$is_current"
  fi

  print -r -- ""
  print -r -- "=========================================================================="
  print -r -- ""
}

_lwt_display_worktree() {
  local wt_path="$1" wt_branch="$2" wt_head="$3" is_current="$4"
  local marker status_icon status_text commit_msg commit_author commit_date

  # Marker for current worktree
  marker="  "
  [[ "$is_current" == "1" ]] && marker="[CURRENT] "

  # Get git status
  local status_output
  status_output=$(git -C "$wt_path" status --porcelain 2>/dev/null || echo "")

  if [[ -z "$status_output" ]]; then
    status_icon="[CLEAN]"
    status_text="clean"
  else
    status_icon="[DIRTY]"
    status_text="dirty"
  fi

  # Get last commit info
  if [[ -n "$wt_head" ]]; then
    commit_msg=$(git -C "$wt_path" log -1 --format="%s" 2>/dev/null || echo "No commits")
    commit_author=$(git -C "$wt_path" log -1 --format="%an" 2>/dev/null || echo "Unknown")
    commit_date=$(git -C "$wt_path" log -1 --format="%ar" 2>/dev/null || echo "Unknown")
  else
    commit_msg="No commits yet"
    commit_author="Unknown"
    commit_date="Unknown"
  fi

  # Branch display
  local branch_display
  if [[ -z "$wt_branch" ]]; then
    if [[ -n "$wt_head" ]]; then
      branch_display="(detached @ ${wt_head:0:7})"
    else
      branch_display="(no branch)"
    fi
  else
    branch_display="$wt_branch"
  fi

  # Display worktree info
  print -r -- "${marker}$(basename "$wt_path")"
  print -r -- "   Path:   $wt_path"
  print -r -- "   Branch: $branch_display"
  print -r -- "   Status: $status_icon $status_text"
  print -r -- "   Commit: $commit_msg"
  print -r -- "           by $commit_author, $commit_date"
  print -r -- ""
}

# ============================================================================
# SWITCH WORKTREE (swt)
# ============================================================================

swt() {
  emulate -L zsh
  setopt local_options
  setopt local_traps
  setopt err_return pipe_fail no_unset

  # Parse flags
  local print_only=0
  local show_help=0
  local direct_arg=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--print)
        print_only=1
        shift
        ;;
      -h|--help)
        show_help=1
        shift
        ;;
      -*)
        print -r -- "Unknown option: $1"
        return 1
        ;;
      *)
        direct_arg="$1"
        shift
        ;;
    esac
  done

  # Show help
  if [[ $show_help -eq 1 ]]; then
    cat <<'EOF'
swt - Switch Git Worktree

USAGE:
  swt [OPTIONS] [worktree-name]

OPTIONS:
  -p, --print    Print the worktree path instead of opening editor
  -h, --help     Show this help message

EXAMPLES:
  swt                    # Interactive selection with fzf (or numbered menu)
  swt feature-name       # Switch directly to worktree matching 'feature-name'
  swt -p                 # Print path for use with: cd $(swt -p)

ENVIRONMENT:
  GWT_EDITOR            Editor command (default: cursor)
EOF
    return 0
  fi

  # Load config
  _load_gwt_config || true

  # Must be inside a git repo
  local main_repo
  if ! main_repo=$(git rev-parse --show-toplevel 2>/dev/null); then
    print -r -- "Not inside a git repository."
    return 1
  fi

  # Get common git dir to handle both main repo and worktrees
  local git_common_dir
  git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
  if [[ "$git_common_dir" == *.git/worktrees/* ]]; then
    main_repo=$(dirname "$git_common_dir")
  fi

  # Get list of worktrees
  local worktree_list
  worktree_list=$(git -C "$main_repo" worktree list --porcelain 2>/dev/null)

  if [[ -z "$worktree_list" ]]; then
    print -r -- "No worktrees found."
    return 1
  fi

  # Parse worktrees into arrays
  local -a worktree_paths
  local -a worktree_branches
  local -a worktree_info
  local current_path current_branch current_info

  while IFS= read -r line; do
    if [[ "$line" == worktree\ * ]]; then
      current_path="${line#worktree }"
    elif [[ "$line" == branch\ * ]]; then
      current_branch="${line#branch refs/heads/}"
    elif [[ "$line" == HEAD\ * ]]; then
      current_branch="(detached)"
    elif [[ -z "$line" && -n "$current_path" ]]; then
      # End of worktree entry
      local wt_name=$(basename "$current_path")
      local status_icon=""

      # Check if it's the current worktree
      if [[ "$current_path" == "$main_repo" || "$current_path" == "$(git rev-parse --show-toplevel 2>/dev/null)" ]]; then
        status_icon=" (current)"
      fi

      worktree_paths+=("$current_path")
      worktree_branches+=("${current_branch:-main}")
      worktree_info+=("$wt_name [$current_branch]$status_icon")

      current_path=""
      current_branch=""
    fi
  done <<<"$worktree_list"

  # Handle last entry if file doesn't end with blank line
  if [[ -n "$current_path" ]]; then
    local wt_name=$(basename "$current_path")
    local status_icon=""
    if [[ "$current_path" == "$main_repo" || "$current_path" == "$(git rev-parse --show-toplevel 2>/dev/null)" ]]; then
      status_icon=" (current)"
    fi
    worktree_paths+=("$current_path")
    worktree_branches+=("${current_branch:-main}")
    worktree_info+=("$wt_name [$current_branch]$status_icon")
  fi

  if [[ ${#worktree_paths[@]} -eq 0 ]]; then
    print -r -- "No worktrees found."
    return 1
  fi

  local selected_path=""

  # Direct argument provided
  if [[ -n "$direct_arg" ]]; then
    local matched=0
    local i
    for i in {1..${#worktree_paths[@]}}; do
      local wt_name=$(basename "${worktree_paths[$i]}")
      if [[ "$wt_name" == *"$direct_arg"* || "${worktree_branches[$i]}" == *"$direct_arg"* ]]; then
        selected_path="${worktree_paths[$i]}"
        matched=1
        break
      fi
    done

    if [[ $matched -eq 0 ]]; then
      print -r -- "No worktree matching '$direct_arg' found."
      return 1
    fi
  else
    # Interactive selection
    if command -v fzf >/dev/null 2>&1; then
      # Use fzf for selection
      local selected_info
      selected_info=$(printf '%s\n' "${worktree_info[@]}" | fzf --height=40% --border --prompt="Select worktree: " --preview="echo {}" --preview-window=hidden)

      if [[ -z "$selected_info" ]]; then
        print -r -- "No worktree selected."
        return 1
      fi

      # Find matching path
      local i
      for i in {1..${#worktree_info[@]}}; do
        if [[ "${worktree_info[$i]}" == "$selected_info" ]]; then
          selected_path="${worktree_paths[$i]}"
          break
        fi
      done
    else
      # Fallback to numbered selection
      print -r -- "Available worktrees:"
      print -r -- ""
      local i
      for i in {1..${#worktree_info[@]}}; do
        print -r -- "  $i) ${worktree_info[$i]}"
      done
      print -r -- ""

      local selection
      read -r "selection?Select worktree (1-${#worktree_info[@]}): "

      if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt ${#worktree_info[@]} ]]; then
        print -r -- "Invalid selection."
        return 1
      fi

      selected_path="${worktree_paths[$selection]}"
    fi
  fi

  if [[ -z "$selected_path" ]]; then
    print -r -- "Failed to select worktree."
    return 1
  fi

  # Print mode
  if [[ $print_only -eq 1 ]]; then
    print -r -- "$selected_path"
    return 0
  fi

  # Open in editor
  local editor="$GWT_EDITOR"

  if ! command -v "$editor" >/dev/null 2>&1; then
    print -r -- "Editor '$editor' not found. Path: $selected_path"
    return 1
  fi

  "$editor" "$selected_path" &
  print -r -- "Opening $(basename "$selected_path") in $editor..."
}

# ============================================================================
# UPDATE WORKTREES (uwt)
# ============================================================================

uwt() {
  emulate -L zsh
  setopt local_options
  setopt local_traps
  setopt err_return pipe_fail no_unset

  # Parse flags
  local force=0
  local all=0
  local show_help=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force)
        force=1
        shift
        ;;
      -a|--all)
        all=1
        shift
        ;;
      -h|--help)
        show_help=1
        shift
        ;;
      *)
        print -r -- "Unknown option: $1"
        print -r -- "Use -h or --help for usage information."
        return 1
        ;;
    esac
  done

  # Show help
  if [[ $show_help -eq 1 ]]; then
    print -r -- "Usage: uwt [OPTIONS]"
    print -r -- ""
    print -r -- "Update/pull git worktrees with remote tracking status."
    print -r -- ""
    print -r -- "Options:"
    print -r -- "  -a, --all     Update all worktrees without prompting"
    print -r -- "  -f, --force   Update worktrees even with uncommitted changes"
    print -r -- "  -h, --help    Show this help message"
    print -r -- ""
    print -r -- "Examples:"
    print -r -- "  uwt           # Interactive mode - choose which worktrees to update"
    print -r -- "  uwt -a        # Update all worktrees automatically"
    print -r -- "  uwt -a -f     # Update all worktrees, even with uncommitted changes"
    return 0
  fi

  # Must be inside a git repo
  local main_repo
  if ! main_repo=$(git rev-parse --show-toplevel 2>/dev/null); then
    print -r -- "Not inside a git repository."
    return 1
  fi

  print -r -- "Fetching latest from remote..."
  git -C "$main_repo" fetch --all --prune 2>/dev/null || {
    print -r -- "Failed to fetch from remote. Continuing with local data..."
  }
  print -r -- ""

  # Get list of all worktrees
  local -a worktree_list
  local -a worktree_paths
  local -a worktree_branches
  local -a worktree_status
  local -a worktree_dirty

  while IFS= read -r line; do
    local wt_path=$(print -r -- "$line" | awk '{print $1}')
    local wt_branch=$(print -r -- "$line" | awk -F'[][]' '{print $2}')

    worktree_paths+=("$wt_path")
    worktree_branches+=("$wt_branch")

    # Check for uncommitted changes
    local dirty=0
    if ! git -C "$wt_path" diff --quiet 2>/dev/null || \
       ! git -C "$wt_path" diff --cached --quiet 2>/dev/null || \
       [[ -n $(git -C "$wt_path" ls-files --others --exclude-standard 2>/dev/null) ]]; then
      dirty=1
    fi
    worktree_dirty+=($dirty)

    # Check tracking status
    local status="no-remote"
    local upstream
    if upstream=$(git -C "$wt_path" rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null); then
      local local_commit=$(git -C "$wt_path" rev-parse @ 2>/dev/null)
      local remote_commit=$(git -C "$wt_path" rev-parse @{u} 2>/dev/null)
      local base_commit=$(git -C "$wt_path" merge-base @ @{u} 2>/dev/null)

      if [[ "$local_commit" == "$remote_commit" ]]; then
        status="up-to-date"
      elif [[ "$local_commit" == "$base_commit" ]]; then
        status="behind"
      elif [[ "$remote_commit" == "$base_commit" ]]; then
        status="ahead"
      else
        status="diverged"
      fi
    fi
    worktree_status+=("$status")

  done < <(git -C "$main_repo" worktree list --porcelain | awk '/^worktree /{path=$2} /^branch /{branch=$2; print path, branch}')

  # Display worktree status
  print -r -- "Worktree Status:"
  print -r -- "================================================================="

  local -a updateable
  local idx=1
  for i in {1..$#worktree_paths}; do
    local path="${worktree_paths[$i]}"
    local branch="${worktree_branches[$i]}"
    local status="${worktree_status[$i]}"
    local dirty=${worktree_dirty[$i]}
    local name=$(basename "$path")

    # Status symbol
    local status_symbol
    case "$status" in
      up-to-date) status_symbol="[OK]" ;;
      behind)     status_symbol="[BEHIND]" ;;
      ahead)      status_symbol="[AHEAD]" ;;
      diverged)   status_symbol="[DIVERGED]" ;;
      no-remote)  status_symbol="[NO-REMOTE]" ;;
    esac

    # Dirty indicator
    local dirty_indicator=""
    if [[ $dirty -eq 1 ]]; then
      dirty_indicator=" [DIRTY]"
    fi

    print -r -- "${idx}. ${status_symbol} ${name} [${branch}] - ${status}${dirty_indicator}"

    # Add to updateable list if behind and (clean or force)
    if [[ "$status" == "behind" && ($dirty -eq 0 || $force -eq 1) ]]; then
      updateable+=($i)
    fi

    ((idx++))
  done
  print -r -- "================================================================="
  print -r -- ""

  # Check if there's anything to update
  if [[ ${#updateable[@]} -eq 0 ]]; then
    print -r -- "No worktrees need updating."
    return 0
  fi

  # Determine which worktrees to update
  local -a to_update
  if [[ $all -eq 1 ]]; then
    to_update=("${updateable[@]}")
    print -r -- "Updating ${#to_update[@]} worktree(s)..."
  else
    print -r -- "${#updateable[@]} worktree(s) can be updated."
    local confirmation
    read -r "?Update all updateable worktrees? [y/N]: " confirmation
    if [[ "$confirmation" =~ ^[Yy]$ ]]; then
      to_update=("${updateable[@]}")
    else
      print -r -- "Update cancelled."
      return 0
    fi
  fi

  # Update worktrees
  print -r -- ""
  local -a updated
  local -a failed
  local -a skipped

  for i in "${to_update[@]}"; do
    local path="${worktree_paths[$i]}"
    local branch="${worktree_branches[$i]}"
    local name=$(basename "$path")
    local dirty=${worktree_dirty[$i]}

    if [[ $dirty -eq 1 && $force -eq 0 ]]; then
      print -r -- "Skipping $name (uncommitted changes)"
      skipped+=("$name")
      continue
    fi

    print -r -- "Pulling $name..."
    if git -C "$path" pull --ff-only 2>/dev/null; then
      updated+=("$name")
      print -r -- "   Updated $name"
    else
      failed+=("$name")
      print -r -- "   Failed to update $name"
    fi
  done

  # Summary
  print -r -- ""
  print -r -- "================================================================="
  print -r -- "Update Summary:"
  print -r -- "   Updated: ${#updated[@]}"
  if [[ ${#updated[@]} -gt 0 ]]; then
    for name in "${updated[@]}"; do
      print -r -- "      - $name"
    done
  fi

  if [[ ${#failed[@]} -gt 0 ]]; then
    print -r -- "   Failed: ${#failed[@]}"
    for name in "${failed[@]}"; do
      print -r -- "      - $name"
    done
  fi

  if [[ ${#skipped[@]} -gt 0 ]]; then
    print -r -- "   Skipped: ${#skipped[@]}"
    for name in "${skipped[@]}"; do
      print -r -- "      - $name"
    done
  fi
  print -r -- "================================================================="

  if [[ ${#failed[@]} -gt 0 ]]; then
    return 1
  fi

  print -r -- "Done."
}

# ============================================================================
# HELP SYSTEM
# ============================================================================

_gwt_help() {
  cat << 'EOF'
======================================================================
                   Git Worktree Helper Commands
======================================================================

Available Commands:

  cwt  - Create a new git worktree with a new branch
  dwt  - Delete a git worktree (and optionally its branch)
  lwt  - List all git worktrees
  swt  - Switch between git worktrees
  uwt  - Update all git worktrees

Usage:
  Run any command with -h or --help for detailed help

Examples:
  cwt feature-login          # Create worktree for feature-login branch
  dwt                        # Delete current worktree (interactive)
  lwt                        # List all worktrees
  swt                        # Switch worktrees (interactive)
  uwt -a                     # Update all worktrees

Configuration:
  Create .git-worktree-config in your repo root to customize behavior
  See .git-worktree-config.example for template

EOF
}
