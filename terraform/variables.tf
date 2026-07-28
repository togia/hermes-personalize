variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-west-2"
}

variable "project_name" {
  description = "Name prefix used to tag and identify all resources for this project."
  type        = string
  default     = "hermes-personalize"
}

variable "key_name" {
  description = "Name of an existing EC2 key pair to use for SSH access."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. t4g.micro is the recommended starting point; move to t4g.small if the memory store grows (e.g. a real vector DB)."
  type        = string
  default     = "t4g.micro"
}

variable "root_volume_size_gb" {
  description = "Size of the OS root volume in GB. This holds the OS only, not agent memory."
  type        = number
  default     = 8
}

variable "data_volume_size_gb" {
  description = "Size of the separate EBS data volume that holds long-term agent memory."
  type        = number
  default     = 20
}

variable "snapshot_retention_days" {
  description = "How many daily DLM snapshots of the data volume to retain."
  type        = number
  default     = 14
}

# No default: an OpenRouter key should never live in version control, tfvars files,
# or shell history. Pass it via TF_VAR_openrouter_api_key at apply time, then Terraform
# ignores drift on this value afterwards (see aws_ssm_parameter.openrouter_key lifecycle)
# so rotating the key by hand in the console/CLI doesn't get clobbered on the next apply.
variable "openrouter_api_key" {
  description = "OpenRouter API key, stored as a SecureString in SSM Parameter Store."
  type        = string
  sensitive   = true
}

# Same reasoning as openrouter_api_key above: never in tfvars or version control.
# Pass via TF_VAR_telegram_bot_token at apply time.
variable "telegram_bot_token" {
  description = "Telegram bot token (from @BotFather), stored as a SecureString in SSM Parameter Store. The agent process uses this for long-polling updates, so no inbound webhook is needed."
  type        = string
  sensitive   = true
}

# Same reasoning again. Pass via TF_VAR_tailscale_auth_key at apply time.
variable "tailscale_auth_key" {
  description = "Tailscale auth key used to join the instance to your tailnet on first boot, stored as a SecureString in SSM Parameter Store. This is what gives the instance a stable private IP for admin access, replacing IP-locked SSH."
  type        = string
  sensitive   = true
}

variable "budget_limit_usd" {
  description = "Monthly AWS Budget alert threshold in USD."
  type        = number
  default     = 15
}

variable "budget_alert_email" {
  description = "Email address to notify when the budget threshold is forecast to be exceeded or is exceeded."
  type        = string
}

variable "enable_cloudwatch_logs" {
  description = "Whether to create a CloudWatch Logs group and grant the instance role permission to write to it."
  type        = bool
  default     = true
}
