#!/usr/bin/env bash
# enforce-cors-no-lambda.sh — Block CORS headers in Lambda code
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

# Only check Python files
case "$FILE_PATH" in
  *.py) ;;
  *) exit 0 ;;
esac

# Exclude files that are allowed to reference CORS
case "$FILE_PATH" in
  */tests/* | */test_* | *_test.py | */conftest.py)
    # Test files can reference CORS for assertions
    exit 0
    ;;
  *.tf | *.tfvars)
    # Terraform files — CORS belongs here
    exit 0
    ;;
  */0_utilities/*)
    # The hooks repo itself — exempt
    exit 0
    ;;
esac

# Get the content being written/edited
if [[ "$TOOL_NAME" == "Write" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
elif [[ "$TOOL_NAME" == "Edit" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
else
  exit 0
fi

if [[ -z "$CONTENT" ]]; then
  exit 0
fi

# Check for CORS header strings in the content
CORS_PATTERNS=(
  "Access-Control-Allow-Origin"
  "Access-Control-Allow-Methods"
  "Access-Control-Allow-Headers"
  "Access-Control-Allow-Credentials"
  "Access-Control-Max-Age"
  "Access-Control-Expose-Headers"
)

for pattern in "${CORS_PATTERNS[@]}"; do
  if echo "$CONTENT" | grep -qF "$pattern"; then
    echo "BLOCKED: CORS headers must NOT be set in Lambda code."
    echo ""
    echo "  File: $FILE_PATH"
    echo "  Found: $pattern"
    echo ""
    echo "CORS must be configured in Terraform API Gateway only (single source of truth)."
    echo "  - REST API v1: Use the modules/cors/ Terraform module for OPTIONS + Lambda env var"
    echo "  - HTTP API v2: Use cors_configuration block in API Gateway Terraform"
    echo ""
    echo "Setting CORS in both Lambda and API Gateway causes drift and breakage."
    echo ""
    echo "Rule: CORS Single Source of Truth (CLAUDE.md Phase 2)"
    exit 2
  fi
done

exit 0
