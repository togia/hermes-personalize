# Terraform infrastructure

This directory provisions the architecture described in [../docs/infra.md](../docs/infra.md):
an EC2 t4g.micro host that calls the OpenRouter API, with long-term memory on a
separate encrypted EBS volume, daily snapshots, and access locked to your IP.

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
| `variables.tf` | Inputs: your IP, EC2 key pair name, instance/volume sizing, OpenRouter key (sensitive), budget alert email, etc. |
| `main.tf` | The resources: security group, IAM instance role + SSM/KMS/CloudWatch permissions, SSM SecureString for the OpenRouter key, EC2 instance (AL2023 arm64), separate EBS volume + attachment for memory, DLM daily-snapshot policy, AWS Budget alert |
| `outputs.tf` | Instance ID, public IP, a ready-to-use SSH command, memory volume ID, SSM parameter name |
| `terraform.tfvars.example` | Template for the values you need to fill in |
| `.terraform.lock.hcl` | Provider version lock — commit this, it's not a secret |

## Usage

1. `cp terraform.tfvars.example terraform.tfvars` and fill in `my_ip_cidr`, `key_name`,
   and `budget_alert_email`. **Do not** put the OpenRouter key in this file.
2. `terraform init`
3. Review the plan, passing the OpenRouter key only as an environment variable so it
   is not written to `terraform.tfvars`:
   ```
   TF_VAR_openrouter_api_key="sk-or-..." terraform plan
   ```
4. If it looks right:
   ```
   TF_VAR_openrouter_api_key="sk-or-..." terraform apply
   ```

`terraform.tfvars`, `*.tfstate`, and `.terraform/` are gitignored — never commit them.

To rotate the OpenRouter key later, update it directly in SSM Parameter Store (console
or `aws ssm put-parameter --overwrite`) rather than via Terraform — the parameter's
`lifecycle.ignore_changes` is set so `terraform apply` won't stomp on a manual rotation.
