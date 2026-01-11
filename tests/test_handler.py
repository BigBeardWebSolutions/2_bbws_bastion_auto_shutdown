"""
Unit Tests for Bastion Auto-Shutdown Lambda Function
Test-Driven Development (TDD) approach
"""

import json
import pytest
from datetime import datetime, timedelta
from unittest.mock import Mock, patch, MagicMock
from decimal import Decimal


# Mock the modules before importing handler
@pytest.fixture(autouse=True)
def mock_aws_modules():
    """Auto-use fixture to mock AWS SDK modules"""
    with patch('boto3.client'):
        yield


class TestBastionAutoShutdown:
    """Test cases for bastion auto-shutdown Lambda function"""

    @pytest.fixture
    def mock_ec2_client(self):
        """Mock EC2 client"""
        mock_client = Mock()
        mock_client.describe_instances.return_value = {
            'Reservations': [{
                'Instances': [{
                    'InstanceId': 'i-1234567890abcdef0',
                    'State': {'Name': 'running'},
                    'Tags': [
                        {'Key': 'Environment', 'Value': 'dev'},
                        {'Key': 'ManagedBy', 'Value': 'bastion-auto-shutdown'},
                        {'Key': 'IdleTimeout', 'Value': '30'}
                    ]
                }]
            }]
        }
        mock_client.describe_instance_status.return_value = {
            'InstanceStatuses': [{
                'InstanceId': 'i-1234567890abcdef0',
                'InstanceState': {'Name': 'running'}
            }]
        }
        mock_client.stop_instances.return_value = {
            'StoppingInstances': [{
                'InstanceId': 'i-1234567890abcdef0',
                'CurrentState': {'Name': 'stopping'},
                'PreviousState': {'Name': 'running'}
            }]
        }
        return mock_client

    @pytest.fixture
    def mock_cloudwatch_client(self):
        """Mock CloudWatch client"""
        mock_client = Mock()

        def get_metric_statistics_side_effect(**kwargs):
            """Return appropriate mock data based on metric name"""
            metric_name = kwargs.get('MetricName')

            if metric_name == 'CPUUtilization':
                # Default: low CPU usage (idle)
                return {
                    'Datapoints': [
                        {'Average': 2.5, 'Timestamp': datetime.utcnow() - timedelta(minutes=5)},
                        {'Average': 1.8, 'Timestamp': datetime.utcnow() - timedelta(minutes=10)},
                        {'Average': 3.2, 'Timestamp': datetime.utcnow() - timedelta(minutes=15)}
                    ]
                }
            elif metric_name in ['NetworkIn', 'NetworkOut']:
                # Low network I/O (idle)
                return {
                    'Datapoints': [
                        {'Sum': 1000.0, 'Timestamp': datetime.utcnow() - timedelta(minutes=5)},
                        {'Sum': 800.0, 'Timestamp': datetime.utcnow() - timedelta(minutes=10)},
                        {'Sum': 1200.0, 'Timestamp': datetime.utcnow() - timedelta(minutes=15)}
                    ]
                }
            return {'Datapoints': []}

        mock_client.get_metric_statistics.side_effect = get_metric_statistics_side_effect
        return mock_client

    @pytest.fixture
    def mock_dynamodb_client(self):
        """Mock DynamoDB client"""
        mock_client = Mock()
        mock_client.get_item.return_value = {
            'Item': {
                'instance_id': {'S': 'i-1234567890abcdef0'},
                'session_start': {'N': str(int((datetime.utcnow() - timedelta(minutes=45)).timestamp()))},
                'last_activity': {'N': str(int((datetime.utcnow() - timedelta(minutes=35)).timestamp()))},
                'status': {'S': 'idle'},
                'environment': {'S': 'dev'}
            }
        }
        mock_client.update_item.return_value = {}
        return mock_client

    @pytest.fixture
    def mock_ssm_client(self):
        """Mock SSM client for session checking"""
        mock_client = Mock()
        # Default: no active sessions
        mock_client.describe_sessions.return_value = {
            'Sessions': []
        }
        return mock_client

    @pytest.fixture
    def mock_sns_client(self):
        """Mock SNS client"""
        mock_client = Mock()
        mock_client.publish.return_value = {
            'MessageId': '12345678-1234-1234-1234-123456789012'
        }
        return mock_client

    def test_idle_bastion_gets_stopped(self, mock_ec2_client, mock_cloudwatch_client,
                                       mock_dynamodb_client, mock_ssm_client, mock_sns_client):
        """Test that idle bastion (>30 min) gets stopped"""
        # Patch the module-level clients in src.handler
        with patch('src.handler.ec2_client', mock_ec2_client), \
             patch('src.handler.cloudwatch_client', mock_cloudwatch_client), \
             patch('src.handler.dynamodb_client', mock_dynamodb_client), \
             patch('src.handler.ssm_client', mock_ssm_client), \
             patch('src.handler.sns_client', mock_sns_client), \
             patch('src.handler.metrics_helper.cloudwatch', mock_cloudwatch_client), \
             patch('src.handler.SNS_TOPIC_ARN', 'arn:aws:sns:eu-west-1:123456789012:test-topic'):

            from src.handler import lambda_handler

            # Execute Lambda
            event = {}
            context = Mock()
            context.aws_request_id = 'test-request-123'

            result = lambda_handler(event, context)

            # Assertions
            assert result['statusCode'] == 200
            assert 'stopped' in result['body'].lower()

            # Verify EC2 stop was called
            mock_ec2_client.stop_instances.assert_called_once()

            # Verify DynamoDB was updated
            mock_dynamodb_client.update_item.assert_called()

            # Verify SNS notification sent
            mock_sns_client.publish.assert_called_once()

    def test_active_bastion_not_stopped(self, mock_ec2_client, mock_cloudwatch_client,
                                        mock_dynamodb_client, mock_ssm_client, mock_sns_client):
        """Test that active bastion with recent activity is NOT stopped"""
        # Setup: recent activity
        mock_dynamodb_client.get_item.return_value = {
            'Item': {
                'instance_id': {'S': 'i-1234567890abcdef0'},
                'last_activity': {'N': str(int((datetime.utcnow() - timedelta(minutes=5)).timestamp()))},
                'status': {'S': 'active'},
                'environment': {'S': 'dev'}
            }
        }

        with patch('src.handler.ec2_client', mock_ec2_client), \
             patch('src.handler.cloudwatch_client', mock_cloudwatch_client), \
             patch('src.handler.dynamodb_client', mock_dynamodb_client), \
             patch('src.handler.ssm_client', mock_ssm_client), \
             patch('src.handler.sns_client', mock_sns_client), \
             patch('src.handler.metrics_helper.cloudwatch', mock_cloudwatch_client):

            from src.handler import lambda_handler

            event = {}
            context = Mock()
            context.aws_request_id = 'test-request-456'
            result = lambda_handler(event, context)

            # Assertions
            assert result['statusCode'] == 200
            result_body = json.loads(result['body'])
            assert result_body['results'][0]['action'] == 'kept_running'

            # Verify EC2 stop was NOT called
            mock_ec2_client.stop_instances.assert_not_called()

            # Verify SNS notification NOT sent
            mock_sns_client.publish.assert_not_called()

    def test_bastion_with_active_ssm_session_not_stopped(self, mock_ec2_client, mock_cloudwatch_client,
                                                          mock_dynamodb_client, mock_ssm_client, mock_sns_client):
        """Test that bastion with active SSM session is NOT stopped"""
        # Setup: active SSM session
        mock_ssm_client.describe_sessions.return_value = {
            'Sessions': [{
                'SessionId': 'session-123',
                'Target': 'i-1234567890abcdef0',
                'Status': 'Connected',
                'StartDate': datetime.utcnow() - timedelta(minutes=20)
            }]
        }

        with patch('src.handler.ec2_client', mock_ec2_client), \
             patch('src.handler.cloudwatch_client', mock_cloudwatch_client), \
             patch('src.handler.dynamodb_client', mock_dynamodb_client), \
             patch('src.handler.ssm_client', mock_ssm_client), \
             patch('src.handler.sns_client', mock_sns_client), \
             patch('src.handler.metrics_helper.cloudwatch', mock_cloudwatch_client):

            from src.handler import lambda_handler

            event = {}
            context = Mock()
            context.aws_request_id = 'test-request-789'
            result = lambda_handler(event, context)

            # Assertions
            assert result['statusCode'] == 200
            result_body = json.loads(result['body'])
            assert result_body['results'][0]['action'] == 'kept_running'
            assert 'ssm' in result_body['results'][0]['reason'].lower()

            # Verify EC2 stop was NOT called
            mock_ec2_client.stop_instances.assert_not_called()

    def test_stopped_bastion_skipped(self, mock_ec2_client, mock_cloudwatch_client,
                                     mock_dynamodb_client, mock_ssm_client, mock_sns_client):
        """Test that already stopped bastion is skipped"""
        # Setup: stopped instance
        mock_ec2_client.describe_instances.return_value = {
            'Reservations': [{
                'Instances': [{
                    'InstanceId': 'i-1234567890abcdef0',
                    'State': {'Name': 'stopped'},
                    'Tags': [
                        {'Key': 'Environment', 'Value': 'dev'},
                        {'Key': 'ManagedBy', 'Value': 'bastion-auto-shutdown'}
                    ]
                }]
            }]
        }

        with patch('src.handler.ec2_client', mock_ec2_client), \
             patch('src.handler.cloudwatch_client', mock_cloudwatch_client), \
             patch('src.handler.dynamodb_client', mock_dynamodb_client), \
             patch('src.handler.ssm_client', mock_ssm_client), \
             patch('src.handler.sns_client', mock_sns_client), \
             patch('src.handler.metrics_helper.cloudwatch', mock_cloudwatch_client):

            from src.handler import lambda_handler

            event = {}
            context = Mock()
            context.aws_request_id = 'test-request-101'
            result = lambda_handler(event, context)

            # Assertions
            assert result['statusCode'] == 200
            result_body = json.loads(result['body'])
            assert result_body['results'][0]['action'] == 'skipped'
            assert result_body['results'][0]['reason'] == 'already_stopped'

            # Verify EC2 stop was NOT called (already stopped)
            mock_ec2_client.stop_instances.assert_not_called()

    def test_high_cpu_usage_not_stopped(self, mock_ec2_client, mock_cloudwatch_client,
                                        mock_dynamodb_client, mock_ssm_client, mock_sns_client):
        """Test that bastion with high CPU usage is NOT stopped"""
        # Setup: high CPU usage
        def high_cpu_side_effect(**kwargs):
            """Return high CPU and normal network metrics"""
            metric_name = kwargs.get('MetricName')

            if metric_name == 'CPUUtilization':
                return {
                    'Datapoints': [
                        {'Average': 45.0, 'Timestamp': datetime.utcnow() - timedelta(minutes=5)},
                        {'Average': 52.3, 'Timestamp': datetime.utcnow() - timedelta(minutes=10)},
                        {'Average': 38.7, 'Timestamp': datetime.utcnow() - timedelta(minutes=15)}
                    ]
                }
            elif metric_name in ['NetworkIn', 'NetworkOut']:
                return {
                    'Datapoints': [
                        {'Sum': 1000.0, 'Timestamp': datetime.utcnow() - timedelta(minutes=5)},
                        {'Sum': 800.0, 'Timestamp': datetime.utcnow() - timedelta(minutes=10)}
                    ]
                }
            return {'Datapoints': []}

        mock_cloudwatch_client.get_metric_statistics.side_effect = high_cpu_side_effect

        with patch('src.handler.ec2_client', mock_ec2_client), \
             patch('src.handler.cloudwatch_client', mock_cloudwatch_client), \
             patch('src.handler.dynamodb_client', mock_dynamodb_client), \
             patch('src.handler.ssm_client', mock_ssm_client), \
             patch('src.handler.sns_client', mock_sns_client), \
             patch('src.handler.metrics_helper.cloudwatch', mock_cloudwatch_client):

            from src.handler import lambda_handler

            event = {}
            context = Mock()
            context.aws_request_id = 'test-request-202'
            result = lambda_handler(event, context)

            # Assertions
            assert result['statusCode'] == 200
            result_body = json.loads(result['body'])
            assert result_body['results'][0]['action'] == 'kept_running'
            assert 'cpu' in result_body['results'][0]['reason'].lower()

            # Verify EC2 stop was NOT called
            mock_ec2_client.stop_instances.assert_not_called()

    def test_error_handling_no_instances(self, mock_ec2_client, mock_cloudwatch_client,
                                         mock_dynamodb_client, mock_ssm_client, mock_sns_client):
        """Test graceful handling when no bastion instances found"""
        # Setup: no instances
        mock_ec2_client.describe_instances.return_value = {'Reservations': []}

        with patch('src.handler.ec2_client', mock_ec2_client), \
             patch('src.handler.cloudwatch_client', mock_cloudwatch_client), \
             patch('src.handler.dynamodb_client', mock_dynamodb_client), \
             patch('src.handler.ssm_client', mock_ssm_client), \
             patch('src.handler.sns_client', mock_sns_client), \
             patch('src.handler.metrics_helper.cloudwatch', mock_cloudwatch_client):

            from src.handler import lambda_handler

            event = {}
            context = Mock()
            context.aws_request_id = 'test-request-303'
            result = lambda_handler(event, context)

            # Assertions
            assert result['statusCode'] == 200
            result_body = json.loads(result['body'])
            assert 'no managed bastion instances found' in result_body['message'].lower()

    def test_error_handling_boto3_exception(self, mock_ec2_client, mock_cloudwatch_client,
                                            mock_dynamodb_client, mock_ssm_client, mock_sns_client):
        """Test error handling for AWS API exceptions"""
        # Setup: EC2 API exception
        mock_ec2_client.describe_instances.side_effect = Exception("AWS API Error")

        with patch('src.handler.ec2_client', mock_ec2_client), \
             patch('src.handler.cloudwatch_client', mock_cloudwatch_client), \
             patch('src.handler.dynamodb_client', mock_dynamodb_client), \
             patch('src.handler.ssm_client', mock_ssm_client), \
             patch('src.handler.sns_client', mock_sns_client), \
             patch('src.handler.metrics_helper.cloudwatch', mock_cloudwatch_client):

            from src.handler import lambda_handler

            event = {}
            context = Mock()
            context.aws_request_id = 'test-request-404'
            result = lambda_handler(event, context)

            # Assertions
            assert result['statusCode'] == 500
            result_body = json.loads(result['body'])
            assert 'error' in result_body


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
