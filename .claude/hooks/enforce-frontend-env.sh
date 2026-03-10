#!/usr/bin/env bash
# enforce-frontend-env.sh — Block broken frontend env var patterns
# Claude Code PreToolUse hook for Bash and Write|Edit tool calls
# Exit 2 = block with feedback | Exit 0 = allow
#
# Prevents:
#   1. Inline VITE_X=... npm run build (vars don't reach Vite's loadEnv)
#   2. Hardcoded region fallbacks in frontend config (silent wrong-env routing)
#   3. npm run build without --mode flag (won't load correct .env file)
#
set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# ── Handle Bash tool ──
if [[ "$TOOL_NAME" == "Bash" ]]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [[ -z "$COMMAND" ]] && exit 0

  # Block: VITE_*=... npm run build (inline env injection — vars won't reach Vite)
  if echo "$COMMAND" | grep -qE 'VITE_[A-Z_]+=\S+.*npm run build'; then
    echo "BLOCKED: Inline VITE_* env vars with npm run build."
    echo ""
    echo "  Command: $COMMAND"
    echo ""
    echo "  Vite's loadEnv() reads from .env files on disk, NOT from shell environment."
    echo "  Inline vars (VITE_X=foo npm run build) are IGNORED by Vite in production mode."
    echo ""
    echo "  Correct approach:"
    echo "    1. Create .env.{mode} file (e.g., .env.production) with all VITE_* vars"
    echo "    2. Run: npm run build -- --mode production"
    echo "    OR use mode-specific scripts: npm run build:dev, build:sit, build:prod"
    echo ""
    echo "  Vite loads these files (in order of priority):"
    echo "    .env                  # always loaded"
    echo "    .env.local            # always loaded, git-ignored"
    echo "    .env.{mode}           # only in specified mode"
    echo "    .env.{mode}.local     # only in specified mode, git-ignored"
    echo ""
    echo "  .env.development is ONLY loaded when mode=development (npm run dev)."
    echo "  npm run build defaults to mode=production → loads .env.production."
    echo ""
    echo "Rule: CLAUDE.md — Frontend UI Verification Rule + Cognito Environment Configuration"
    exit 2
  fi

  # Block: plain `npm run build` without --mode in a frontend directory
  # (Allow build:dev, build:sit, build:prod which have mode baked in)
  if echo "$COMMAND" | grep -qE '^npm run build$' || echo "$COMMAND" | grep -qE '&& npm run build$' || echo "$COMMAND" | grep -qE '\|\| npm run build$'; then
    # Check if this looks like a frontend context (has VITE_ references nearby)
    # We can't know the directory, so just warn — don't block
    echo "WARNING: Plain 'npm run build' uses mode=production by default."
    echo ""
    echo "  This loads .env.production (NOT .env.development)."
    echo "  If you're building for DEV, use: npm run build:dev (or npm run build -- --mode dev)"
    echo "  If .env.production doesn't exist, all VITE_* vars will be undefined."
    echo ""
    echo "  Available build modes: build:dev, build:sit, build:prod"
    # Don't block — just warn. Exit 0.
    exit 0
  fi

  exit 0
fi

# ── Handle Write|Edit tool ──
if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$FILE_PATH" ]] && exit 0

# Exclude hooks repo
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

