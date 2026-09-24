provider "aws" {
  region = var.aws_region

  # Applied to every taggable resource created by this module so the isolated
  # MISP stack is easy to identify and cost-track.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "misp"
    }
  }
}
