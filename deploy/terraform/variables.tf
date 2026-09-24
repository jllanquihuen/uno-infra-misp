# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region where the isolated MISP instance is deployed."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name, used for tagging and resource naming."
  type        = string
  default     = "uno-infra-misp"
}

variable "environment" {
  description = "Environment label (e.g. prod, staging) for tagging/naming."
  type        = string
  default     = "prod"
}

# -----------------------------------------------------------------------------
# Networking (reuse EXISTING VPC/subnet - this module does not create a VPC)
# -----------------------------------------------------------------------------
variable "vpc_id" {
  description = "ID of an existing VPC where the instance and security group live."
  type        = string
}

variable "subnet_id" {
  description = "ID of an existing subnet for the instance. Use a private subnet if fronting with an ALB; a public subnet if the instance needs a direct public IP."
  type        = string
}

variable "assign_public_ip" {
  description = "Whether to assign a public IP to the instance. Keep false for private subnets fronted by an ALB or accessed via SSM."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# Instance sizing
# -----------------------------------------------------------------------------
variable "instance_type" {
  description = "EC2 instance type. MISP core + PECL + workers + MariaDB buffer pool need memory; t3.xlarge (4 vCPU / 16 GB) matches what was validated."
  type        = string
  default     = "t3.xlarge"
}

variable "root_volume_size_gb" {
  description = "Size of the root EBS volume in GiB (OS + container images)."
  type        = number
  default     = 50
}

variable "data_volume_size_gb" {
  description = "Size of the separate data EBS volume in GiB for MISP persistent data (MariaDB, files, gnupg). Set to 0 to disable and keep everything on the root volume."
  type        = number
  default     = 100
}

# -----------------------------------------------------------------------------
# Access: SSM (default) and optional SSH
# -----------------------------------------------------------------------------
variable "enable_ssh" {
  description = "Open SSH (22) ingress. Prefer SSM Session Manager (always enabled via IAM) and keep this false."
  type        = bool
  default     = false
}

variable "ssh_ingress_cidrs" {
  description = "CIDR blocks allowed to reach SSH when enable_ssh = true. Never use 0.0.0.0/0 in production."
  type        = list(string)
  default     = []
}

variable "key_name" {
  description = "Optional EC2 key pair name for SSH. Leave empty to rely on SSM only."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Application ingress (HTTP/HTTPS to MISP)
# -----------------------------------------------------------------------------
variable "allowed_https_cidrs" {
  description = "CIDR blocks allowed to reach MISP on 443. Restrict to corporate/VPN ranges. If fronting with an ALB, set this to the ALB security group range or the VPC CIDR."
  type        = list(string)
  default     = []
}

variable "enable_http" {
  description = "Also open port 80 (typically only for an HTTP->HTTPS redirect). MISP itself serves HTTPS."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# IAM: ECR pull + Secrets Manager read scoping
# -----------------------------------------------------------------------------
variable "ecr_repository_arns" {
  description = "ARNs of ECR repositories the instance may pull MISP images from. Use [\"*\"] to allow any repo in the account (less strict)."
  type        = list(string)
  default     = ["*"]
}

variable "secrets_manager_arns" {
  description = "ARNs of Secrets Manager secrets the instance may read (DB/Redis/GPG/SMTP). Scope this to the specific MISP secrets in production."
  type        = list(string)
  default     = ["*"]
}

# -----------------------------------------------------------------------------
# Bootstrap
# -----------------------------------------------------------------------------
variable "repo_url" {
  description = "Git URL of this repository, cloned by user-data so provision.sh/deploy.sh are present on the instance."
  type        = string
  default     = "https://github.com/unoafp/uno-infra-misp.git"
}

variable "repo_branch" {
  description = "Git branch to check out during bootstrap."
  type        = string
  default     = "main"
}