# ── Check: Hardcoded region fallbacks in frontend config ──
case "$FILE_PATH" in
  *.ts | *.tsx | *.js | *.jsx)
    # Block: import.meta.env.VITE_*REGION* || 'af-south-1' or 'eu-west-1'
    if echo "$CONTENT" | grep -qE "import\.meta\.env\.VITE_.*\|\|.*'(af-south-1|eu-west-1)'"; then
      MATCH=$(echo "$CONTENT" | grep -oE "import\.meta\.env\.VITE_[A-Z_]+.*\|\|.*'[a-z0-9-]+'" | head -1)
      echo "BLOCKED: Hardcoded region fallback in frontend config."
      echo ""
      echo "  File: $FILE_PATH"
      echo "  Found: $MATCH"
      echo ""
      echo "  Silent fallbacks route traffic to the wrong environment."
      echo "  Use fail-fast instead:"
      echo ""
      echo "    function requireEnv(name: string): string {"
      echo "      const value = import.meta.env[name];"
      echo "      if (!value) throw new Error(\`\${name} is required\`);"
      echo "      return value;"
      echo "    }"
      echo "    const region = requireEnv('VITE_AWS_REGION');"
      echo ""
      echo "Rule: CLAUDE.md — Cognito Environment Configuration + Never Hardcode Regions"
      exit 2
    fi

    # Block: Hardcoded Cognito pool IDs in source code
    if echo "$CONTENT" | grep -qE "'(af-south-1|eu-west-1)_[A-Za-z0-9]+'"; then
      MATCH=$(echo "$CONTENT" | grep -oE "'[a-z]+-[a-z]+-[0-9]_[A-Za-z0-9]+'" | head -1)
      echo "BLOCKED: Hardcoded Cognito User Pool ID in frontend source code."
      echo ""
      echo "  File: $FILE_PATH"
      echo "  Found: $MATCH"
      echo ""
      echo "  Use environment variables: import.meta.env.VITE_COGNITO_USER_POOL_ID"
      echo ""
      echo "Rule: API & Cloud Security Rule #22 — Never hardcode Cognito IDs in frontend code"
      exit 2
    fi

    # Block: Hardcoded region strings assigned to region/REGION variables
    if echo "$CONTENT" | grep -qE "(region|REGION|aws_region)\s*[:=]\s*['\"]af-south-1['\"]"; then
      echo "BLOCKED: Hardcoded AWS region in frontend code."
      echo ""
      echo "  File: $FILE_PATH"
      echo "  Found: hardcoded af-south-1"
      echo ""
      echo "  Use: import.meta.env.VITE_AWS_REGION (injected via .env.{mode} file)"
      echo ""
      echo "Rule: CLAUDE.md — Never Hardcode Regions (#22)"
      exit 2
    fi
    if echo "$CONTENT" | grep -qE "(region|REGION|aws_region)\s*[:=]\s*['\"]eu-west-1['\"]"; then
      echo "BLOCKED: Hardcoded AWS region in frontend code."
      echo ""
      echo "  File: $FILE_PATH"
      echo "  Found: hardcoded eu-west-1"
      echo ""
      echo "  Use: import.meta.env.VITE_AWS_REGION (injected via .env.{mode} file)"
      echo ""
      echo "Rule: CLAUDE.md — Never Hardcode Regions (#22)"
      exit 2
    fi
    ;;
esac

# ── Check: GitHub Actions workflow injecting VITE_* vars inline ──
case "$FILE_PATH" in
  *.yml | *.yaml)
    if echo "$CONTENT" | grep -qE 'VITE_[A-Z_]+:.*\$\{\{' && echo "$CONTENT" | grep -qF 'npm run build'; then
      echo "BLOCKED: GitHub Actions workflow injects VITE_* vars inline with npm run build."
      echo ""
      echo "  File: $FILE_PATH"
      echo ""
      echo "  Vite's loadEnv() reads from .env files, not shell environment."
      echo "  Inline env: blocks in GitHub Actions won't reach Vite."
      echo ""
      echo "  Fix: Create .env.{mode} files with VITE_* vars, or use a step that"
      echo "  writes vars to .env.production before running npm run build."
      echo ""
      echo "  Example (correct pattern from kimmyai_landing):"
      echo "    - name: Write .env.production"
      echo "      run: |"
      echo "        echo \"VITE_API_URL=\${{ vars.API_URL }}\" >> .env.production"
      echo "        echo \"VITE_COGNITO_USER_POOL_ID=\${{ vars.POOL_ID }}\" >> .env.production"
      echo "    - name: Build"
      echo "      run: npm run build:prod"
      echo ""
      echo "Rule: CLAUDE.md — Frontend UI Verification Rule"
      exit 2
    fi
    ;;
esac

exit 0
