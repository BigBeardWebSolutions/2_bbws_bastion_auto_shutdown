# Variables for Bastion Auto-Shutdown Lambda

variable "environment" {
  description = "Environment name (dev, sit, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
}

variable "idle_threshold_minutes" {
  description = "Idle timeout in minutes before auto-shutdown"
  type        = number
  default     = 30
}

variable "cpu_idle_threshold" {
  description = "CPU utilization percentage threshold (below = idle)"
  type        = number
  default     = 5.0
}

variable "network_idle_threshold" {
  description = "Network I/O bytes threshold (below = idle)"
  type        = number
  default     = 1000000  # 1MB
}

variable "alert_email" {
  description = "Email address for SNS notifications (optional)"
  type        = string
  default     = ""
}

variable "log_level" {
  description = "Lambda function log level (DEBUG, INFO, WARNING, ERROR)"
  type        = string
  default     = "INFO"
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
