# Nous Hermes agent on AWS

## Viewing the infra diagram in VS Code

1. Install the [Draw.io Integration](https://marketplace.visualstudio.com/items?itemName=hediet.vscode-drawio) extension (`hediet.vscode-drawio`).
2. Open `infra-diagram.drawio` — it renders and edits directly in the editor tab.

## Terraform

`terraform/` provisions the architecture proposed in `infra.md`: an EC2 t4g.micro host
that calls the OpenRouter API, with its long-term memory on a separate encrypted EBS
volume, daily snapshots, and everything locked down to your IP.

| File | Contents |
|---|---|
| `versions.tf` | Terraform/provider version pins (`hashicorp/aws ~> 5.0`) |
| `variables.tf` | Inputs: your IP, EC2 key pair name, instance/volume sizing, OpenRouter key (sensitive), budget alert email, etc. |
| `main.tf` | The resources: security group, IAM instance role + SSM/KMS/CloudWatch permissions, SSM SecureString for the OpenRouter key, EC2 instance (AL2023 arm64), separate EBS volume + attachment for memory, DLM daily-snapshot policy, AWS Budget alert |
| `outputs.tf` | Instance ID, public IP, a ready-to-use SSH command, memory volume ID, SSM parameter name |
| `terraform.tfvars.example` | Template for the values you need to fill in |
| `.terraform.lock.hcl` | Provider version lock — commit this, it's not a secret |

### Usage

1. `cd terraform`
2. `cp terraform.tfvars.example terraform.tfvars` and fill in `my_ip_cidr`, `key_name`,
   and `budget_alert_email`. **Do not** put the OpenRouter key in this file.
3. `terraform init`
4. Review the plan, passing the OpenRouter key only as an environment variable so it
   never touches disk or shell history in a recoverable way:
   ```
   TF_VAR_openrouter_api_key="sk-or-..." terraform plan
   ```
5. If it looks right:
   ```
   TF_VAR_openrouter_api_key="sk-or-..." terraform apply
   ```

`terraform.tfvars`, `*.tfstate`, and `.terraform/` are gitignored — never commit them.

To rotate the OpenRouter key later, update it directly in SSM Parameter Store (console
or `aws ssm put-parameter --overwrite`) rather than via Terraform — the parameter's
`lifecycle.ignore_changes` is set so `terraform apply` won't stomp on a manual rotation.