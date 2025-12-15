provider "aws" {
  region = "ca-central-1"
}

module "vpc" {
  source = "../../modules/vpc"
  name   = "cloudops-dev"
  cidr   = "10.0.0.0/16"
}

module "eks" {
  source = "../../modules/eks"

  name               = "cloudops-dev-eks"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  kubernetes_version  = "1.30"
  node_instance_types = ["t3.medium"]
  desired_size        = 2
  min_size            = 1
  max_size            = 3
}
