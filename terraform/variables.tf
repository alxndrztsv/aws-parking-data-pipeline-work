# Define input variables used throughout Terraform configuration

variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
}

variable "project_name" {
  description = "Name of project, used for resource naming."
  type        = string

  validation {
    condition     = length(var.project_name) > 0
    error_message = "Must not be empty: it is part of every resource name."
  }
}

variable "environment" {
  description = "Environment (e.g., dev, staging, prod)."
  type        = string

  validation {
    condition     = length(var.environment) > 0
    error_message = "Must not be empty: it is part of every resource name."
  }
}

variable "sender_email" {
  description = "Email address to send reports from (must be verified in SES)."
  type        = string

  validation {
    condition     = can(regex("^[\\w-\\.]+@([\\w-]+\\.)+[\\w-]{2,4}$", var.sender_email))
    error_message = "Must be a valid email address."
  }
}

variable "recipient_email" {
  description = "Email address to receive reports."
  type        = string

  validation {
    condition     = can(regex("^[\\w-\\.]+@([\\w-]+\\.)+[\\w-]{2,4}$", var.recipient_email))
    error_message = "Must be a valid email address."
  }
}

variable "failure_notification_email" {
  description = "Email address for pipeline alerts"
  type        = string

  validation {
    condition     = can(regex("^[\\w-\\.]+@([\\w-]+\\.)+[\\w-]{2,4}$", var.failure_notification_email))
    error_message = "Must be a valid email address."
  }
}

variable "api_login" {
  description = "API login username"
  type        = string
  sensitive   = true
}

variable "api_password" {
  description = "API password"
  type        = string
  sensitive   = true
}

variable "api_url" {
  description = "API endpoint URL"
  type        = string
}

variable "max_receive_count" {
  description = "Maximum number of times SQS will retry a message before sending to DLQ"
  type        = string
  default     = 4
}
