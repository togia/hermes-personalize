output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.agent.id
}

output "public_ip" {
  description = "Current public IP of the instance. Changes on every stop/start since there's no Elastic IP."
  value       = aws_instance.agent.public_ip
}

output "ssh_command" {
  description = "Convenience SSH command using the current public IP."
  value       = "ssh -i <path-to-${var.key_name}.pem> ec2-user@${aws_instance.agent.public_ip}"
}

output "memory_volume_id" {
  description = "EBS volume ID holding long-term agent memory."
  value       = aws_ebs_volume.memory.id
}

output "openrouter_parameter_name" {
  description = "SSM Parameter Store name for the OpenRouter API key."
  value       = aws_ssm_parameter.openrouter_key.name
}
