output "instance_id" {
  description = "Current EC2 instance ID managed by the ASG. Can change if the ASG ever replaces the instance — re-run `terraform apply` (or `terraform refresh`) to update this, or just check the AWS console/CLI directly, since Terraform has no way to know about a replacement that happened outside a Terraform run."
  value       = try(data.aws_instances.agent.ids[0], "none running — check the ASG in the console")
}

output "public_ip" {
  description = "Current public IP of the running instance, used only for its own outbound calls (OpenRouter, Telegram, Tailscale, SSM) — not for admin access. Changes on every stop/start and on every ASG replacement since there's no Elastic IP; same staleness caveat as instance_id above."
  value       = try(data.aws_instances.agent.public_ips[0], "none running — check the ASG in the console")
}

output "ssh_instructions" {
  description = "How to reach the instance for admin access: over its stable Tailscale IP, not the (changing) public IP above."
  value       = "Find the Tailscale IP for '${var.project_name}-agent' via `tailscale status` or the Tailscale admin console, then: ssh -i <path-to-${var.key_name}.pem> ec2-user@<tailscale-ip>"
}

output "session_manager_command" {
  description = "Fallback shell access via AWS Systems Manager, no ingress rule and no Tailscale dependency required. Looks up the current instance live (rather than baking in an ID from Terraform state) since the ASG can replace it at any time — this keeps working even if Terraform's state is stale."
  value       = "aws ssm start-session --target $(aws ec2 describe-instances --filters Name=tag:Name,Values=${var.project_name}-agent Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].InstanceId' --output text --region ${var.aws_region}) --region ${var.aws_region}"
}

output "memory_volume_id" {
  description = "EBS volume ID holding long-term agent memory."
  value       = aws_ebs_volume.memory.id
}

output "openrouter_parameter_name" {
  description = "SSM Parameter Store name for the OpenRouter API key."
  value       = aws_ssm_parameter.openrouter_key.name
}

output "telegram_parameter_name" {
  description = "SSM Parameter Store name for the Telegram bot token."
  value       = aws_ssm_parameter.telegram_bot_token.name
}

output "tailscale_parameter_name" {
  description = "SSM Parameter Store name for the Tailscale auth key."
  value       = aws_ssm_parameter.tailscale_auth_key.name
}
