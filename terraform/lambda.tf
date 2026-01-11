# Lambda Function for Bastion Auto-Shutdown

# Use pre-built Lambda package (built by GitHub Actions)
# Fallback to local build if running locally
locals {
  lambda_package = fileexists("${path.module}/${var.lambda_package_path}") ? "${path.module}/${var.lambda_package_path}" : data.archive_file.lambda_zip[0].output_path
}

# Archive source code (only used for local development)
data "archive_file" "lambda_zip" {
  count       = fileexists("${path.module}/${var.lambda_package_path}") ? 0 : 1
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/bastion_auto_shutdown.zip"
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${var.environment}-bastion-auto-shutdown-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = merge(
    var.tags,
    {
      Name        = "${var.environment}-bastion-auto-shutdown-lambda-role"
      Environment = var.environment
    }
  )
}

# IAM Policy for Lambda
resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.environment}-bastion-auto-shutdown-lambda-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2Control"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:StopInstances",
          "ec2:DescribeInstanceStatus"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/ManagedBy" = "bastion-auto-shutdown"
          }
        }
      },
      {
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics"
        ]
        Resource = "*"
      },
      {
        Sid    = "DynamoDBAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.bastion_sessions.arn,
          "${aws_dynamodb_table.bastion_sessions.arn}/index/*"
        ]
      },
      {
        Sid      = "SNSPublish"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.bastion_shutdown.arn
      },
      {
        Sid    = "SSMSessions"
        Effect = "Allow"
        Action = [
          "ssm:DescribeSessions",
          "ssm:GetConnectionStatus"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.environment}-bastion-auto-shutdown*"
      }
    ]
  })
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.environment}-bastion-auto-shutdown"
  retention_in_days = 30

  tags = merge(
    var.tags,
    {
      Name        = "/aws/lambda/${var.environment}-bastion-auto-shutdown"
      Environment = var.environment
    }
  )
}

# Lambda Function
resource "aws_lambda_function" "bastion_auto_shutdown" {
  filename         = local.lambda_package
  function_name    = "${var.environment}-bastion-auto-shutdown"
  role            = aws_iam_role.lambda_role.arn
  handler         = "handler.lambda_handler"
  source_code_hash = filebase64sha256(local.lambda_package)
  runtime         = "python3.11"
  timeout         = 60  # 1 minute timeout
  memory_size     = 256

  environment {
    variables = {
      ENVIRONMENT              = var.environment
      # AWS_REGION is automatically provided by Lambda runtime
      DYNAMODB_TABLE          = aws_dynamodb_table.bastion_sessions.name
      SNS_TOPIC_ARN           = aws_sns_topic.bastion_shutdown.arn
      IDLE_THRESHOLD_MINUTES  = var.idle_threshold_minutes
      CPU_IDLE_THRESHOLD      = var.cpu_idle_threshold
      NETWORK_IDLE_THRESHOLD  = var.network_idle_threshold
      LOG_LEVEL               = var.log_level
    }
  }

  tags = merge(
    var.tags,
    {
      Name        = "${var.environment}-bastion-auto-shutdown"
      Environment = var.environment
      Purpose     = "Bastion Auto-Shutdown"
    }
  )

  depends_on = [
    aws_cloudwatch_log_group.lambda_logs,
    aws_iam_role_policy.lambda_policy
  ]
}

# SNS Topic for Shutdown Notifications
resource "aws_sns_topic" "bastion_shutdown" {
  name = "${var.environment}-bastion-auto-shutdown"

  tags = merge(
    var.tags,
    {
      Name        = "${var.environment}-bastion-auto-shutdown"
      Environment = var.environment
    }
  )
}

# SNS Subscription (if email provided)
resource "aws_sns_topic_subscription" "bastion_shutdown_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.bastion_shutdown.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# EventBridge Rule (trigger every 5 minutes)
resource "aws_cloudwatch_event_rule" "bastion_check" {
  name                = "${var.environment}-bastion-auto-shutdown-check"
  description         = "Trigger bastion auto-shutdown Lambda every 5 minutes"
  schedule_expression = "rate(5 minutes)"
  # Note: Tags removed due to GitHub Actions role lacking events:ListTagsForResource permission
}

# EventBridge Target
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.bastion_check.name
  target_id = "BastionAutoShutdownLambda"
  arn       = aws_lambda_function.bastion_auto_shutdown.arn
}

# Lambda Permission for EventBridge
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bastion_auto_shutdown.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.bastion_check.arn
}

# CloudWatch Alarm for Lambda Errors
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.environment}-bastion-auto-shutdown-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = "300"
  statistic           = "Sum"
  threshold           = "3"
  alarm_description   = "Alert when bastion auto-shutdown Lambda has errors"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.bastion_auto_shutdown.function_name
  }

  alarm_actions = var.alert_email != "" ? [aws_sns_topic.bastion_shutdown.arn] : []

  tags = merge(
    var.tags,
    {
      Name        = "${var.environment}-bastion-auto-shutdown-errors"
      Environment = var.environment
    }
  )
}

# Outputs
output "lambda_function_arn" {
  description = "ARN of the bastion auto-shutdown Lambda function"
  value       = aws_lambda_function.bastion_auto_shutdown.arn
}

output "lambda_function_name" {
  description = "Name of the bastion auto-shutdown Lambda function"
  value       = aws_lambda_function.bastion_auto_shutdown.function_name
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic for shutdown notifications"
  value       = aws_sns_topic.bastion_shutdown.arn
}

output "eventbridge_rule_name" {
  description = "Name of the EventBridge rule"
  value       = aws_cloudwatch_event_rule.bastion_check.name
}
