# DynamoDB Table for Bastion Session Tracking

resource "aws_dynamodb_table" "bastion_sessions" {
  name           = "${var.environment}-bastion-sessions"
  billing_mode   = "PAY_PER_REQUEST"  # On-demand pay per request
  hash_key       = "instance_id"
  stream_enabled = false

  attribute {
    name = "instance_id"
    type = "S"
  }

  attribute {
    name = "environment"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  # Global Secondary Index for querying by environment and status
  global_secondary_index {
    name            = "EnvironmentStatusIndex"
    hash_key        = "environment"
    range_key       = "status"
    projection_type = "ALL"
  }

  # TTL to automatically delete old records after 90 days
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  # Point-in-time recovery for production
  point_in_time_recovery {
    enabled = var.environment == "prod" ? true : false
  }

  tags = merge(
    var.tags,
    {
      Name        = "${var.environment}-bastion-sessions"
      Environment = var.environment
      Purpose     = "Bastion Session Tracking"
      ManagedBy   = "Terraform"
    }
  )
}

# Output for Lambda environment variable
output "bastion_sessions_table_name" {
  description = "DynamoDB table name for bastion sessions"
  value       = aws_dynamodb_table.bastion_sessions.name
}

output "bastion_sessions_table_arn" {
  description = "DynamoDB table ARN for bastion sessions"
  value       = aws_dynamodb_table.bastion_sessions.arn
}
