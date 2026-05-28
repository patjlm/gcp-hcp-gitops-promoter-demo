terraform {
  required_version = ">= 1.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
  # Real backend would be:
  # backend "gcs" {
  #   bucket = "gcp-hcp-prod-terraform-state"
  #   prefix = "platform/prod-1/us-central1"
  # }
}

module "platform" {
  source = "../../../../modules/platform"

  environment         = var.environment
  region              = var.region
  instance_count      = var.instance_count
  instance_type       = var.instance_type
  storage_bucket_name = var.storage_bucket_name
  enable_monitoring   = var.enable_monitoring
  tags                = var.tags
}

variable "environment" { type = string }
variable "region" { type = string }
variable "instance_count" { type = number }
variable "instance_type" { type = string }
variable "storage_bucket_name" { type = string }
variable "enable_monitoring" { type = bool }
variable "tags" { type = map(string) }
