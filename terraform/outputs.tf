# Outputs for Bastion Auto-Shutdown Infrastructure

# These are consolidated outputs from lambda.tf and dynamodb.tf

output "summary" {
  description = "Summary of deployed resources"
  value = {
    lambda_function   = aws_lambda_function.bastion_auto_shutdown.function_name
    dynamodb_table    = aws_dynamodb_table.bastion_sessions.name
    sns_topic         = aws_sns_topic.bastion_shutdown.name
    eventbridge_rule  = aws_cloudwatch_event_rule.bastion_check.name
    check_frequency   = "Every 5 minutes"
    idle_timeout      = "${var.idle_threshold_minutes} minutes"
  }
}
