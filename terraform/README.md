# Terraform infrastructure

This directory provisions the architecture described in [../docs/infra.md](../docs/infra.md):
an EC2 t4g.small host running the official NousResearch Hermes Agent CLI, with
DeepSeek V4 Pro through OpenRouter, Telegram gateway polling, native tool execution,
and long-term memory on a separate encrypted EBS volume. Daily snapshots and a
security group with no inbound rules preserve the same low-exposure design; admin
access rides over Tailscale instead of a locked-to-your-IP SSH rule.

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
| `variables.tf` | Inputs: EC2 key pair name, instance/volume sizing, OpenRouter key / Telegram bot token / Tailscale auth key (all sensitive), optional backwards-compatible Google key, OpenRouter model slug, and budget alert email. |
| `main.tf` | The resources: security group with **no ingress rules**, IAM instance role + SSM/KMS/CloudWatch/Session Manager permissions, SSM SecureStrings for the OpenRouter key/Telegram token/Tailscale auth key plus an unused backwards-compatible Google-key parameter, EC2 instance (AL2023 arm64) with `user_data` that joins Tailscale and installs the agent on first boot, separate EBS volume + attachment for memory, DLM daily-snapshot policy, AWS Budget alert |
| `templates/user_data.sh.tpl` | The instance's first-boot script, rendered by `main.tf` via `templatefile()`: installs the ARM64 static `ffmpeg` build needed for Telegram Ogg/Opus voice notes, joins Tailscale, attaches/formats/mounts the memory volume at `/mnt/memory`, installs the official [NousResearch Hermes Agent CLI](https://github.com/NousResearch/hermes-agent) from its repository, and starts its `gateway run` process as the `hermes-agent` systemd service. Hermes sends native tool schemas to OpenRouter, executes returned tool calls locally, and feeds results back to the model. See [Step 4](../README.md#4-hermes-persistent-memory) and [Step 5](../README.md#5-connecting-with-telegram) in the top-level README for what it does at runtime. |
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
| `key_name` | **Yes** | Name of an existing EC2 key pair to use for SSH access. Must match both the `--key-name` you created it with and the `.pem` filename you'll SSH with later (e.g. `key_name = "hermes-aws"` ↔ `~/.ssh/hermes-aws.pem`). See [Step 1 in the top-level README](../README.md#1-gather-your-accounts-and-keys) for the exact `create-key-pair` command, the required `chmod 600`, and why a lost/empty `.pem` can't be recovered. |
| `budget_alert_email` | **Yes** | Email address notified when spend crosses the budget threshold. |
| `openrouter_api_key` | **Yes** (passed as an env var, not in `.tfvars`) | Your OpenRouter API key, stored as a SecureString in SSM Parameter Store. Never commit this or put it in `terraform.tfvars`, see below. |
| `telegram_bot_token` | **Yes** (passed as an env var, not in `.tfvars`) | Your Telegram bot token from [@BotFather](https://t.me/BotFather), stored as a SecureString in SSM Parameter Store. Used for long polling, so no inbound webhook is required. |
| `tailscale_auth_key` | **Yes** (passed as an env var, not in `.tfvars`) | A [Tailscale auth key](https://tailscale.com/kb/1085/auth-keys) used to join the instance to your tailnet on first boot, stored as a SecureString in SSM Parameter Store. This is what gives you a stable IP for admin access no matter where you're connecting from. |
| `google_api_key` | No | Optional backwards-compatible Google AI Studio key for a manual future switch to Gemini. The default Microsoft Edge TTS provider needs no API key. |
| `aws_region` | No (default `eu-west-2`) | AWS region to deploy into. |
| `project_name` | No (default `hermes-personalize`) | Name prefix used to tag and identify all resources. |
| `instance_type` | No (default `t4g.small`) | EC2 instance type sized for the full Hermes Agent CLI runtime and its local tools. |
| `root_volume_size_gb` | No (default `20`) | OS root volume for Amazon Linux and the Hermes runtime; persistent Hermes state remains on the separate memory volume. |
| `data_volume_size_gb` | No (default `20`) | Size of the separate EBS volume that holds long-term agent memory. |
| `snapshot_retention_days` | No (default `14`) | How many daily snapshots of the memory volume to retain. |
| `openrouter_model` | No (default `deepseek/deepseek-v4-pro`) | OpenRouter model slug used by the official Hermes Agent CLI for chat and native tool calling. |
| `vision_openrouter_model` | No (default `qwen/qwen3-vl-32b-instruct`) | OpenRouter multimodal model used only by Hermes's `vision_analyze` tool. This keeps the text-only chat model separate from image analysis. |
| `budget_limit_usd` | No (default `25`) | Monthly AWS Budget alert threshold in USD, above expected always-on infrastructure cost (excluding OpenRouter usage). |
| `enable_cloudwatch_logs` | No (default `true`) | Whether to create a CloudWatch Logs group for the agent process. |

## Usage

1. `cp terraform.tfvars.example terraform.tfvars` and fill in `key_name` and
   `budget_alert_email`. **Do not** put any of the three required secrets below in this file.
2. `terraform init`
3. Export the three required secrets as environment variables, in this same shell, so none of
   them are written to `terraform.tfvars` or typed at a prompt:
   ```bash
   export TF_VAR_openrouter_api_key="sk-or-..."
   export TF_VAR_telegram_bot_token="123456:ABC-your-botfather-token"
   export TF_VAR_tailscale_auth_key="tskey-auth-..."
   ```
4. Review the plan:
   ```bash
   terraform plan
   ```
   It should show a plan to create resources with no `No value for required variable`
   errors and no interactive prompts. If it does prompt you, see below.
5. If the plan looks right, apply it:
   ```bash
   terraform apply
   ```
   Type `yes` when prompted to confirm.
6. Optionally, clear the secrets from your shell once you're done:
   ```bash
   unset TF_VAR_openrouter_api_key TF_VAR_telegram_bot_token TF_VAR_tailscale_auth_key
   ```

`terraform.tfvars`, `*.tfstate`, and `.terraform/` are gitignored — never commit them.

### Changing the agent script or model configuration

`aws_launch_template.agent` reads `templates/user_data.sh.tpl` via `templatefile()`.
Editing that script, or a variable it depends on (`openrouter_model`,
`vision_openrouter_model`, `instance_type`, etc.), and running `terraform apply`
creates a new launch-template version. The ASG's Terraform-managed instance
refresh then replaces its one instance so the change takes effect; expect a
short maintenance window while the existing node releases the single-AZ memory
volume and its replacement boots. The memory volume and everything on it
survives — only the instance and its OS disk are replaced.

### If Terraform prompts you for a value interactively

If you run `plan` or `apply` without exporting the env vars above, Terraform falls
back to asking for each missing variable one at a time, e.g.:

```
var.openrouter_api_key
  OpenRouter API key, stored as a SecureString in SSM Parameter Store.

  Enter a value:
```

This is **Terraform** prompting, not SSM — it just happens to name the variable after
the SSM parameter it's about to write, which is easy to mistake for an SSM prompt.
Avoid typing secrets in at this prompt (it's easy to leave them sitting in your
terminal scrollback); instead, `Ctrl+C` out and re-run with the env vars from step 3
set. If you do end up at this prompt, here's which value goes with which name:

| Prompt | Enter |
|---|---|
| `var.openrouter_api_key` | Your OpenRouter API key, starts with `sk-or-` |
| `var.telegram_bot_token` | Your Telegram bot token from [@BotFather](https://t.me/BotFather), looks like `123456:ABC-...` |
| `var.tailscale_auth_key` | Your [Tailscale auth key](https://tailscale.com/kb/1085/auth-keys), starts with `tskey-auth-` |
| `var.google_api_key` | Optional [Google AI Studio API key](https://aistudio.google.com/app/apikey) retained only for a manual future Gemini TTS switch. |

## Rotating secrets

To rotate any of the three runtime secrets later, update them directly in SSM Parameter Store
(console or `aws ssm put-parameter --overwrite`) rather than via Terraform — each
parameter's `lifecycle.ignore_changes` is set (see `main.tf`) so `terraform apply` won't
stomp on a manual rotation, and won't push a rotated value back to whatever's still in
your shell history or `TF_VAR_*` env vars either. **No `terraform apply` needed for a
rotation, full stop** — it's an out-of-band SSM update, nothing else.

### Rotating the Tailscale auth key specifically

The auth key you generate (see
[Step 1 in the top-level README](../README.md#1-gather-your-accounts-and-keys) for the
exact settings) expires after at most 90 days. When that happens:

```bash
aws ssm put-parameter \
  --name /<project_name>/tailscale-auth-key \
  --value "tskey-auth-<new-key>" \
  --type SecureString \
  --overwrite \
  --region <your-region>
```

Two things worth knowing about timing:

- **The currently-running instance is unaffected either way.** `user_data` reads this
  parameter and calls `tailscale up` exactly once, on first boot. Once a node has
  joined the tailnet, the auth key that got it there becomes irrelevant to that
  session — the key's expiration only limits how long it can be used to onboard a
  *new* device, it has nothing to do with how long an already-joined device stays
  connected (that's a separate, tailnet-wide "node key expiry" setting).
- **It only matters the next time the instance gets replaced.** Since `main.tf` runs
  this on a self-healing Auto Scaling Group (not a static, manually-managed instance),
  a replacement can happen at any time — a health-check failure, not just something you
  triggered. If the SSM value is still an expired key when that happens, the
  replacement's `user_data` fails to authenticate and never joins the tailnet; you'd
  fall back to `terraform output session_manager_command` instead of SSH-over-Tailscale
  until the parameter is rotated. There's no hard deadline to rotate by, just do it
  sometime before the 90 days is up.
