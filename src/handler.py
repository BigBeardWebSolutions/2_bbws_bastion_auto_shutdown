"""
Bastion Auto-Shutdown Lambda Handler

Purpose: Automatically stop bastion EC2 instances after idle timeout
Trigger: EventBridge (every 5 minutes)
Logic:
  1. Find all bastion instances managed by this function
  2. Check if running
  3. If running, check:
     - CloudWatch metrics (CPU, network I/O)
     - SSM session status (active sessions?)
     - DynamoDB last activity timestamp
  4. If idle > timeout AND no active sessions:
     - Stop instance
     - Update DynamoDB
     - Send SNS notification
"""

import boto3
import os
import json
from datetime import datetime, timedelta
from typing import Dict, List, Any, Optional
from .utils.logger import get_logger
from .utils.metrics import MetricsHelper

# Initialize logger
logger = get_logger(__name__)

# Environment variables
ENVIRONMENT = os.environ.get('ENVIRONMENT', 'dev')
AWS_REGION = os.environ.get('AWS_REGION', 'eu-west-1')
DYNAMODB_TABLE = os.environ.get('DYNAMODB_TABLE', f'{ENVIRONMENT}-bastion-sessions')
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')
IDLE_THRESHOLD_MINUTES = int(os.environ.get('IDLE_THRESHOLD_MINUTES', '30'))
CPU_IDLE_THRESHOLD = float(os.environ.get('CPU_IDLE_THRESHOLD', '5.0'))
NETWORK_IDLE_THRESHOLD = int(os.environ.get('NETWORK_IDLE_THRESHOLD', '1000000'))  # 1MB

# Initialize AWS clients
ec2_client = boto3.client('ec2', region_name=AWS_REGION)
cloudwatch_client = boto3.client('cloudwatch', region_name=AWS_REGION)
dynamodb_client = boto3.client('dynamodb', region_name=AWS_REGION)
ssm_client = boto3.client('ssm', region_name=AWS_REGION)
sns_client = boto3.client('sns', region_name=AWS_REGION)

