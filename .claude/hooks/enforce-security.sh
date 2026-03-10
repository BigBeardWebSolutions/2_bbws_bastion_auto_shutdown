#!/usr/bin/env bash
# enforce-security.sh — Block security anti-patterns
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

# Exclude the hooks repo itself and test fixtures
case "$FILE_PATH" in
  */0_utilities/claude-hooks/* | */0_utilities/templates/*)
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

# --- Check 1: Wildcard CORS ---
# Match patterns like: "Access-Control-Allow-Origin": "*" or '*' or `*`
if echo "$CONTENT" | grep -qE "Access-Control-Allow-Origin.*[\"'][*][\"']"; then
  echo "BLOCKED: Wildcard CORS origin detected."
  echo ""
  echo "  File: $FILE_PATH"
  echo "  Found: Access-Control-Allow-Origin: \"*\""
  echo ""
  echo "Always specify exact allowed origin(s). Example:"
  echo "  \"Access-Control-Allow-Origin\": \"https://dev.kimmyai.io\""
  echo ""
  echo "Rule: API & Cloud Security Rule #5 — NEVER use Access-Control-Allow-Origin: *"
  exit 2
fi

# Also catch Allow-Methods: * and Allow-Headers: *
if echo "$CONTENT" | grep -qE "Access-Control-Allow-Methods.*[\"'][*][\"']"; then
  echo "BLOCKED: Wildcard CORS methods detected."
  echo ""
  echo "  File: $FILE_PATH"
  echo "  Found: Access-Control-Allow-Methods: \"*\""
  echo ""
  echo "Explicitly list only supported HTTP methods (e.g., GET, POST, OPTIONS)."
  echo ""
  echo "Rule: API & Cloud Security Rule #6 — NEVER use Access-Control-Allow-Methods: *"
  exit 2
fi

if echo "$CONTENT" | grep -qE "Access-Control-Allow-Headers.*[\"'][*][\"']"; then
  echo "BLOCKED: Wildcard CORS headers detected."
  echo ""
  echo "  File: $FILE_PATH"
  echo "  Found: Access-Control-Allow-Headers: \"*\""
  echo ""
  echo "Explicitly list required headers (e.g., Content-Type, Authorization)."
  echo ""
  echo "Rule: API & Cloud Security Rule #7 — NEVER use Access-Control-Allow-Headers: *"
  exit 2
fi

# --- Check 2: Wildcard IAM in Terraform ---
case "$FILE_PATH" in
  *.tf | *.json)
    # Check for "Action": "*" or "Resource": "*"
    if echo "$CONTENT" | grep -qE '"Action"\s*:\s*"\*"'; then
      echo "BLOCKED: Wildcard IAM Action detected in Terraform/policy."
      echo ""
      echo "  File: $FILE_PATH"
      echo "  Found: \"Action\": \"*\""
      echo ""
      echo "Always scope to specific actions (e.g., \"s3:GetObject\", \"dynamodb:Query\")."
      echo ""
      echo "Rule: API & Cloud Security Rule #9 — NEVER use Action: \"*\""
      exit 2
    fi

    if echo "$CONTENT" | grep -qE '"Resource"\s*:\s*"\*"'; then
      echo "BLOCKED: Wildcard IAM Resource detected in Terraform/policy."
      echo ""
      echo "  File: $FILE_PATH"
      echo "  Found: \"Resource\": \"*\""
      echo ""
      echo "Always scope to specific resource ARNs."
      echo ""
      echo "Rule: API & Cloud Security Rule #9 — NEVER use Resource: \"*\""
      exit 2
    fi

    # Check for wildcard allow_origins in Terraform (catches both allow_origins = ["*"] and default = ["*"] in CORS contexts)
    if echo "$CONTENT" | grep -qE '(allow_origins|default)\s*=\s*\["\*"\]'; then
      echo "BLOCKED: Wildcard CORS origins in Terraform."
      echo ""
      echo "  File: $FILE_PATH"
      echo "  Found: wildcard [\"*\"] in allow_origins or default"
      echo ""
      echo "Use environment-specific origins: https://dev.kimmyai.io, etc."
      echo ""
      echo "Rule: API & Cloud Security Rule #5"
      exit 2
    fi

    # Check for Principal: "*" without conditions
    if echo "$CONTENT" | grep -qE '"Principal"\s*:\s*"\*"'; then
      echo "WARNING: Open Principal detected in policy."
      echo ""
      echo "  File: $FILE_PATH"
      echo "  Found: \"Principal\": \"*\""
      echo ""
      echo "Ensure this is behind a VPC endpoint policy or has restrictive conditions."
      echo "If intentional (e.g., S3 bucket policy with condition), add a comment explaining why."
      echo ""
      echo "Rule: API & Cloud Security Rule #10 — NEVER use Principal: \"*\" without conditions"
      exit 2
    fi
    ;;
esac

# --- Check 3: Hardcoded AWS Access Keys ---
if echo "$CONTENT" | grep -qE 'AKIA[0-9A-Z]{16}'; then
  echo "BLOCKED: Hardcoded AWS Access Key detected."
  echo ""
  echo "  File: $FILE_PATH"
  echo ""
  echo "Use IAM roles or AWS Secrets Manager instead of hardcoded credentials."
  echo ""
  echo "Rule: API & Cloud Security Rule #1 — NEVER hardcode secrets"
  exit 2
fi

# Check for common secret patterns
if echo "$CONTENT" | grep -qE "(aws_secret_access_key|AWS_SECRET_ACCESS_KEY)\s*=\s*[\"'][A-Za-z0-9/+=]{40}[\"']"; then
  echo "BLOCKED: Hardcoded AWS Secret Access Key detected."
  echo ""
  echo "  File: $FILE_PATH"
  echo ""
  echo "Use IAM roles or AWS Secrets Manager instead of hardcoded credentials."
  echo ""
  echo "Rule: API & Cloud Security Rule #1 — NEVER hardcode secrets"
  exit 2
fi

# --- Check 4: AdministratorAccess on CI/CD roles ---
case "$FILE_PATH" in
  *.tf)
    if echo "$CONTENT" | grep -qF "AdministratorAccess"; then
      echo "BLOCKED: AdministratorAccess policy reference detected in Terraform."
      echo ""
      echo "  File: $FILE_PATH"
      echo ""
      echo "NEVER use AdministratorAccess or any full-access policy on CI/CD roles."
      echo "Scope to minimum required actions and resources."
      echo ""
      echo "Rule: API & Cloud Security Rule #11"
      exit 2
    fi
    ;;
esac

exit 0
