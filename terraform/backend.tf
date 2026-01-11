# Terraform Backend Configuration
# S3 backend for remote state storage

terraform {
  backend "s3" {
    # Backend configuration is provided via -backend-config flags in GitHub Actions
    # For local development, create a backend-config file:
    #
    # bucket         = "bbws-lambda-terraform-state-dev"
    # key            = "bastion-auto-shutdown/terraform.tfstate"
    # region         = "eu-west-1"
    # encrypt        = true
    # dynamodb_table = "terraform-state-lock"  # Optional: for state locking
  }
}
