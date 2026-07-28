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

locals {
  # Pinned to one subnet (and therefore one AZ) deliberately: the memory volume
  # below lives in a single AZ and can't follow the ASG across AZs, so the ASG
  # must only ever launch where that volume already is.
  subnet_id = data.aws_subnets.default.ids[0]
}

data "aws_subnet" "selected" {
  id = local.subnet_id
}

# --- AMI: Amazon Linux 2023, arm64, resolved via the public SSM parameter ---
# so this always picks up the latest patched image without pinning an AMI ID.

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# --- Security group: locked to your IP, egress limited to what the box actually needs ---

resource "aws_security_group" "agent" {
  name        = "${var.project_name}-sg"
  description = "Personal Hermes agent host: no inbound rules at all. Admin access goes over Tailscales private mesh; messaging goes over Telegram long polling. Both are outbound-initiated, so there is nothing to open inbound."
  vpc_id      = data.aws_vpc.default.id

  # No ingress rules, intentionally. There is no SSH-from-my-IP rule, no webhook
  # port, nothing. Admin access (SSH) rides over the tailscale0 interface once the
  # instance joins the tailnet (see user_data below); Tailscale itself doesn't
  # require an inbound security group rule to establish that tunnel — it either
  # punches through via UDP or falls back to relaying through its DERP network,
  # both of which look like outbound-initiated traffic from the instance's side.
  # This is what makes the whole design avoid needing a load balancer, API Gateway,
  # or NAT Gateway: there is no inbound path to protect or route in the first place.

  egress {
    description = "HTTPS out to OpenRouter, Telegram, Tailscale coordination, SSM, etc."
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

  # Optional but recommended: lets Tailscale attempt a direct UDP connection instead
  # of always relaying through DERP. Still egress-only, so it doesn't weaken the
  # "no inbound" posture — if this is ever blocked, Tailscale just falls back to
  # relaying over the 443 rule above and keeps working.
  egress {
    description = "Tailscale direct (UDP) connection attempts"
    from_port   = 41641
    to_port     = 41641
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
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
    sid     = "ReadSecrets"
    actions = ["ssm:GetParameter"]
    resources = [
      aws_ssm_parameter.openrouter_key.arn,
      aws_ssm_parameter.telegram_bot_token.arn,
      aws_ssm_parameter.tailscale_auth_key.arn,
      aws_ssm_parameter.brave_api_key.arn,
    ]
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

  # Session Manager fallback: lets you get a shell via `aws ssm start-session`
  # without any inbound security group rule, independent of whether the Tailscale
  # join in user_data succeeds. These are the core actions the SSM Agent needs to
  # register and open a session; none of them support resource-level scoping.
  # (Deliberately not the AWS managed AmazonSSMManagedInstanceCore policy — that
  # also grants S3/CloudWatch Logs access for session logging this project doesn't
  # use, so this statement lists only what Session Manager itself requires.)
  statement {
    sid = "SessionManagerCore"
    actions = [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
    ]
    resources = ["*"]
  }

  # Lets a freshly (re)launched instance find and attach the persistent memory
  # volume itself. The ASG below can replace the instance at any time, and a
  # statically-managed Terraform attachment can't follow a not-yet-known future
  # instance ID, so this has to happen at runtime in user_data instead.
  statement {
    sid       = "DescribeVolumesForAttach"
    actions   = ["ec2:DescribeVolumes"]
    resources = ["*"] # DescribeVolumes doesn't support resource-level scoping
  }

  statement {
    sid     = "AttachMemoryVolume"
    actions = ["ec2:AttachVolume"]
    resources = [
      aws_ebs_volume.memory.arn,
      "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
    ]
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

# --- Secrets: OpenRouter API key, Telegram bot token, Tailscale auth key, Brave Search API key ---

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

resource "aws_ssm_parameter" "telegram_bot_token" {
  name        = "/${var.project_name}/telegram-bot-token"
  description = "Telegram bot token used by the agent process to long-poll for updates."
  type        = "SecureString"
  value       = var.telegram_bot_token
  tags        = local.tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "tailscale_auth_key" {
  name        = "/${var.project_name}/tailscale-auth-key"
  description = "Tailscale auth key used to join the instance to the tailnet on first boot."
  type        = "SecureString"
  value       = var.tailscale_auth_key
  tags        = local.tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "brave_api_key" {
  name        = "/${var.project_name}/brave-api-key"
  description = "Brave Search API key used by the agent's web_search tool."
  type        = "SecureString"
  value       = var.brave_api_key
  tags        = local.tags

  lifecycle {
    ignore_changes = [value]
  }
}

# --- Compute: launch template + single-instance ASG for self-healing ---
# A plain aws_instance has no way to notice its own host has crashed or gone
# unreachable and relaunch itself — something outside it has to do that. An Auto
# Scaling Group with min=max=desired=1 does exactly that; it's not here for
# scaling out, it's a supervisor for one instance. This is why the memory volume
# is pinned to one subnet/AZ (see locals.subnet_id above): it protects against
# instance/host-level failures, not a full AZ outage — that would need the
# memory itself to live somewhere shared (EFS, a database), not a single EBS
# volume, which is a bigger change than this.

resource "aws_launch_template" "agent" {
  name_prefix   = "${var.project_name}-"
  image_id      = data.aws_ssm_parameter.al2023_arm64.value
  instance_type = var.instance_type
  key_name      = var.key_name

  iam_instance_profile {
    name = aws_iam_instance_profile.agent.name
  }

  # Auto-assigned public IP instead of an Elastic IP: costs $0 while the instance is
  # stopped, which is the whole point of the stop/start cost-saving pattern in infra.md.
  # Trade-off: the public IP changes on every stop/start and on every ASG-driven
  # replacement. This is fine here because nothing depends on it for inbound access —
  # it's only used for the instance's own outbound calls (OpenRouter, Telegram,
  # Tailscale, SSM), and admin access goes over the stable Tailscale IP instead.
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.agent.id]
    delete_on_termination       = true
  }

  # Require IMDSv2 (token-based metadata requests). user_data below already uses
  # the token flow, so this is a free hardening step, not a functional change.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  block_device_mappings {
    device_name = "/dev/xvda" # AL2023's registered root device name
    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size_gb
      encrypted             = true
      delete_on_termination = true # OS disk only — no memory lives here, safe to discard
    }
  }

  # Runs on first boot of every instance the ASG ever launches — a replacement gets
  # a fresh root volume, so this is no longer a one-time thing the way it was for a
  # single stop/start-able instance. Joins Tailscale, finds + attaches the persistent
  # memory volume (which doesn't come with a new instance automatically the way it
  # used to with a static Terraform-managed attachment), formats/mounts it on first
  # use, then installs and starts the actual Telegram/OpenRouter agent process.
  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tpl", {
    aws_region                = var.aws_region
    auth_key_param_name       = aws_ssm_parameter.tailscale_auth_key.name
    openrouter_key_param_name = aws_ssm_parameter.openrouter_key.name
    telegram_token_param_name = aws_ssm_parameter.telegram_bot_token.name
    brave_key_param_name      = aws_ssm_parameter.brave_api_key.name
    openrouter_model          = var.openrouter_model
    project_name              = var.project_name
    memory_volume_id          = aws_ebs_volume.memory.id
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.tags, {
      Name = "${var.project_name}-agent"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.tags
  }

  # Deliberately no disable_api_termination here, unlike the single-instance design
  # this replaces: the whole point of the ASG is to terminate and replace an
  # unhealthy instance automatically, and API termination protection would block
  # exactly that. The memory volume's own prevent_destroy + delete_on_termination
  # = false (below) is what actually protects your data, independent of this.
}

resource "aws_autoscaling_group" "agent" {
  name                      = "${var.project_name}-asg"
  min_size                  = 1
  max_size                  = 1
  desired_capacity          = 1
  vpc_zone_identifier       = [local.subnet_id]
  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.agent.id
    version = "$Latest"
  }

  dynamic "tag" {
    for_each = merge(local.tags, { Name = "${var.project_name}-agent" })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }
}

# Looks up whichever instance the ASG currently has running, purely so the outputs
# below can surface a usable instance ID/IP. Terraform doesn't otherwise expose a
# single instance's attributes from an ASG, since ASG membership is dynamic and can
# change (a health-check replacement) independently of any Terraform run.
data "aws_instances" "agent" {
  instance_tags = {
    Name = "${var.project_name}-agent"
  }
  instance_state_names = ["running"]

  depends_on = [aws_autoscaling_group.agent]
}

# --- Storage: the actual long-term memory volume, kept separate from the OS disk ---
# Attaching this as its own resource (rather than a second root_block_device) means it
# is never implicitly deleted when the instance is destroyed — that's what makes it
# survive `terraform destroy` of the instance, matching infra.md's DeleteOnTermination=false.

resource "aws_ebs_volume" "memory" {
  availability_zone = data.aws_subnet.selected.availability_zone
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

# No static aws_volume_attachment resource here anymore — with a plain aws_instance
# it could reference a fixed instance_id, but the ASG above can replace that instance
# at any time with one whose ID doesn't exist yet at plan time. Attachment happens at
# runtime instead, in the launch template's user_data (device /dev/sdf, which this
# Nitro-based instance type will expose as /dev/nvme1n1 or similar — use `nvme list`
# or check /dev/disk/by-id on the box rather than assuming /dev/xvdf).

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
  description        = "Daily snapshots of the agent memory volume retained ${var.snapshot_retention_days} days"
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
