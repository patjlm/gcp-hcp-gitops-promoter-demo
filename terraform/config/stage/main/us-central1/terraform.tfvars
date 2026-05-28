environment         = "stage"
region              = "us-central1"
instance_count      = 2
instance_type       = "medium"
storage_bucket_name = "gcp-hcp-stage-main-uc1"
enable_monitoring   = true
tags = {
  env    = "stage"
  sector = "main"
}
