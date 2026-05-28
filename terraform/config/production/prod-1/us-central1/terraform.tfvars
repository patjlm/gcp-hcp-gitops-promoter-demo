environment         = "production"
region              = "us-central1"
instance_count      = 3
instance_type       = "large"
storage_bucket_name = "gcp-hcp-prod-1-uc1"
enable_monitoring   = true
tags = {
  env    = "production"
  sector = "prod-1"
}
