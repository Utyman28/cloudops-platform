terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ca-central-1"
}

locals {
  repo_owner = "Utyman28"
  repo_name  = "cloudops-platform"
  branch     = "main"

  state_bucket = "cloudops-platform-utyman28-dev-ca-central-1-tfstate"
  lock_table   = "cloudops-platform-utyman28-dev-ca-central-1-tflock"
}

# 1) OIDC Provider (one per AWS account)
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # commonly used GitHub Actions OIDC thumbprint
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# 2) Trust policy: ONLY your repo on main branch
data "aws_iam_policy_document" "gha_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [
        "repo:${local.repo_owner}/${local.repo_name}:ref:refs/heads/${local.branch}"
      ]
    }
  }
}

resource "aws_iam_role" "gha_role" {
  name               = "github-actions-cloudops-dev"
  assume_role_policy = data.aws_iam_policy_document.gha_trust.json
}

# 3) Permissions: exactly what CI needs for backend + read-only describe
data "aws_iam_policy_document" "gha_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket"
    ]
    resources = [
      "arn:aws:s3:::${local.state_bucket}"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = [
      "arn:aws:s3:::${local.state_bucket}/*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem"
    ]
    resources = [
      "arn:aws:dynamodb:ca-central-1:*:table/${local.lock_table}"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity",
      "ec2:Describe*",
      "iam:Get*",
      "iam:List*",
      "eks:DescribeCluster"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "gha_policy" {
  name   = "github-actions-cloudops-dev-policy"
  policy = data.aws_iam_policy_document.gha_permissions.json
}

resource "aws_iam_role_policy_attachment" "attach" {
  role       = aws_iam_role.gha_role.name
  policy_arn = aws_iam_policy.gha_policy.arn
}

output "gha_role_arn" {
  value = aws_iam_role.gha_role.arn
}

