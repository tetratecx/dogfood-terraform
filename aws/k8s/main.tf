data "aws_region" "current" {}

resource "aws_vpc" "tsb" {
  cidr_block           = var.cidr
  enable_dns_hostnames = true
  tags = merge(var.tags, {
    Name = "${var.name_prefix}_vpc"
  })
}

data "aws_availability_zones" "available" {}

resource "aws_subnet" "tsb" {
  count                   = min(length(data.aws_availability_zones.available.names), var.min_az_count, var.max_az_count)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  cidr_block              = cidrsubnet(var.cidr, 4, count.index)
  vpc_id                  = aws_vpc.tsb.id
  map_public_ip_on_launch = "true"
  tags = merge(var.tags, {
  Name = "${var.name_prefix}_subnet_${data.aws_availability_zones.available.names[count.index]}", "kubernetes.io/role/elb" = 1, "kubernetes.io/role/internal-elb" = 1 })
}

resource "aws_internet_gateway" "tsb" {
  vpc_id = aws_vpc.tsb.id
  tags = merge(var.tags, {
    Name = "${var.name_prefix}_igw"
  })
}


resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.tsb.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.tsb.id
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}_rt"
  })
}


resource "aws_route_table_association" "rta" {
  count          = min(length(data.aws_availability_zones.available.names), var.min_az_count, var.max_az_count)
  subnet_id      = element(aws_subnet.tsb.*.id, count.index)
  route_table_id = aws_route_table.rt.id
}


data "aws_availability_zones" "available" {}
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name                    = var.cluster_name
  cluster_version                 = var.k8s_version
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true
  create_cloudwatch_log_group     = false

  vpc_id     = aws_vpc.tsb.id
  subnet_ids = aws_subnet.tsb.*.id

  eks_managed_node_group_defaults = {
    disk_size      = 50
    instance_types = [var.instance_type]
    iam_role_additional_policies = {
      AmazonEBSCSIDriverPolicy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    }

    tags = merge(var.tags, {
      Name = "${var.name_prefix}_default"
    })
  }

  cluster_addons = {
    coredns = {
      most_recent       = true
      resolve_conflicts = "OVERWRITE"
    }
    kube-proxy = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
      configuration_values = jsonencode({
        "controller" = {
          "extraVolumeTags" = var.tags
        }
      })
    }
    vpc-cni = {
      most_recent       = true
      resolve_conflicts = "OVERWRITE"
    }
  }

  eks_managed_node_groups = {
    tsb_sandbox_blue = {
      min_size     = 2
      max_size     = 7
      desired_size = 2
    }
  }

  cluster_security_group_additional_rules = {
    egress_nodes_ephemeral_ports_tcp = {
      description                = "all"
      protocol                   = "-1"
      from_port                  = 0
      to_port                    = 0
      type                       = "egress"
      source_node_security_group = true
    }

    inress_ec2_tcp = {
      description                   = "Access EKS externally"
      protocol                      = "tcp"
      from_port                     = 443
      to_port                       = 443
      type                          = "ingress"
      cidr_blocks                   = ["0.0.0.0/0"]
      source_cluster_security_group = false
    }

  }

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      cidr_blocks = ["0.0.0.0/0"]
    }
    egress_all = {
      description = "Node all egress"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}"
  })

  putin_khuylo = true

  create_aws_auth_configmap = false
  manage_aws_auth_configmap = true
}

data "aws_eks_cluster_auth" "cluster" {
  name = var.cluster_name
}

# Workaround for aws-auth configmap detection: https://github.com/terraform-aws-modules/terraform-aws-eks/issues/2525 
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "/bin/sh"
    args        = ["-c", "for i in $(seq 1 30); do curl -s -k -f ${module.eks.cluster_endpoint}/healthz > /dev/null && break || sleep 10; done && aws eks --region ${data.aws_availability_zones.available.id} get-token --cluster-name ${var.cluster_name}"]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "/bin/sh"
      args        = ["-c", "for i in $(seq 1 30); do curl -s -k -f ${module.eks.cluster_endpoint}/healthz > /dev/null && break || sleep 10; done && aws eks --region ${data.aws_availability_zones.available.id} get-token --cluster-name ${var.cluster_name}"]
    }
  }
}

module "load_balancer_controller" {
  source                           = "git::https://github.com/smarunich/terraform-aws-eks-lb-controller.git"
  helm_chart_version               = var.lb_controller_helm_chart_version
  cluster_identity_oidc_issuer     = module.eks.cluster_oidc_issuer_url
  cluster_identity_oidc_issuer_arn = module.eks.oidc_provider_arn
  cluster_name                     = var.cluster_name
  settings                         = var.lb_controller_settings
}

module "eks-cluster-autoscaler" {
  source            = "lablabs/eks-cluster-autoscaler/aws"
  enabled           = true
  argo_enabled      = false
  argo_helm_enabled = false

  cluster_name                     = var.cluster_name
  cluster_identity_oidc_issuer     = module.eks.cluster_oidc_issuer_url
  cluster_identity_oidc_issuer_arn = module.eks.oidc_provider_arn
  helm_release_name                = var.cluster_name
  irsa_role_name_prefix            = var.cluster_name
}

resource "kubernetes_annotations" "default-storageclass" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  force       = "true"

  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "true"
  }
}

