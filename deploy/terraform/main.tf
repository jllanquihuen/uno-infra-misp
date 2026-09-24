locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Separate data volume attaches at this device; user-data formats/mounts it.
  data_device_name = "/dev/xvdf"
  # On Nitro instances the block device surfaces as an NVMe path; user-data
  # checks for a block device before formatting so this hint is best-effort.
  data_device_hint = var.data_volume_size_gb > 0 ? "/dev/nvme1n1" : ""
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
    repo_url         = var.repo_url
    repo_branch      = var.repo_branch
    data_device_hint = local.data_device_hint
  })

  tags = {
    Name = "${local.name_prefix}"
  }
}

# -----------------------------------------------------------------------------
# Optional separate data volume for MISP persistent data
# -----------------------------------------------------------------------------
resource "aws_ebs_volume" "data" {
  count = var.data_volume_size_gb > 0 ? 1 : 0

  availability_zone = aws_instance.misp.availability_zone
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
