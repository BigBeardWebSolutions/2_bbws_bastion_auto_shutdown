#!/usr/bin/env bash
# enforce-proxy.sh — Block direct API calls in test files
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

# Only check test files
case "$FILE_PATH" in
  */tests/*.py | */test_*.py | *_test.py)
    ;;
  *)
    exit 0
    ;;
esac

# Exclude the hooks repo itself
case "$FILE_PATH" in
  */0_utilities/*)
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

# Check if the file uses mocking (moto, mock_aws, etc.) — if so, allow direct URLs
# because these are unit tests with mocked AWS services
if echo "$CONTENT" | grep -qE '@mock_aws|@mock_s3|@mock_dynamodb|mock_aws|from moto|import moto|@patch|@mock\.patch|MagicMock|unittest\.mock'; then
  exit 0
fi

# Also check if the file already has proxy URL patterns — if so, it's using proxy correctly
if echo "$CONTENT" | grep -qE 'PROXY_URL|proxy_url|proxy_base_url|PROXY_BASE|test_proxy'; then
  exit 0
fi

# Block direct AWS API Gateway URLs
BLOCKED_URL_PATTERNS=(
  '\.execute-api\.[a-z0-9-]+\.amazonaws\.com'
  '\.amazonaws\.com/[a-z]+/'
  'https://[a-z0-9]+\.execute-api\.'
)

for pattern in "${BLOCKED_URL_PATTERNS[@]}"; do
  MATCH=$(echo "$CONTENT" | grep -oE "$pattern" | head -1) || true
  if [[ -n "$MATCH" ]]; then
    echo "BLOCKED: Direct API Gateway URL detected in test file."
    echo ""
    echo "  File: $FILE_PATH"
    echo "  Found: $MATCH"
    echo ""
    echo "Agent tests MUST use an API Gateway HTTP Proxy, not direct API URLs."
    echo "Use a proxy URL variable: PROXY_URL, proxy_base_url, etc."
    echo ""
    echo "Each repo should have /tests/proxy/ with Terraform for the proxy setup."
    echo ""
    echo "Rule: Agent Test Proxy Rule (CLAUDE.md)"
    exit 2
  fi
done

# Block direct kimmyai.io URLs in test files (should use proxy)
if echo "$CONTENT" | grep -qE 'https?://[a-z]+\.kimmyai\.io/api/'; then
  MATCH=$(echo "$CONTENT" | grep -oE 'https?://[a-z]+\.kimmyai\.io/api/[^ "'"'"']*' | head -1) || true
  echo "BLOCKED: Direct API URL (kimmyai.io) detected in test file."
  echo ""
  echo "  File: $FILE_PATH"
  echo "  Found: $MATCH"
  echo ""
  echo "Agent tests MUST use an API Gateway HTTP Proxy, not direct service URLs."
  echo ""
  echo "Rule: Agent Test Proxy Rule (CLAUDE.md)"
  exit 2
fi

exit 0
