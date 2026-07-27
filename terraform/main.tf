locals {
  tags = {
    Project   = var.project_name
    ManagedBy = "terraform"
  }
}

data "aws_caller_identity" "current" {}

# --- Networking: use the account's default VPC/subnet, not a dedicated one ---
# A personal single-instance box doesn't justify the cost/complexity of a custom VPC.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# --- AMI: Amazon Linux 2023, arm64, resolved via the public SSM parameter ---
# so this always picks up the latest patched image without pinning an AMI ID.

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# --- Security group: locked to your IP, egress limited to what the box actually needs ---

resource "aws_security_group" "agent" {
  name        = "${var.project_name}-sg"
  description = "Personal Hermes agent host: SSH and outbound HTTPS only, all locked to one IP."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from your IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    description = "HTTPS out to OpenRouter, SSM, etc."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # DNS resolution for the VPC's Amazon-provided resolver. Without this, the 443 rule
  # above is unreachable because the instance can never resolve a hostname to connect to.
  egress {
    description = "DNS to the VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }

  tags = local.tags
}

# --- IAM: instance role scoped to exactly what infra.md calls for, nothing else ---

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agent" {
  name               = "${var.project_name}-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = local.tags
}

# SSM SecureString parameters are encrypted with the AWS-managed alias/aws/ssm key by
# default, so the instance role needs kms:Decrypt on it, not just ssm:GetParameter.
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

data "aws_iam_policy_document" "agent_permissions" {
  statement {
    sid       = "ReadOpenRouterKey"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.openrouter_key.arn]
  }

  statement {
    sid       = "DecryptSsmSecureString"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.ssm.target_key_arn]
  }

  statement {
    sid       = "BasicMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.enable_cloudwatch_logs ? [1] : []
    content {
      sid = "AgentLogs"
      actions = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      resources = ["${aws_cloudwatch_log_group.agent[0].arn}:*"]
    }
  }
}

resource "aws_iam_role_policy" "agent" {
  name   = "${var.project_name}-instance-policy"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent_permissions.json
}

resource "aws_iam_instance_profile" "agent" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.agent.name
}

resource "aws_cloudwatch_log_group" "agent" {
  count             = var.enable_cloudwatch_logs ? 1 : 0
  name              = "/${var.project_name}/agent"
  retention_in_days = 30
  tags              = local.tags
}

# --- Secret: OpenRouter API key ---

resource "aws_ssm_parameter" "openrouter_key" {
  name        = "/${var.project_name}/openrouter-api-key"
  description = "OpenRouter API key used by the agent process."
  type        = "SecureString"
  value       = var.openrouter_api_key
  tags        = local.tags

  # Lets you rotate the key by hand (console/CLI) without `terraform apply` reverting it
  # back to whatever was last passed in as a variable.
  lifecycle {
    ignore_changes = [value]
  }
}

# --- Compute ---

resource "aws_instance" "agent" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.agent.id]
  iam_instance_profile   = aws_iam_instance_profile.agent.name
  key_name               = var.key_name

  # Auto-assigned public IP instead of an Elastic IP: costs $0 while the instance is
  # stopped, which is the whole point of the stop/start cost-saving pattern in infra.md.
  # Trade-off: the public IP changes on every stop/start.
  associate_public_ip_address = true

  # Cheap insurance against the most common way people lose an EBS volume: terminating
  # the instance without realizing the attached data volume goes with it by default.
  disable_api_termination = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true # OS disk only — no memory lives here, safe to discard
  }

  tags = merge(local.tags, {
    Name = "${var.project_name}-agent"
  })
}

# --- Storage: the actual long-term memory volume, kept separate from the OS disk ---
# Attaching this as its own resource (rather than a second root_block_device) means it
# is never implicitly deleted when the instance is destroyed — that's what makes it
# survive `terraform destroy` of the instance, matching infra.md's DeleteOnTermination=false.

resource "aws_ebs_volume" "memory" {
  availability_zone = aws_instance.agent.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = merge(local.tags, {
    Name   = "${var.project_name}-memory"
    Backup = "true" # matched by the DLM target_tags below
  })

  # Requires `terraform destroy -target` gymnastics (or removing this block first) to
  # actually delete the memory volume — that friction is intentional, not a bug.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "memory" {
  # /dev/sdf is the conventional attach point Terraform/the API expects; on this
  # Nitro-based instance type the OS will actually expose it as /dev/nvme1n1 or similar —
  # use `nvme list` or check /dev/disk/by-id on the box rather than assuming /dev/xvdf.
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.memory.id
  instance_id = aws_instance.agent.id
}

# --- Snapshots: the actual safety net for the memory volume ---

data "aws_iam_policy_document" "dlm_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${var.project_name}-dlm-role"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "memory_snapshots" {
  description        = "Daily snapshots of the agent memory volume, retained ${var.snapshot_retention_days} days."
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Backup = "true"
    }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }

      retain_rule {
        count = var.snapshot_retention_days
      }

      tags_to_add = {
        SnapshotOf = "${var.project_name}-memory"
      }

      copy_tags = true
    }
  }

  tags = local.tags
}

# --- Cost guardrail ---

resource "aws_budgets_budget" "monthly" {
  name         = "${var.project_name}-monthly-budget"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
