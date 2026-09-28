locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Requested attach point. On Nitro the kernel may expose it under a different
  # NVMe name; user-data discovers the real device by EBS volume-id (NVMe serial)
  # and mounts by filesystem UUID, so this name is only the requested hint to AWS.
  data_device_name = "/dev/sdf"

  # Security group of the ALB allowed to reach the instance on 443:
  # the one this module creates (enable_alb) takes precedence, otherwise an
  # existing SG passed via alb_security_group_id, otherwise none.
  alb_source_sg_id = var.enable_alb ? aws_security_group.alb[0].id : var.alb_security_group_id
}

# -----------------------------------------------------------------------------
# AMI: latest Canonical Ubuntu 24.04 LTS (amd64, HVM, EBS gp3-capable)
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu_2404" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# -----------------------------------------------------------------------------
# Security group
# -----------------------------------------------------------------------------
resource "aws_security_group" "misp" {
  name        = "${local.name_prefix}-sg"
  description = "Isolated MISP host: HTTPS in, all out, optional SSH/HTTP."
  vpc_id      = var.vpc_id

  tags = {
    Name = "${local.name_prefix}-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each = toset(var.allowed_https_cidrs)

  security_group_id = aws_security_group.misp.id
  description       = "MISP HTTPS"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each = var.enable_http ? toset(var.allowed_https_cidrs) : toset([])

  security_group_id = aws_security_group.misp.id
  description       = "MISP HTTP (redirect)"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

# Preferred production path: allow 443 to the instance ONLY from the ALB's
# security group (by reference), not from CIDRs. Uses the ALB SG created by this
# module (when enable_alb=true) or an existing one passed via alb_security_group_id.
resource "aws_vpc_security_group_ingress_rule" "https_from_alb" {
  count = local.alb_source_sg_id != "" ? 1 : 0

  security_group_id            = aws_security_group.misp.id
  description                  = "MISP HTTPS from ALB"
  referenced_security_group_id = local.alb_source_sg_id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = var.enable_ssh ? toset(var.ssh_ingress_cidrs) : toset([])

  security_group_id = aws_security_group.misp.id
  description       = "SSH (prefer SSM instead)"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = aws_security_group.misp.id
  description       = "Allow all outbound (image pulls, MISP feeds, Secrets Manager)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# -----------------------------------------------------------------------------
# IAM: instance role with SSM + scoped ECR pull + Secrets Manager read
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "misp" {
  name               = "${local.name_prefix}-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = {
    Name = "${local.name_prefix}-role"
  }
}

# SSM Session Manager access (no inbound SSH needed).
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.misp.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ECR: auth token is account-wide; pull actions scoped to the given repos.
data "aws_iam_policy_document" "ecr" {
  statement {
    sid       = "EcrAuthToken"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "ecr" {
  name   = "${local.name_prefix}-ecr-pull"
  role   = aws_iam_role.misp.id
  policy = data.aws_iam_policy_document.ecr.json
}

# Secrets Manager: read-only, scoped to the MISP secrets.
data "aws_iam_policy_document" "secrets" {
  statement {
    sid = "SecretsRead"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = var.secrets_manager_arns
  }
}

resource "aws_iam_role_policy" "secrets" {
  name   = "${local.name_prefix}-secrets-read"
  role   = aws_iam_role.misp.id
  policy = data.aws_iam_policy_document.secrets.json
}

resource "aws_iam_instance_profile" "misp" {
  name = "${local.name_prefix}-profile"
  role = aws_iam_role.misp.name
}

# -----------------------------------------------------------------------------
# EC2 instance
# -----------------------------------------------------------------------------
resource "aws_instance" "misp" {
  ami                         = data.aws_ami.ubuntu_2404.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.misp.id]
  iam_instance_profile        = aws_iam_instance_profile.misp.name
  associate_public_ip_address = var.assign_public_ip
  key_name                    = var.key_name != "" ? var.key_name : null

  # Enforce IMDSv2.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
    tags = {
      Name = "${local.name_prefix}-root"
    }
  }

  user_data = templatefile("${path.module}/user-data.sh.tpl", {
    repo_url            = var.repo_url
    repo_branch         = var.repo_branch
    data_volume_enabled = var.data_volume_size_gb > 0 ? "1" : "0"
    data_volume_id      = var.data_volume_size_gb > 0 ? aws_ebs_volume.data[0].id : ""
  })

  tags = {
    Name = "${local.name_prefix}"
  }
}

# -----------------------------------------------------------------------------
# Optional separate data volume for MISP persistent data
# -----------------------------------------------------------------------------
# AZ comes from the subnet (not the instance) so the volume does not depend on
# the instance - this lets us pass the volume-id into the instance user-data
# without creating a dependency cycle.
data "aws_subnet" "selected" {
  id = var.subnet_id
}

resource "aws_ebs_volume" "data" {
  count = var.data_volume_size_gb > 0 ? 1 : 0

  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${local.name_prefix}-data"
  }
}

resource "aws_volume_attachment" "data" {
  count = var.data_volume_size_gb > 0 ? 1 : 0

  device_name = local.data_device_name
  volume_id   = aws_ebs_volume.data[0].id
  instance_id = aws_instance.misp.id
}
