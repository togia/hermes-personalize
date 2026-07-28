# Terraform infrastructure

This directory provisions the architecture described in [../docs/infra.md](../docs/infra.md):
an EC2 t4g.micro host that calls the OpenRouter API and polls Telegram for messages,
with long-term memory on a separate encrypted EBS volume, daily snapshots, and a
security group with no inbound rules at all — admin access rides over Tailscale
instead of a locked-to-your-IP SSH rule.

Terraform loads these files together as one module; the diagram below shows how
values and resource references flow between them:

```text
  ┌──────────────────────────┐      copy and edit      ┌─────────────────────────┐
  │ terraform.tfvars.example │ ──────────────────────► │ terraform.tfvars        │
  └──────────────────────────┘                         │ local; ignored by Git   │
                                                       └────────────┬────────────┘
                                                                    │ values
  ┌──────────────────────────┐                                      │
  │ TF_VAR_openrouter_api_key│ ── secret value ─────────────────────┤
  └──────────────────────────┘                                      ▼
                                                       ┌─────────────────────────┐
  ┌──────────────────────────┐   provider and region   │ variables.tf            │
  │ versions.tf              │ ─────────────────────►  │ declared inputs/defaults│
  └────────────┬─────────────┘                         └────────────┬────────────┘
               │                                                    │ inputs
               │                                                    ▼
               │                                        ┌─────────────────────────┐
               └──────────────────────────────────────► │ main.tf                 │
                                                        │ reads AWS data; creates │
                                                        │ network, IAM, EC2, EBS, │
                                                        │ backups, and budget     │
                                                        └────────────┬────────────┘
                                                                     │ resource IDs
                                                                     ▼
                                                        ┌─────────────────────────┐
                                                        │ outputs.tf              │
                                                        │ prints IDs, IP, and SSH │
                                                        └─────────────────────────┘
```

| File | Contents |
|---|---|
| `versions.tf` | Terraform/provider version pins (`hashicorp/aws ~> 5.0`) |
| `variables.tf` | Inputs: EC2 key pair name, instance/volume sizing, OpenRouter key / Telegram bot token / Tailscale auth key (all sensitive), budget alert email, etc. No IP variable — there's no IP-locked rule left to configure. |
| `main.tf` | The resources: security group with **no ingress rules**, IAM instance role + SSM/KMS/CloudWatch/Session Manager permissions, SSM SecureStrings for the OpenRouter key/Telegram token/Tailscale auth key, EC2 instance (AL2023 arm64) with `user_data` that joins Tailscale on first boot, separate EBS volume + attachment for memory, DLM daily-snapshot policy, AWS Budget alert |
| `outputs.tf` | Instance ID, public IP (outbound use only), instructions for finding the instance's Tailscale IP for SSH, a ready-to-use Session Manager fallback command, memory volume ID, SSM parameter names |
| `terraform.tfvars.example` | Template for the values you need to fill in |
| `.terraform.lock.hcl` | Provider version lock — commit this, it's not a secret |

> Looking for the account sign-ups (OpenRouter, Telegram, Tailscale) that these
> variables' values come from? See
> [Step 1 in the top-level README](../README.md#1-gather-your-accounts-and-keys) —
> gather those first, this file assumes you already have them.

## Variables

| Variable | Required? | Description |
|---|---|---|
| `key_name` | **Yes** | Name of an existing EC2 key pair to use for SSH access. Create one in the AWS Console or with `aws ec2 create-key-pair` first. |
| `budget_alert_email` | **Yes** | Email address notified when spend crosses the budget threshold. |
| `openrouter_api_key` | **Yes** (passed as an env var, not in `.tfvars`) | Your OpenRouter API key, stored as a SecureString in SSM Parameter Store. Never commit this or put it in `terraform.tfvars`, see below. |
| `telegram_bot_token` | **Yes** (passed as an env var, not in `.tfvars`) | Your Telegram bot token from [@BotFather](https://t.me/BotFather), stored as a SecureString in SSM Parameter Store. Used for long polling, so no inbound webhook is required. |
| `tailscale_auth_key` | **Yes** (passed as an env var, not in `.tfvars`) | A [Tailscale auth key](https://tailscale.com/kb/1085/auth-keys) used to join the instance to your tailnet on first boot, stored as a SecureString in SSM Parameter Store. This is what gives you a stable IP for admin access no matter where you're connecting from. |
| `aws_region` | No (default `eu-west-2`) | AWS region to deploy into. |
| `project_name` | No (default `hermes-personalize`) | Name prefix used to tag and identify all resources. |
| `instance_type` | No (default `t4g.micro`) | EC2 instance type. Move to `t4g.small` if the memory store grows (e.g. a real vector DB). |
| `root_volume_size_gb` | No (default `8`) | OS root volume size, holds the OS only, not agent memory. |
| `data_volume_size_gb` | No (default `20`) | Size of the separate EBS volume that holds long-term agent memory. |
| `snapshot_retention_days` | No (default `14`) | How many daily snapshots of the memory volume to retain. |
| `budget_limit_usd` | No (default `15`) | Monthly AWS Budget alert threshold in USD. |
| `enable_cloudwatch_logs` | No (default `true`) | Whether to create a CloudWatch Logs group for the agent process. |

## Usage

1. `cp terraform.tfvars.example terraform.tfvars` and fill in `key_name` and
   `budget_alert_email`. **Do not** put any of the three secrets below in this file.
2. `terraform init`
3. Review the plan, passing all three secrets only as environment variables so none
   of them are written to `terraform.tfvars`:
   ```
   TF_VAR_openrouter_api_key="sk-or-..." \
   TF_VAR_telegram_bot_token="123456:ABC-your-botfather-token" \
   TF_VAR_tailscale_auth_key="tskey-auth-..." \
   terraform plan
   ```
4. If it looks right, `apply` with the same three variables set.

`terraform.tfvars`, `*.tfstate`, and `.terraform/` are gitignored — never commit them.

To rotate any of the three secrets later, update them directly in SSM Parameter Store
(console or `aws ssm put-parameter --overwrite`) rather than via Terraform — each
parameter's `lifecycle.ignore_changes` is set so `terraform apply` won't stomp on a
manual rotation. Note that rotating the Tailscale auth key in SSM has no effect on an
already-running instance — it's only read once, in `user_data`, on first boot. It
matters if the instance is ever replaced (not just stopped/started).
