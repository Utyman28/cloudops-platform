terraform {
  backend "s3" {
    bucket         = "cloudops-platform-utyman28-dev-ca-central-1-tfstate"
    key            = "env/dev/terraform.tfstate"
    region         = "ca-central-1"
    dynamodb_table = "cloudops-platform-utyman28-dev-ca-central-1-tflock"
    encrypt        = true
  }
}
