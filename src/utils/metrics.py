"""
CloudWatch metrics helper utility for Lambda functions.
"""

import boto3
from datetime import datetime, timedelta
from typing import List, Dict, Any


class MetricsHelper:
    """Helper class for CloudWatch metrics operations"""

    def __init__(self):
        self.cloudwatch = boto3.client('cloudwatch')

    def get_instance_cpu_usage(self, instance_id: str, minutes: int = 30) -> float:
        """
        Get average CPU usage for instance over specified period.

        Args:
            instance_id: EC2 instance ID
            minutes: Number of minutes to look back

        Returns:
            Average CPU utilization percentage
        """
        end_time = datetime.utcnow()
        start_time = end_time - timedelta(minutes=minutes)

        response = self.cloudwatch.get_metric_statistics(
            Namespace='AWS/EC2',
            MetricName='CPUUtilization',
            Dimensions=[
                {'Name': 'InstanceId', 'Value': instance_id}
            ],
            StartTime=start_time,
            EndTime=end_time,
            Period=300,  # 5-minute periods
            Statistics=['Average']
        )

        datapoints = response.get('Datapoints', [])
        if not datapoints:
            return 0.0

        # Calculate average of all datapoints
        total = sum(dp['Average'] for dp in datapoints)
        return total / len(datapoints)

    def get_instance_network_io(self, instance_id: str, minutes: int = 30) -> Dict[str, float]:
        """
        Get network I/O metrics for instance.

        Args:
            instance_id: EC2 instance ID
            minutes: Number of minutes to look back

        Returns:
            Dictionary with 'network_in' and 'network_out' in bytes
        """
        end_time = datetime.utcnow()
        start_time = end_time - timedelta(minutes=minutes)

        # Get NetworkIn
        network_in_response = self.cloudwatch.get_metric_statistics(
            Namespace='AWS/EC2',
            MetricName='NetworkIn',
            Dimensions=[
                {'Name': 'InstanceId', 'Value': instance_id}
            ],
            StartTime=start_time,
            EndTime=end_time,
            Period=300,
            Statistics=['Sum']
        )

        # Get NetworkOut
        network_out_response = self.cloudwatch.get_metric_statistics(
            Namespace='AWS/EC2',
            MetricName='NetworkOut',
            Dimensions=[
                {'Name': 'InstanceId', 'Value': instance_id}
            ],
            StartTime=start_time,
            EndTime=end_time,
            Period=300,
            Statistics=['Sum']
        )

        network_in_datapoints = network_in_response.get('Datapoints', [])
        network_out_datapoints = network_out_response.get('Datapoints', [])

        network_in = sum(dp['Sum'] for dp in network_in_datapoints) if network_in_datapoints else 0.0
        network_out = sum(dp['Sum'] for dp in network_out_datapoints) if network_out_datapoints else 0.0

        return {
            'network_in': network_in,
            'network_out': network_out,
            'total': network_in + network_out
        }

    def is_instance_idle(self, instance_id: str, cpu_threshold: float = 5.0,
                        network_threshold: float = 1_000_000,  # 1MB
                        minutes: int = 30) -> bool:
        """
        Determine if instance is idle based on metrics.

        Args:
            instance_id: EC2 instance ID
            cpu_threshold: CPU usage percentage threshold (below = idle)
            network_threshold: Network I/O bytes threshold (below = idle)
            minutes: Number of minutes to analyze

        Returns:
            True if instance is idle, False otherwise
        """
        cpu_usage = self.get_instance_cpu_usage(instance_id, minutes)
        network_io = self.get_instance_network_io(instance_id, minutes)

        is_cpu_idle = cpu_usage < cpu_threshold
        is_network_idle = network_io['total'] < network_threshold

        return is_cpu_idle and is_network_idle

    def put_custom_metric(self, namespace: str, metric_name: str, value: float,
                         unit: str = 'Count', dimensions: List[Dict[str, str]] = None):
        """
        Put custom metric to CloudWatch.

        Args:
            namespace: Metric namespace
            metric_name: Metric name
            value: Metric value
            unit: Metric unit
            dimensions: List of dimension dicts
        """
        metric_data = {
            'MetricName': metric_name,
            'Value': value,
            'Unit': unit,
            'Timestamp': datetime.utcnow()
        }

        if dimensions:
            metric_data['Dimensions'] = dimensions

        self.cloudwatch.put_metric_data(
            Namespace=namespace,
            MetricData=[metric_data]
        )
