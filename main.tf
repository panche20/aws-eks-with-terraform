terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {}
}

locals {
  cluster_name = "${var.project}-${var.environment}"
  name_prefix  = "${var.project}-${var.environment}"
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags { tags = local.common_tags }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = ["eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
    "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = ["eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
      "--region", var.aws_region]
    }
  }
}

module "vpc" {
  source       = "./modules/vpc"
  name         = local.name_prefix
  cidr         = var.vpc_cidr
  azs          = var.azs
  cluster_name = local.cluster_name
  tags         = local.common_tags
}

module "eks" {
  source              = "./modules/eks"
  cluster_name        = local.cluster_name
  kubernetes_version  = var.kubernetes_version
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  private_subnet_ids  = module.vpc.private_subnet_ids
  node_instance_types = var.node_instance_types
  capacity_type       = var.capacity_type
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  environment         = var.environment
  tags                = local.common_tags
}

module "irsa" {
  source            = "./modules/irsa"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  environment       = var.environment
  tags              = local.common_tags
}

module "addons" {
  source                  = "./modules/addons"
  cluster_name            = module.eks.cluster_name
  cluster_endpoint        = module.eks.cluster_endpoint
  cluster_ca_certificate  = module.eks.cluster_ca_certificate
  aws_region              = var.aws_region
  vpc_id                  = module.vpc.vpc_id
  alb_controller_role_arn = module.irsa.alb_controller_role_arn
  ebs_csi_role_arn        = module.irsa.ebs_csi_role_arn
  tags                    = local.common_tags
  depends_on              = [module.eks]
}

resource "kubernetes_namespace" "url_shortener" {
  metadata {
    name = "url-shortener"
    labels = {
      environment = var.environment
      managed-by  = "terraform"
    }
  }
  depends_on = [module.eks]
}

resource "helm_release" "url_shortener" {
  name      = "url-shortener"
  chart     = "${path.module}/helm/url-shortener"
  namespace = kubernetes_namespace.url_shortener.metadata[0].name

  set {
    name  = "app.image"
    value = "ghcr.io/${var.github_user}/url-shortener"
  }

  set {
    name  = "app.tag"
    value = var.app_image_tag
  }

  depends_on = [module.addons]
}
