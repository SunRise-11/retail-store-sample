data "aws_eks_cluster_auth" "this" {
  name = module.eks_cluster.eks_cluster_id
}

data "aws_availability_zones" "available" {}

data "aws_region" "current" {}
