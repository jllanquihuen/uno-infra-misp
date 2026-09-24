output "instance_id" {
  description = "EC2 instance ID of the MISP host."
  value       = aws_instance.misp.id
}

output "private_ip" {
  description = "Private IP of the MISP host."
  value       = aws_instance.misp.private_ip
}

output "public_ip" {
  description = "Public IP of the MISP host (null when assign_public_ip = false)."
  value       = aws_instance.misp.public_ip
}

output "security_group_id" {
  description = "Security group ID attached to the instance."
  value       = aws_security_group.misp.id
}

output "iam_role_arn" {
  description = "IAM role ARN assumed by the instance (ECR pull + Secrets Manager read + SSM)."
  value       = aws_iam_role.misp.arn
}

output "data_volume_id" {
  description = "EBS data volume ID (null when data_volume_size_gb = 0)."
  value       = var.data_volume_size_gb > 0 ? aws_ebs_volume.data[0].id : null
}

output "ssm_start_session_command" {
  description = "Command to open an interactive shell on the instance via SSM (no SSH required)."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.misp.id}"
}
