variable "environment" {
  description = "Deployment environment (integration, stage, production)"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "instance_count" {
  description = "Number of compute instances"
  type        = number
  default     = 1
}

variable "instance_type" {
  description = "Instance type (small, medium, large)"
  type        = string
  default     = "small"
}

variable "storage_bucket_name" {
  description = "Name of the storage bucket"
  type        = string
}

variable "enable_monitoring" {
  description = "Enable monitoring stack"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
