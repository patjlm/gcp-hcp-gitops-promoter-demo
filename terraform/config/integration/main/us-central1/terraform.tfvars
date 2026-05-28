environment         = "integration"
region              = "us-central1"
instance_count      = 1
instance_type       = "small"
storage_bucket_name = "gcp-hcp-int-main-uc1"
enable_monitoring   = false
tags = {
  env    = "integration"
  sector = "main"
}
