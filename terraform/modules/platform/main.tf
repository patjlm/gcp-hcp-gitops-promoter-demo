terraform {
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

resource "null_resource" "compute" {
  count = var.instance_count

  triggers = {
    environment    = var.environment
    region         = var.region
    instance_type  = var.instance_type
    instance_index = count.index
  }
}

resource "null_resource" "storage_bucket" {
  triggers = {
    environment         = var.environment
    region              = var.region
    storage_bucket_name = var.storage_bucket_name
  }
}

resource "null_resource" "networking" {
  triggers = {
    environment = var.environment
    region      = var.region
  }
}

resource "null_resource" "config_summary" {
  triggers = {
    environment       = var.environment
    region            = var.region
    instance_count    = var.instance_count
    enable_monitoring = var.enable_monitoring
  }
}
