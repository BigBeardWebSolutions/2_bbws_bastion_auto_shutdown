# Bastion Auto-Shutdown Lambda Function

## Overview

AWS Lambda function that automatically stops idle bastion EC2 instances after a configurable timeout period. Designed to minimize costs for WordPress migration bastion hosts that are only needed occasionally.

## Purpose

- **Cost Optimization:** Automatically stop bastion instances when idle
- **Zero Manual Effort:** No need to remember to stop instances
- **Activity Monitoring:** Checks CPU, network I/O, and SSM sessions
- **Audit Trail:** Tracks all sessions in DynamoDB
- **Notifications:** SNS alerts when instances are auto-stopped

## Features

### Idle Detection
- **CloudWatch Metrics:** Monitors CPU and network I/O
- **SSM Session Check:** Detects active SSH sessions
- **DynamoDB Tracking:** Records activity timestamps
- **Configurable Thresholds:** Customize idle detection criteria

### Safety Features
- **Fail-Safe Design:** On error, keeps instance running
- **Active Session Protection:** Never stops instance with active SSM sessions
- **High Activity Protection:** Keeps instance running if CPU > 5% or network active
- **CloudWatch Alarms:** Alerts on Lambda execution errors

### Cost Savings
- **80% Reduction:** From $8.50/month to $1.70/month (typical usage)
- **On-Demand Usage:** Only run bastion when needed
- **Automatic Cleanup:** No forgotten running instances

## Architecture

```
EventBridge (every 5 min) → Lambda Function → EC2 API
                                ↓
                          DynamoDB (session tracking)
                                ↓
                          CloudWatch (metrics)
                                ↓
                          SSM (session status)
                                ↓
                          SNS (notifications)
```

## How It Works

1. **EventBridge Trigger:** Lambda runs every 5 minutes
2. **Find Instances:** Queries EC2 for bastion instances with tag `ManagedBy: bastion-auto-shutdown`
3. **Check Status:** Skips instances that are already stopped
4. **Measure Activity:**
   - Get CPU utilization from CloudWatch (last 30 minutes)
   - Get network I/O from CloudWatch (last 30 minutes)
   - Check for active SSM sessions
   - Query DynamoDB for last activity timestamp
5. **Decision Logic:**
   - **Keep Running** if:
     - Active SSM session exists
     - CPU usage > 5%
     - Network I/O > 1MB in last 30 minutes
     - Last activity < 30 minutes ago
   - **Stop Instance** if:
     - No active SSM sessions
     - CPU usage < 5%
     - Network I/O < 1MB
     - Last activity > 30 minutes ago
6. **Actions on Stop:**
   - Stop EC2 instance
   - Update DynamoDB record (status=stopped, stopped_by=auto_shutdown)
   - Send SNS notification

## Deployment

### Prerequisites
- AWS account with appropriate IAM permissions
- Terraform >= 1.0
- Python 3.11+ (for local testing)
- Bastion instance deployed with tag `ManagedBy: bastion-auto-shutdown`

### Terraform Deployment

```bash
cd terraform/

# Initialize Terraform
terraform init

# Plan deployment
terraform plan \
  -var="environment=dev" \
  -var="aws_region=eu-west-1" \
  -var="alert_email=your-email@example.com"

# Apply deployment
terraform apply \
  -var="environment=dev" \
  -var="aws_region=eu-west-1" \
  -var="alert_email=your-email@example.com"
```

### Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `environment` | - | Environment name (dev, sit, prod) |
| `aws_region` | - | AWS region |
| `idle_threshold_minutes` | `30` | Minutes of idle time before shutdown |
| `cpu_idle_threshold` | `5.0` | CPU % threshold (below = idle) |
| `network_idle_threshold` | `1000000` | Network bytes threshold (below = idle) |
| `alert_email` | `""` | Email for SNS notifications (optional) |
| `log_level` | `INFO` | Lambda log level |

### Deployed Resources

- **Lambda Function:** `{environment}-bastion-auto-shutdown`
- **DynamoDB Table:** `{environment}-bastion-sessions`
- **SNS Topic:** `{environment}-bastion-auto-shutdown`
- **EventBridge Rule:** `{environment}-bastion-auto-shutdown-check` (every 5 minutes)
- **CloudWatch Log Group:** `/aws/lambda/{environment}-bastion-auto-shutdown`
- **CloudWatch Alarm:** `{environment}-bastion-auto-shutdown-errors`

