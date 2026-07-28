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
