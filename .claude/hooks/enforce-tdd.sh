#!/usr/bin/env bash
# enforce-tdd.sh — Block implementation code without prior test changes
# Claude Code PreToolUse hook for Write|Edit tool calls
# Exit 2 = block with feedback | Exit 0 = allow
set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

FILENAME=$(basename "$FILE_PATH")

# Only check Python source files in implementation directories
# Allow everything else (tests, Terraform, configs, docs, scripts, etc.)
case "$FILE_PATH" in
  */tests/* | */test_* | *_test.py | */conftest.py)
    # Test files — always allowed
    exit 0
    ;;
  *.tf | *.tfvars | *.hcl)
    # Terraform files — not subject to TDD
    exit 0
    ;;
  *.md | *.txt | *.yml | *.yaml | *.json | *.toml | *.cfg | *.ini | *.env*)
    # Config/docs — not subject to TDD
    exit 0
    ;;
  *.sh)
    # Shell scripts — not subject to TDD
    exit 0
    ;;
  *.html | *.css | *.js | *.jsx | *.ts | *.tsx)
    # Frontend files — not subject to this Python TDD hook
    exit 0
    ;;
  *requirements*.txt | *Pipfile* | *pyproject.toml | *setup.py | *setup.cfg)
    # Dependency files — not subject to TDD
    exit 0
    ;;
  *__init__.py)
    # Package init files — usually not subject to TDD
    exit 0
    ;;
  */.claude/* | */.github/* | */.pre-commit-config.yaml | */.gitignore)
    # Tool/CI config — not subject to TDD
    exit 0
    ;;
  */0_utilities/*)
    # Utilities repo (hooks themselves, scripts, etc.) — exempt
    exit 0
    ;;
esac

# Only enforce on Python source files in implementation directories
case "$FILE_PATH" in
  *.py)
    # This is a Python source file — check if it's in an implementation directory
    case "$FILE_PATH" in
      */src/* | */handlers/* | */services/* | */models/* | */utils/* | */api/* | */lib/* | */core/*)
        # Implementation directory — enforce TDD
        ;;
      *)
        # Python file not in a known implementation directory — allow
        exit 0
        ;;
    esac
    ;;
  *)
    # Not a Python file — allow
    exit 0
    ;;
esac

# At this point we have a Python source file in an implementation directory.
# Check if test files have been modified in the current working tree.
# We look for both staged and unstaged changes to test files.

# Find the git root for this file
FILE_DIR=$(dirname "$FILE_PATH")
GIT_ROOT=$(cd "$FILE_DIR" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || true

if [[ -z "$GIT_ROOT" ]]; then
  # Not in a git repo — can't check, allow
  exit 0
fi

# Check for test file changes (staged + unstaged + untracked)
TEST_CHANGES=$(cd "$GIT_ROOT" && {
  git diff --name-only 2>/dev/null
  git diff --cached --name-only 2>/dev/null
  git ls-files --others --exclude-standard 2>/dev/null
} | grep -E "(test_|_test\.py|/tests/)" | head -5) || true

if [[ -n "$TEST_CHANGES" ]]; then
  # Test files have been modified — TDD is being followed
  exit 0
fi

# No test changes found — block
# Derive the expected test file name
BASENAME="${FILENAME%.py}"
echo "BLOCKED: TDD violation — write failing test first before implementation code."
echo ""
echo "  File: $FILE_PATH"
echo "  Expected: tests/test_${BASENAME}.py (or similar test file)"
echo ""
echo "No test file changes detected in the working tree. TDD requires:"
echo "  1. Write a failing test (red)"
echo "  2. Write minimum implementation to pass (green)"
echo "  3. Refactor"
echo ""
echo "Rule: TBT Law #12 — ALWAYS use TDD (Test-Driven Development)"
exit 2
