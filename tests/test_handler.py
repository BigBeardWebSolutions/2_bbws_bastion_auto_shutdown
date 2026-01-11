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
        # Default: low CPU usage (idle)
        mock_client.get_metric_statistics.return_value = {
            'Datapoints': [
                {'Average': 2.5, 'Timestamp': datetime.utcnow() - timedelta(minutes=5)},
                {'Average': 1.8, 'Timestamp': datetime.utcnow() - timedelta(minutes=10)},
                {'Average': 3.2, 'Timestamp': datetime.utcnow() - timedelta(minutes=15)}
            ]
        }
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
        # Import handler after mocks are set up
        with patch('boto3.client') as mock_boto3:
            def client_factory(service_name, **kwargs):
                clients = {
                    'ec2': mock_ec2_client,
                    'cloudwatch': mock_cloudwatch_client,
                    'dynamodb': mock_dynamodb_client,
                    'ssm': mock_ssm_client,
                    'sns': mock_sns_client
                }
                return clients.get(service_name)

            mock_boto3.side_effect = client_factory

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

        with patch('boto3.client') as mock_boto3:
            def client_factory(service_name, **kwargs):
                clients = {
                    'ec2': mock_ec2_client,
                    'cloudwatch': mock_cloudwatch_client,
                    'dynamodb': mock_dynamodb_client,
                    'ssm': mock_ssm_client,
                    'sns': mock_sns_client
                }
                return clients.get(service_name)

            mock_boto3.side_effect = client_factory

            from src.handler import lambda_handler

            event = {}
            context = Mock()
            result = lambda_handler(event, context)

            # Assertions
            assert result['statusCode'] == 200
            assert 'active' in result['body'].lower() or 'not idle' in result['body'].lower()

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

        with patch('boto3.client') as mock_boto3:
            def client_factory(service_name, **kwargs):
                clients = {
                    'ec2': mock_ec2_client,
                    'cloudwatch': mock_cloudwatch_client,
                    'dynamodb': mock_dynamodb_client,
                    'ssm': mock_ssm_client,
                    'sns': mock_sns_client
                }
                return clients.get(service_name)

            mock_boto3.side_effect = client_factory

            from src.handler import lambda_handler

            event = {}
            context = Mock()
            result = lambda_handler(event, context)

            # Assertions
            assert result['statusCode'] == 200
            assert 'active session' in result['body'].lower() or 'ssm' in result['body'].lower()

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

        with patch('boto3.client') as mock_boto3:
            def client_factory(service_name, **kwargs):
                clients = {
                    'ec2': mock_ec2_client,
                    'cloudwatch': mock_cloudwatch_client,
                    'dynamodb': mock_dynamodb_client,
                    'ssm': mock_ssm_client,
                    'sns': mock_sns_client
                }
                return clients.get(service_name)

            mock_boto3.side_effect = client_factory

            from src.handler import lambda_handler

            event = {}
            context = Mock()
            result = lambda_handler(event, context)

            # Assertions
            assert result['statusCode'] == 200
            assert 'stopped' in result['body'].lower() or 'skipped' in result['body'].lower()

            # Verify EC2 stop was NOT called (already stopped)
            mock_ec2_client.stop_instances.assert_not_called()

    def test_high_cpu_usage_not_stopped(self, mock_ec2_client, mock_cloudwatch_client,
                                        mock_dynamodb_client, mock_ssm_client, mock_sns_client):
        """Test that bastion with high CPU usage is NOT stopped"""
        # Setup: high CPU usage
        mock_cloudwatch_client.get_metric_statistics.return_value = {
            'Datapoints': [
                {'Average': 45.0, 'Timestamp': datetime.utcnow() - timedelta(minutes=5)},
                {'Average': 52.3, 'Timestamp': datetime.utcnow() - timedelta(minutes=10)},
                {'Average': 38.7, 'Timestamp': datetime.utcnow() - timedelta(minutes=15)}
            ]
        }

        with patch('boto3.client') as mock_boto3:
            def client_factory(service_name, **kwargs):
                clients = {
                    'ec2': mock_ec2_client,
                    'cloudwatch': mock_cloudwatch_client,
                    'dynamodb': mock_dynamodb_client,
                    'ssm': mock_ssm_client,
                    'sns': mock_sns_client
                }
                return clients.get(service_name)

            mock_boto3.side_effect = client_factory

            from src.handler import lambda_handler

            event = {}
            context = Mock()
            result = lambda_handler(event, context)

            # Assertions
            assert result['statusCode'] == 200
            assert 'active' in result['body'].lower() or 'high cpu' in result['body'].lower()

            # Verify EC2 stop was NOT called
            mock_ec2_client.stop_instances.assert_not_called()

    def test_error_handling_no_instances(self, mock_ec2_client, mock_cloudwatch_client,
                                         mock_dynamodb_client, mock_ssm_client, mock_sns_client):
        """Test graceful handling when no bastion instances found"""
        # Setup: no instances
        mock_ec2_client.describe_instances.return_value = {'Reservations': []}

        with patch('boto3.client') as mock_boto3:
            def client_factory(service_name, **kwargs):
                clients = {
                    'ec2': mock_ec2_client,
                    'cloudwatch': mock_cloudwatch_client,
                    'dynamodb': mock_dynamodb_client,
                    'ssm': mock_ssm_client,
                    'sns': mock_sns_client
                }
                return clients.get(service_name)

            mock_boto3.side_effect = client_factory

            from src.handler import lambda_handler

            event = {}
            context = Mock()
            result = lambda_handler(event, context)

            # Assertions
            assert result['statusCode'] == 200
            assert 'no instances' in result['body'].lower() or 'not found' in result['body'].lower()

    def test_error_handling_boto3_exception(self, mock_ec2_client, mock_cloudwatch_client,
                                            mock_dynamodb_client, mock_ssm_client, mock_sns_client):
        """Test error handling for AWS API exceptions"""
        # Setup: EC2 API exception
        mock_ec2_client.describe_instances.side_effect = Exception("AWS API Error")

        with patch('boto3.client') as mock_boto3:
            def client_factory(service_name, **kwargs):
                clients = {
                    'ec2': mock_ec2_client,
                    'cloudwatch': mock_cloudwatch_client,
                    'dynamodb': mock_dynamodb_client,
                    'ssm': mock_ssm_client,
                    'sns': mock_sns_client
                }
                return clients.get(service_name)

            mock_boto3.side_effect = client_factory

            from src.handler import lambda_handler

            event = {}
            context = Mock()
            result = lambda_handler(event, context)

            # Assertions
            assert result['statusCode'] == 500
            assert 'error' in result['body'].lower()


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