## Testing

### Unit Tests (TDD)

```bash
# Install test dependencies
pip install -r requirements.txt

# Run unit tests
pytest tests/test_handler.py -v

# Run with coverage
pytest tests/test_handler.py --cov=src --cov-report=html
```

### Test Scenarios Covered

1. **Idle bastion gets stopped** - CPU < 5%, network < 1MB, no SSM sessions, idle > 30 min
2. **Active bastion not stopped** - Recent activity within threshold
3. **Bastion with SSM session not stopped** - Active session prevents shutdown
4. **Stopped bastion skipped** - Already stopped instances ignored
5. **High CPU not stopped** - CPU > 5% indicates activity
6. **Error handling** - Graceful handling of API errors

### Manual Testing

```bash
# Invoke Lambda manually via AWS CLI
aws lambda invoke \
  --function-name dev-bastion-auto-shutdown \
  --region eu-west-1 \
  --profile Tebogo-dev \
  response.json

# View response
cat response.json
```

## Monitoring

### CloudWatch Logs

```bash
# Tail Lambda logs
aws logs tail /aws/lambda/dev-bastion-auto-shutdown \
  --follow \
  --profile Tebogo-dev
```

### CloudWatch Metrics

- **Lambda Invocations:** Count of executions
- **Lambda Errors:** Failed executions
- **Lambda Duration:** Execution time
- **Custom Metrics:** Bastion/dev/BootstrapComplete

### DynamoDB Table

```bash
# Query bastion sessions
aws dynamodb scan \
  --table-name dev-bastion-sessions \
  --profile Tebogo-dev
```

**Table Schema:**
- `instance_id` (Partition Key): EC2 instance ID
- `session_start`: Unix timestamp
- `last_activity`: Unix timestamp
- `status`: active | idle | stopped
- `environment`: dev | sit | prod
- `stopped_by`: manual | auto_shutdown | timeout
- `stopped_at`: Unix timestamp
- `ttl`: TTL for automatic cleanup (90 days)

### SNS Notifications

When a bastion is auto-stopped, you'll receive an email:

```
Subject: [dev] Bastion Auto-Stopped: dev-wordpress-migration-bastion

Bastion Instance Auto-Stopped

Environment: dev
Instance ID: i-1234567890abcdef0
Instance Name: dev-wordpress-migration-bastion
Reason: idle_30min
Stopped At: 2024-01-15T10:30:00

The bastion instance was automatically stopped after 30 minutes of idle time.

To restart:
aws ec2 start-instances --instance-ids i-1234567890abcdef0 --region eu-west-1

To connect:
aws ssm start-session --target i-1234567890abcdef0 --region eu-west-1
```

## Troubleshooting

### Lambda Not Stopping Idle Bastion

1. **Check Instance Tags:**
   ```bash
   aws ec2 describe-instances \
     --instance-ids i-1234567890abcdef0 \
     --query 'Reservations[0].Instances[0].Tags'
   ```
   Ensure tags include:
   - `ManagedBy: bastion-auto-shutdown`
   - `Environment: dev` (matches Lambda environment)

