output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_ids" {
  value = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_oidc_issuer" {
  value = module.eks.cluster_oidc_issuer
}

output "eks_oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}
