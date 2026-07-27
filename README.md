# Hermes Personalize

A personal, always-remembering AI agent: a small always-available AWS host that
talks to the **Nous Hermes** model via the [OpenRouter](https://openrouter.ai) API,
keeps a durable long-term memory of your conversations, and — eventually — is
reachable from WhatsApp so you can talk to it like a contact rather than a web app.

## Why this exists

Most chat-with-an-LLM setups are stateless: close the tab and the model forgets
you. This project's goal is the opposite — a lightweight agent that:

- **Remembers you across sessions.** Conversation history and context persist on
  durable storage, not in a browser tab or a container that gets recycled.
- **Is cheap to run.** No GPU, no dedicated inference server — the model itself
  runs on OpenRouter's infrastructure and is billed separately by them. The AWS
  side is just a small orchestration host plus storage, on the order of
  $4–14/month (see [docs/infra.md](./docs/infra.md) for the breakdown).
- **Is reachable where you already are.** The end goal is a WhatsApp number you
  can message, backed by this agent and its memory, rather than a bespoke UI.

The infrastructure and its rationale are documented in full in
[docs/infra.md](./docs/infra.md), with a visual architecture diagram at
[docs/infra.drawio](./docs/infra.drawio) (rendered automatically to
[docs/export/infra.svg](./docs/export/infra.svg) by CI):

![Infrastructure diagram](./docs/export/infra.svg)

## 1. Provisioning the infrastructure

The Terraform in [terraform/](./terraform) provisions everything needed to run
the agent host: an EC2 instance, a separate encrypted EBS volume for long-term
memory, daily snapshots, IAM scoped to least privilege, and a budget alert. Full
details on each file are in [terraform/README.md](./terraform/README.md); the
essentials are below.

### Variables you need to supply

| Variable | Required? | Description |
|---|---|---|
| `my_ip_cidr` | **Yes** | Your public IP in CIDR form (e.g. `203.0.113.4/32`, from `curl ifconfig.me`). SSH and any exposed app port are locked to this — the instance is not meant to be reachable from the wider internet. |
| `key_name` | **Yes** | Name of an existing EC2 key pair to use for SSH access. Create one in the AWS Console or with `aws ec2 create-key-pair` first. |
| `budget_alert_email` | **Yes** | Email address notified when spend crosses the budget threshold. |
| `openrouter_api_key` | **Yes** (passed as an env var, not in `.tfvars`) | Your OpenRouter API key, stored as a SecureString in SSM Parameter Store. Never commit this or put it in `terraform.tfvars` — see below. |
| `aws_region` | No (default `eu-west-2`) | AWS region to deploy into. |
| `project_name` | No (default `hermes-personalize`) | Name prefix used to tag and identify all resources. |
| `instance_type` | No (default `t4g.micro`) | EC2 instance type. Move to `t4g.small` if the memory store grows (e.g. a real vector DB). |
| `root_volume_size_gb` | No (default `8`) | OS root volume size — holds the OS only, not agent memory. |
| `data_volume_size_gb` | No (default `20`) | Size of the separate EBS volume that holds long-term agent memory. |
| `snapshot_retention_days` | No (default `14`) | How many daily snapshots of the memory volume to retain. |
| `budget_limit_usd` | No (default `15`) | Monthly AWS Budget alert threshold in USD. |
| `enable_cloudwatch_logs` | No (default `true`) | Whether to create a CloudWatch Logs group for the agent process. |

### Steps

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: my_ip_cidr, key_name, budget_alert_email

terraform init

# Pass the OpenRouter key only as an env var — never in terraform.tfvars
TF_VAR_openrouter_api_key="sk-or-..." terraform plan
TF_VAR_openrouter_api_key="sk-or-..." terraform apply
```

`terraform.tfvars`, `*.tfstate`, and `.terraform/` are gitignored — never commit
them. To rotate the OpenRouter key later, update it directly in SSM Parameter
Store rather than via Terraform (see [terraform/README.md](./terraform/README.md)
for why).

## 2. Connecting to the instance

After `terraform apply` finishes, get the SSH command from the Terraform output:

```bash
terraform output ssh_command
```

which resolves to:

```bash
ssh -i <path-to-your-key>.pem ec2-user@<instance-public-ip>
```

Notes:

- The public IP is **not static** — there's no Elastic IP, so it changes every
  time the instance stops and starts (this is a deliberate cost tradeoff, see
  [docs/infra.md](./docs/infra.md)). Re-run `terraform output public_ip` after a
  restart if you're reconnecting.
- SSH is locked to the `my_ip_cidr` you supplied, so you'll need to update and
  re-apply the Terraform config if your IP changes (e.g. new network, VPN).
- The long-term memory volume is attached separately from the OS disk. On this
  instance type it will typically show up as `/dev/nvme1n1` rather than
  `/dev/sdf` — use `lsblk` or `nvme list` on the box to confirm, then mount it
  (e.g. under `/mnt/memory`) before pointing the agent process at it.

## 3. Setting up Hermes persistent memory

> **Status: planned, not yet implemented.** The infrastructure to support this
> (a separate encrypted EBS volume, `DeleteOnTermination=false`, daily snapshots
> via DLM) is already provisioned by Terraform. The agent process and its
> memory layer itself have not been built yet.

The intended design, per [docs/infra.md](./docs/infra.md):

1. Run the agent process on the EC2 instance, calling the OpenRouter chat
   completions API for the Nous Hermes model.
2. Persist conversation history (and, eventually, embeddings for semantic
   recall — a lightweight vector store or SQLite database) to the mounted
   memory volume, not to the OS disk, so it survives instance replacement.
3. Rely on the DLM daily-snapshot policy (retain 14 days by default) as the
   safety net for that data — the memory volume itself is protected from
   accidental deletion via `prevent_destroy` and EC2 termination protection.

This section will be filled in with concrete setup steps once the agent process
and memory layer are implemented.

## 4. Connecting with WhatsApp

> **Status: planned, not yet implemented.**

The intended design is to front the agent with a WhatsApp integration (e.g. the
WhatsApp Business Cloud API, or a bridge such as Twilio's WhatsApp API) so
messages sent to a WhatsApp number are relayed to the agent process running on
the EC2 instance, with replies sent back the same way. Because the instance's
security group currently only allows inbound traffic from `my_ip_cidr`, exposing
a webhook endpoint to WhatsApp's servers will require either opening a scoped
inbound rule for the provider's IP ranges or fronting the instance with a
managed endpoint (e.g. API Gateway or a tunnel) — this is an open design
question to resolve when this section is implemented.

This section will be filled in with concrete setup steps once the WhatsApp
integration exists.