2. **Check CloudWatch Metrics:**
   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/EC2 \
     --metric-name CPUUtilization \
     --dimensions Name=InstanceId,Value=i-1234567890abcdef0 \
     --start-time 2024-01-15T10:00:00Z \
     --end-time 2024-01-15T10:30:00Z \
     --period 300 \
     --statistics Average
   ```

3. **Check SSM Sessions:**
   ```bash
   aws ssm describe-sessions \
     --state Active \
     --filters key=Target,value=i-1234567890abcdef0
   ```

4. **Check Lambda Logs:**
   ```bash
   aws logs tail /aws/lambda/dev-bastion-auto-shutdown --follow
   ```

### Lambda Execution Errors

1. **Check IAM Permissions:**
   ```bash
   aws iam get-role-policy \
     --role-name dev-bastion-auto-shutdown-lambda-role \
     --policy-name dev-bastion-auto-shutdown-lambda-policy
   ```

2. **Check CloudWatch Alarms:**
   ```bash
   aws cloudwatch describe-alarms \
     --alarm-names dev-bastion-auto-shutdown-errors
   ```

3. **Review Error Logs:**
   ```bash
   aws logs filter-log-events \
     --log-group-name /aws/lambda/dev-bastion-auto-shutdown \
     --filter-pattern "ERROR"
   ```

### DynamoDB Issues

1. **Table Exists:**
   ```bash
   aws dynamodb describe-table --table-name dev-bastion-sessions
   ```

2. **Check GSI:**
   ```bash
   aws dynamodb describe-table \
     --table-name dev-bastion-sessions \
     --query 'Table.GlobalSecondaryIndexes'
   ```

## Cost Analysis

### Monthly Costs (DEV Environment)

**Lambda:**
- Invocations: 8,640/month (every 5 minutes)
- Duration: ~2 seconds/invocation
- Memory: 256MB
- **Cost:** ~$0.20/month

**DynamoDB:**
- On-demand reads: ~260/month
- On-demand writes: ~130/month
- **Cost:** ~$0.01/month

**SNS:**
- Notifications: ~60/month (assuming 2 stops/day)
- **Cost:** ~$0.01/month

**CloudWatch Logs:**
- Log storage: ~100MB/month
- **Cost:** ~$0.50/month

**Total Lambda Infrastructure:** ~$0.72/month

**Combined with Bastion (8 hours/month usage):** ~$2.42/month

**Savings vs Always-On Bastion:** 72% ($8.50 → $2.42)

## Maintenance

### Updating Lambda Code

```bash
# 1. Update src/handler.py or utils/*

# 2. Run tests
pytest tests/ -v

# 3. Deploy via Terraform
cd terraform/
terraform apply -var="environment=dev"
```

### Adjusting Idle Timeout

```bash
terraform apply \
  -var="environment=dev" \
  -var="idle_threshold_minutes=60"  # Increase to 60 minutes
```

### Disabling Auto-Shutdown

```bash
# Disable EventBridge rule
aws events disable-rule \
  --name dev-bastion-auto-shutdown-check \
  --region eu-west-1
```

### Enabling Auto-Shutdown

```bash
# Enable EventBridge rule
aws events enable-rule \
  --name dev-bastion-auto-shutdown-check \
  --region eu-west-1
```

## Development

### Project Structure

```
2_bbws_bastion_auto_shutdown/
├── src/
│   ├── handler.py              # Main Lambda handler
│   ├── utils/
│   │   ├── logger.py           # Structured logging
│   │   └── metrics.py          # CloudWatch metrics helper
│   └── __init__.py
├── tests/
│   └── test_handler.py         # Unit tests (TDD)
├── terraform/
│   ├── lambda.tf               # Lambda, SNS, EventBridge
│   ├── dynamodb.tf             # Session tracking table
│   ├── variables.tf            # Input variables
│   └── outputs.tf              # Output values
├── requirements.txt            # Python dependencies
└── README.md                   # This file
```

### Local Development

```bash
# Install dependencies
pip install -r requirements.txt

# Run tests
pytest tests/ -v --cov=src

# Lint code
pylint src/

# Type checking
mypy src/
```

## References

- [AWS Lambda](https://docs.aws.amazon.com/lambda/)
- [EventBridge](https://docs.aws.amazon.com/eventbridge/)
- [DynamoDB](https://docs.aws.amazon.com/dynamodb/)
- [SNS](https://docs.aws.amazon.com/sns/)
- [SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [Bastion Operations Guide](../2_bbws_agents/tenant/migrations/runbooks/bastion_operations_guide.md)
- [WordPress Migration Playbook](../2_bbws_agents/tenant/migrations/runbooks/wordpress_migration_playbook_automated.md)

## Support

For issues or questions:
1. Check CloudWatch Logs: `/aws/lambda/{environment}-bastion-auto-shutdown`
2. Review DynamoDB records: `{environment}-bastion-sessions`
3. Check CloudWatch Alarms: `{environment}-bastion-auto-shutdown-errors`
4. Contact DevOps team

## License

Internal use only - BBWS Platform