# Initialize metrics helper
metrics_helper = MetricsHelper()


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Lambda handler for bastion auto-shutdown.

    Args:
        event: EventBridge event
        context: Lambda context

    Returns:
        Response dict with statusCode and body
    """
    request_id = context.aws_request_id
    logger.info(f"Bastion auto-shutdown check started", extra={
        'request_id': request_id,
        'environment': ENVIRONMENT
    })

    try:
        # Find all managed bastion instances
        instances = find_managed_bastion_instances()

        if not instances:
            logger.info("No managed bastion instances found")
            return {
                'statusCode': 200,
                'body': json.dumps({'message': 'No managed bastion instances found'})
            }

        results = []
        for instance in instances:
            instance_id = instance['InstanceId']
            state = instance['State']['Name']

            logger.info(f"Processing bastion instance", extra={
                'instance_id': instance_id,
                'state': state
            })

            # Skip if already stopped
            if state == 'stopped':
                logger.info(f"Instance already stopped, skipping", extra={'instance_id': instance_id})
                results.append({
                    'instance_id': instance_id,
                    'action': 'skipped',
                    'reason': 'already_stopped'
                })
                continue

            # Skip if not running
            if state != 'running':
                logger.info(f"Instance not running (state: {state}), skipping", extra={'instance_id': instance_id})
                results.append({
                    'instance_id': instance_id,
                    'action': 'skipped',
                    'reason': f'not_running_{state}'
                })
                continue

            # Check if instance should be stopped
            should_stop, reason = should_stop_instance(instance)

            if should_stop:
                logger.info(f"Stopping idle instance", extra={
                    'instance_id': instance_id,
                    'reason': reason
                })

                # Stop the instance
                stop_instance(instance_id)

                # Update DynamoDB
                update_session_record(instance_id, 'stopped', 'auto_shutdown')

                # Send SNS notification
                send_shutdown_notification(instance, reason)

                results.append({
                    'instance_id': instance_id,
                    'action': 'stopped',
                    'reason': reason
                })
            else:
                logger.info(f"Instance still active, not stopping", extra={
                    'instance_id': instance_id,
                    'reason': reason
                })
                results.append({
                    'instance_id': instance_id,
                    'action': 'kept_running',
                    'reason': reason
                })

        logger.info(f"Bastion auto-shutdown check completed", extra={
            'results': results
        })

        return {
            'statusCode': 200,
            'body': json.dumps({
                'message': 'Bastion auto-shutdown check completed',
                'results': results
            })
        }

    except Exception as e:
        logger.error(f"Error in bastion auto-shutdown", extra={
            'error': str(e),
            'request_id': request_id
        }, exc_info=True)
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': str(e),
                'message': 'Error in bastion auto-shutdown'
            })
        }


def find_managed_bastion_instances() -> List[Dict[str, Any]]:
    """
    Find all EC2 instances managed by this auto-shutdown function.

    Returns:
        List of instance dictionaries
    """
    try:
        response = ec2_client.describe_instances(
            Filters=[
                {'Name': 'tag:ManagedBy', 'Values': ['bastion-auto-shutdown']},
                {'Name': 'tag:Environment', 'Values': [ENVIRONMENT]}
            ]
        )

        instances = []
        for reservation in response.get('Reservations', []):
            instances.extend(reservation.get('Instances', []))

        return instances

    except Exception as e:
        logger.error(f"Error finding bastion instances", extra={'error': str(e)}, exc_info=True)
        raise


def should_stop_instance(instance: Dict[str, Any]) -> tuple[bool, str]:
    """
    Determine if instance should be stopped based on activity.

    Args:
        instance: EC2 instance dictionary

    Returns:
        Tuple of (should_stop: bool, reason: str)
    """
    instance_id = instance['InstanceId']

    try:
        # Check for active SSM sessions
        if has_active_ssm_sessions(instance_id):
            return False, "active_ssm_session"

        # Check CloudWatch metrics
        cpu_usage = metrics_helper.get_instance_cpu_usage(instance_id, IDLE_THRESHOLD_MINUTES)
        network_io = metrics_helper.get_instance_network_io(instance_id, IDLE_THRESHOLD_MINUTES)

        logger.info(f"Instance metrics", extra={
            'instance_id': instance_id,
            'cpu_usage': cpu_usage,
            'network_io_total': network_io['total']
        })

        # Check if CPU is high
        if cpu_usage >= CPU_IDLE_THRESHOLD:
            return False, f"high_cpu_{cpu_usage:.1f}%"

        # Check if network activity is high
        if network_io['total'] >= NETWORK_IDLE_THRESHOLD:
            return False, f"high_network_{network_io['total']}_bytes"

        # Check DynamoDB session record
        session = get_session_record(instance_id)
        if session:
            last_activity_ts = int(session.get('last_activity', {}).get('N', '0'))
            last_activity = datetime.fromtimestamp(last_activity_ts)
            idle_minutes = (datetime.utcnow() - last_activity).total_seconds() / 60

            logger.info(f"Session info", extra={
                'instance_id': instance_id,
                'last_activity': last_activity.isoformat(),
                'idle_minutes': idle_minutes
            })

            if idle_minutes < IDLE_THRESHOLD_MINUTES:
                return False, f"recent_activity_{idle_minutes:.0f}min_ago"

        # All checks passed - instance is idle
        return True, f"idle_{IDLE_THRESHOLD_MINUTES}min"

    except Exception as e:
        logger.error(f"Error checking if instance should stop", extra={
            'instance_id': instance_id,
            'error': str(e)
        }, exc_info=True)
        # On error, don't stop (fail safe)
        return False, f"error_checking_{str(e)[:50]}"


def has_active_ssm_sessions(instance_id: str) -> bool:
    """
    Check if instance has any active SSM sessions.

    Args:
        instance_id: EC2 instance ID

    Returns:
        True if active sessions exist, False otherwise
    """
    try:
        response = ssm_client.describe_sessions(
            State='Active',
            Filters=[
                {'key': 'Target', 'value': instance_id}
            ]
        )

        sessions = response.get('Sessions', [])
        has_sessions = len(sessions) > 0

        if has_sessions:
            logger.info(f"Active SSM sessions found", extra={
                'instance_id': instance_id,
                'session_count': len(sessions)
            })

        return has_sessions

    except Exception as e:
        logger.error(f"Error checking SSM sessions", extra={
            'instance_id': instance_id,
            'error': str(e)
        }, exc_info=True)
        # On error, assume there might be sessions (fail safe)
        return True


def get_session_record(instance_id: str) -> Optional[Dict[str, Any]]:
    """
    Get session record from DynamoDB.

    Args:
        instance_id: EC2 instance ID

    Returns:
        Session record or None
    """
    try:
        response = dynamodb_client.get_item(
            TableName=DYNAMODB_TABLE,
            Key={'instance_id': {'S': instance_id}}
        )

        return response.get('Item')

    except Exception as e:
        logger.error(f"Error getting session record", extra={
            'instance_id': instance_id,
            'error': str(e)
        }, exc_info=True)
        return None


def update_session_record(instance_id: str, status: str, stopped_by: str):
    """
    Update session record in DynamoDB.

    Args:
        instance_id: EC2 instance ID
        status: Session status (stopped, active, idle)
        stopped_by: Who/what stopped the instance
    """
    try:
        now_ts = int(datetime.utcnow().timestamp())

        dynamodb_client.update_item(
            TableName=DYNAMODB_TABLE,
            Key={'instance_id': {'S': instance_id}},
            UpdateExpression='SET #status = :status, stopped_at = :stopped_at, stopped_by = :stopped_by',
            ExpressionAttributeNames={
                '#status': 'status'
            },
            ExpressionAttributeValues={
                ':status': {'S': status},
                ':stopped_at': {'N': str(now_ts)},
                ':stopped_by': {'S': stopped_by}
            }
        )

        logger.info(f"Updated session record", extra={
            'instance_id': instance_id,
            'status': status
        })

    except Exception as e:
        logger.error(f"Error updating session record", extra={
            'instance_id': instance_id,
            'error': str(e)
        }, exc_info=True)


def stop_instance(instance_id: str):
    """
    Stop EC2 instance.

    Args:
        instance_id: EC2 instance ID
    """
    try:
        response = ec2_client.stop_instances(
            InstanceIds=[instance_id]
        )

        logger.info(f"Instance stop initiated", extra={
            'instance_id': instance_id,
            'response': response['StoppingInstances']
        })

    except Exception as e:
        logger.error(f"Error stopping instance", extra={
            'instance_id': instance_id,
            'error': str(e)
        }, exc_info=True)
        raise


def send_shutdown_notification(instance: Dict[str, Any], reason: str):
    """
    Send SNS notification about instance shutdown.

    Args:
        instance: EC2 instance dictionary
        reason: Reason for shutdown
    """
    if not SNS_TOPIC_ARN:
        logger.info("No SNS topic configured, skipping notification")
        return

    try:
        instance_id = instance['InstanceId']
        instance_name = get_instance_name(instance)

        message = f"""
Bastion Instance Auto-Stopped

Environment: {ENVIRONMENT}
Instance ID: {instance_id}
Instance Name: {instance_name}
Reason: {reason}
Stopped At: {datetime.utcnow().isoformat()}

The bastion instance was automatically stopped after {IDLE_THRESHOLD_MINUTES} minutes of idle time.

To restart:
aws ec2 start-instances --instance-ids {instance_id} --region {AWS_REGION}

To connect:
aws ssm start-session --target {instance_id} --region {AWS_REGION}
"""

        sns_client.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"[{ENVIRONMENT}] Bastion Auto-Stopped: {instance_name}",
            Message=message
        )

        logger.info(f"Shutdown notification sent", extra={
            'instance_id': instance_id
        })

    except Exception as e:
        logger.error(f"Error sending notification", extra={
            'instance_id': instance['InstanceId'],
            'error': str(e)
        }, exc_info=True)


def get_instance_name(instance: Dict[str, Any]) -> str:
    """
    Get instance name from tags.

    Args:
        instance: EC2 instance dictionary

    Returns:
        Instance name or instance ID if no name tag
    """
    tags = instance.get('Tags', [])
    for tag in tags:
        if tag['Key'] == 'Name':
            return tag['Value']
    return instance['InstanceId']
