environment         = "production"
region              = "europe-west1"
instance_count      = 3
instance_type       = "large"
storage_bucket_name = "gcp-hcp-prod-2-ew1"
enable_monitoring   = true
tags = {
  env    = "production"
  sector = "prod-2"
}
