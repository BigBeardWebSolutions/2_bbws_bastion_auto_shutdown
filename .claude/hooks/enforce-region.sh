#!/usr/bin/env bash
# enforce-region.sh — Block wrong AWS region for environment
# Claude Code PreToolUse hook for Write|Edit tool calls
# Exit 2 = block with feedback | Exit 0 = allow
#
# Rules:
#   DEV  (account 536580886816) → eu-west-1
#   SIT  (account 815856636111) → eu-west-1
#   PROD (account 093646564004) → af-south-1
#
set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# ── Handle Bash tool (catch CLI with wrong --region) ──
if [[ "$TOOL_NAME" == "Bash" ]]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [[ -z "$COMMAND" ]] && exit 0
  # Skip non-AWS commands
  [[ "$COMMAND" != *"aws "* ]] && exit 0

  # Block: DEV/SIT profile + af-south-1
  if echo "$COMMAND" | grep -qiE '(Tebogo-dev|dev|536580886816)' && echo "$COMMAND" | grep -qF 'af-south-1'; then
    echo "BLOCKED: Wrong region for DEV environment."
    echo ""
    echo "  Command: $COMMAND"
    echo "  DEV uses eu-west-1, not af-south-1."
    echo ""
    echo "  DEV  (536580886816) → eu-west-1"
    echo "  SIT  (815856636111) → eu-west-1"
    echo "  PROD (093646564004) → af-south-1"
    echo ""
    echo "Rule: AWS Cognito Environment Configuration (CLAUDE.md)"
    exit 2
  fi
  if echo "$COMMAND" | grep -qiE '(Tebogo-sit|sit|815856636111)' && echo "$COMMAND" | grep -qF 'af-south-1'; then
    echo "BLOCKED: Wrong region for SIT environment."
    echo ""
    echo "  Command: $COMMAND"
    echo "  SIT uses eu-west-1, not af-south-1."
    echo ""
    echo "  DEV  (536580886816) → eu-west-1"
    echo "  SIT  (815856636111) → eu-west-1"
    echo "  PROD (093646564004) → af-south-1"
    echo ""
    echo "Rule: AWS Cognito Environment Configuration (CLAUDE.md)"
    exit 2
  fi
  exit 0
fi

# ── Handle Write|Edit tool ──
if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" ]] && exit 0

# Only check Terraform variable files and workflow files
case "$FILE_PATH" in
  *.tfvars | *.tf | *.yml | *.yaml) ;;
  *) exit 0 ;;
esac

# Exclude the hooks repo itself
case "$FILE_PATH" in
  */0_utilities/claude-hooks/* | */0_utilities/templates/*) exit 0 ;;
esac

# Get content
if [[ "$TOOL_NAME" == "Write" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
elif [[ "$TOOL_NAME" == "Edit" ]]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
fi
[[ -z "$CONTENT" ]] && exit 0

# Determine environment from file path
ENV=""
case "$FILE_PATH" in
  *dev.tfvars | *dev*.tfvars | */dev/* | *deploy-dev* | *-dev.*)
    ENV="dev" ;;
  *sit.tfvars | *sit*.tfvars | */sit/* | *promote-sit* | *-sit.*)
    ENV="sit" ;;
  *prod.tfvars | *prod*.tfvars | */prod/* | *promote-prod* | *-prod.*)
    ENV="prod" ;;
esac

# If we can't determine env from path, check content for environment = "..."
if [[ -z "$ENV" ]]; then
  if echo "$CONTENT" | grep -qE 'environment\s*=\s*"dev"'; then
    ENV="dev"
  elif echo "$CONTENT" | grep -qE 'environment\s*=\s*"sit"'; then
    ENV="sit"
  elif echo "$CONTENT" | grep -qE 'environment\s*=\s*"prod"'; then
    ENV="prod"
  fi
fi

[[ -z "$ENV" ]] && exit 0

# Check: DEV/SIT must NOT contain af-south-1
if [[ "$ENV" == "dev" || "$ENV" == "sit" ]]; then
  if echo "$CONTENT" | grep -qF 'af-south-1'; then
    echo "BLOCKED: Wrong region for $(echo "$ENV" | tr '[:lower:]' '[:upper:]') environment."
    echo ""
    echo "  File: $FILE_PATH"
    echo "  Found: af-south-1 (this is the PROD region)"
    echo "  Expected: eu-west-1"
    echo ""
    echo "  Environment → Region mapping:"
    echo "    DEV  (536580886816) → eu-west-1"
    echo "    SIT  (815856636111) → eu-west-1"
    echo "    PROD (093646564004) → af-south-1"
    echo ""
    echo "Rule: AWS Cognito Environment Configuration (CLAUDE.md)"
    exit 2
  fi
fi

# Check: PROD must NOT contain eu-west-1 for region settings
# (PROD may legitimately reference eu-west-1 for DR, so only block aws_region/region assignments)
if [[ "$ENV" == "prod" ]]; then
  if echo "$CONTENT" | grep -qE '(aws_region|region)\s*=\s*"eu-west-1"'; then
    echo "BLOCKED: Wrong region for PROD environment."
    echo ""
    echo "  File: $FILE_PATH"
    echo "  Found: eu-west-1 as aws_region (this is the DEV/SIT region)"
    echo "  Expected: af-south-1"
    echo ""
    echo "  Environment → Region mapping:"
    echo "    DEV  (536580886816) → eu-west-1"
    echo "    SIT  (815856636111) → eu-west-1"
    echo "    PROD (093646564004) → af-south-1"
    echo ""
    echo "Rule: AWS Cognito Environment Configuration (CLAUDE.md)"
    exit 2
  fi
fi

# Cross-check: account ID vs region mismatch
# DEV account with PROD region
if echo "$CONTENT" | grep -qF '536580886816' && echo "$CONTENT" | grep -qF 'af-south-1'; then
  echo "BLOCKED: Account/region mismatch — DEV account (536580886816) with PROD region (af-south-1)."
  echo ""
  echo "  File: $FILE_PATH"
  echo "  DEV account 536580886816 must use eu-west-1."
  echo ""
  echo "Rule: AWS Cognito Environment Configuration (CLAUDE.md)"
  exit 2
fi

# SIT account with PROD region
if echo "$CONTENT" | grep -qF '815856636111' && echo "$CONTENT" | grep -qF 'af-south-1'; then
  echo "BLOCKED: Account/region mismatch — SIT account (815856636111) with PROD region (af-south-1)."
  echo ""
  echo "  File: $FILE_PATH"
  echo "  SIT account 815856636111 must use eu-west-1."
  echo ""
  echo "Rule: AWS Cognito Environment Configuration (CLAUDE.md)"
  exit 2
fi

# PROD account with DEV/SIT region (for primary region assignment only)
if echo "$CONTENT" | grep -qF '093646564004'; then
  if echo "$CONTENT" | grep -qE '(aws_region|region)\s*=\s*"eu-west-1"'; then
    echo "BLOCKED: Account/region mismatch — PROD account (093646564004) with DEV/SIT region (eu-west-1)."
    echo ""
    echo "  File: $FILE_PATH"
    echo "  PROD account 093646564004 must use af-south-1 as primary region."
    echo "  (eu-west-1 is only for DR replica references)"
    echo ""
    echo "Rule: AWS Cognito Environment Configuration (CLAUDE.md)"
    exit 2
  fi
fi

exit 0
