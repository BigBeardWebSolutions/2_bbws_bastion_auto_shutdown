#!/usr/bin/env bash
# enforce-iac.sh — Block AWS CLI infrastructure mutations
# Claude Code PreToolUse hook for Bash tool calls
# Exit 2 = block with feedback | Exit 0 = allow
set -euo pipefail

INPUT=$(cat)

# Only check Bash tool calls
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# Allowed read-only and operational AWS CLI commands
ALLOWED_PATTERNS=(
  "aws .* describe-"
  "aws .* list-"
  "aws .* get-"
  "aws .* scan"
  "aws s3 ls"
  "aws s3 sync"
  "aws s3 cp"
  "aws s3 mv"
  "aws s3 rm"
  "aws cloudfront create-invalidation"
  "aws cloudfront wait"
  "aws logs tail"
  "aws logs filter-log-events"
  "aws logs get-log-events"
  "aws sts get-caller-identity"
  "aws sts assume-role"
  "aws configure"
  "aws --version"
  "aws help"
)

# Blocked infrastructure mutation commands (service + action pairs)
BLOCKED_PATTERNS=(
  "aws s3api create-bucket"
  "aws s3api delete-bucket"
  "aws s3api put-bucket-policy"
  "aws s3api put-bucket-acl"
  "aws s3api put-bucket-website"
  "aws s3api put-bucket-cors"
  "aws s3api put-bucket-encryption"
  "aws s3api put-bucket-versioning"
  "aws s3api put-public-access-block"
  "aws cloudfront create-distribution"
  "aws cloudfront update-distribution"
  "aws cloudfront delete-distribution"
  "aws lambda create-function"
  "aws lambda update-function-configuration"
  "aws lambda update-function-code"
  "aws lambda delete-function"
  "aws lambda add-permission"
  "aws lambda remove-permission"
  "aws lambda publish-layer-version"
  "aws iam create-role"
  "aws iam delete-role"
  "aws iam attach-role-policy"
  "aws iam detach-role-policy"
  "aws iam put-role-policy"
  "aws iam delete-role-policy"
  "aws iam create-policy"
  "aws iam delete-policy"
  "aws iam create-user"
  "aws iam delete-user"
  "aws dynamodb create-table"
  "aws dynamodb delete-table"
  "aws dynamodb update-table"
  "aws dynamodb update-time-to-live"
  "aws apigateway create-rest-api"
  "aws apigateway delete-rest-api"
  "aws apigateway create-resource"
  "aws apigateway put-method"
  "aws apigateway put-integration"
  "aws apigatewayv2 create-api"
  "aws apigatewayv2 delete-api"
  "aws apigatewayv2 create-route"
  "aws apigatewayv2 update-api"
  "aws apigatewayv2 update-route"
  "aws route53 change-resource-record-sets"
  "aws cognito-idp create-user-pool"
  "aws cognito-idp delete-user-pool"
  "aws cognito-idp update-user-pool"
  "aws ec2 create-vpc"
  "aws ec2 delete-vpc"
  "aws ec2 create-subnet"
  "aws ec2 delete-subnet"
  "aws ec2 create-security-group"
  "aws ec2 delete-security-group"
  "aws ec2 authorize-security-group"
  "aws ec2 revoke-security-group"
  "aws ecs create-cluster"
  "aws ecs delete-cluster"
  "aws ecs create-service"
  "aws ecs update-service"
  "aws ecs delete-service"
  "aws ecs register-task-definition"
  "aws sns create-topic"
  "aws sns delete-topic"
  "aws sqs create-queue"
  "aws sqs delete-queue"
  "aws kms create-key"
  "aws kms schedule-key-deletion"
  "aws secretsmanager create-secret"
  "aws secretsmanager delete-secret"
  "aws ssm put-parameter"
  "aws ssm delete-parameter"
  "aws acm request-certificate"
  "aws acm delete-certificate"
  "aws wafv2 create-web-acl"
  "aws wafv2 delete-web-acl"
  "aws wafv2 update-web-acl"
)

# Skip if command doesn't contain "aws "
if [[ "$COMMAND" != *"aws "* ]]; then
  exit 0
fi

# Check if the command matches any allowed pattern first
for pattern in "${ALLOWED_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qE "$pattern"; then
    exit 0
  fi
done

# Check if the command matches any blocked pattern
for pattern in "${BLOCKED_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qF "$pattern"; then
    echo "BLOCKED: Infrastructure mutation via AWS CLI detected."
    echo "  Command: $COMMAND"
    echo "  Matched: $pattern"
    echo ""
    echo "Use Terraform to manage infrastructure. AWS CLI is only permitted for:"
    echo "  - Read-only operations (describe, list, get, scan)"
    echo "  - S3 content sync (aws s3 sync/cp)"
    echo "  - CloudFront invalidation (aws cloudfront create-invalidation)"
    echo "  - Log tailing (aws logs tail)"
    echo ""
    echo "Rule: TBT Law #11 — Infrastructure changes MUST use Terraform (IaC) only"
    exit 2
  fi
done

# If it's an aws command that's neither explicitly allowed nor blocked,
# check for generic mutation verbs as a safety net
MUTATION_VERBS="create-|delete-|update-|put-|attach-|detach-|remove-|modify-|register-|deregister-|add-|revoke-|authorize-|schedule-|enable-|disable-"
if echo "$COMMAND" | grep -qE "aws [a-z0-9-]+ ($MUTATION_VERBS)"; then
  # Extract the specific aws subcommand for the message
  SUBCMD=$(echo "$COMMAND" | grep -oE "aws [a-z0-9-]+ [a-z-]+" | head -1)
  echo "BLOCKED: Potential infrastructure mutation via AWS CLI detected."
  echo "  Command: $SUBCMD"
  echo ""
  echo "This command appears to mutate infrastructure. Use Terraform instead."
  echo "If this is a false positive, add an explicit allow pattern to enforce-iac.sh."
  echo ""
  echo "Rule: TBT Law #11 — Infrastructure changes MUST use Terraform (IaC) only"
  exit 2
fi

exit 0
