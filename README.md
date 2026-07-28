# Hermes Personalize

An AWS deployment for running a personal agent backed by the **Nous Hermes**
model on [OpenRouter](https://openrouter.ai). This repository does not host or
fine-tune a model; it provisions the infrastructure around one.

## What this repo provides

Nous Hermes already gives you the model. What it doesn't give you is a place to
run a persistent agent process against it without either paying for a GPU
instance you don't need or accepting that state disappears whenever the process
restarts. This repo addresses that gap with four things:

- **No GPU provisioning.** The model runs on OpenRouter's infrastructure and is
  billed separately by them (their per-token pricing is not included here). The
  AWS side only needs to run an orchestration process, so it uses a cheap
  Graviton instance (`t4g.micro`), not an inference-capable one.
- **Cost-effective by default.** No Elastic IP (auto-assigned public IP instead,
  which costs nothing while the instance is stopped), gp3 storage, SSM
  Parameter Store instead of Secrets Manager for secrets, and a
  stop/start-friendly design. Estimated at $4 to $14/month depending on uptime;
  see [docs/infra.md](./docs/infra.md) for the full cost breakdown.
- **Backed-up long-term memory.** Agent state lives on a separate encrypted EBS
  volume, not the OS disk, with `DeleteOnTermination=false`, EC2 termination
  protection, and a daily DLM snapshot policy (14-day retention by default).
  The goal is that the memory volume survives instance replacement, accidental
  termination, and the usual ways people lose an EBS volume.
- **Cheap and secure for the same reason.** The security group allows **no
  inbound traffic at all**. Admin access rides over [Tailscale](https://tailscale.com)
  (a private mesh network giving the instance and your devices stable IPs
  regardless of what network you're on), and messaging rides over Telegram's
  long-polling API (the instance calls out to Telegram, Telegram never calls
  in). Because nothing external ever needs to open a new connection to the
  instance, there's no load balancer, API Gateway, or NAT Gateway to provision,
  pay for, or secure — cost and attack surface shrink together here, not as a
  trade-off against each other. See [docs/infra.md](./docs/infra.md) for the
  full rationale, and [Step 6](#6-possible-upgrades) below for what changes if
  you want a webhook-based integration (e.g. WhatsApp) or even tighter
  isolation later.

The full architecture and rationale (instance sizing, storage choice, IAM
scoping, security group rules, cost tables) are documented in
[docs/infra.md](./docs/infra.md), with a diagram at
[docs/infra.drawio](./docs/infra.drawio), rendered automatically to
[docs/export/infra.svg](./docs/export/infra.svg) by CI:

![Infrastructure diagram](./docs/export/infra.svg?v=30393284423-10)

## How to set this up

The steps below are meant to be followed in order, top to bottom, with no need
to jump ahead or double back. In particular: **Telegram and Tailscale both need
an account and a key created before you touch Terraform**, because Terraform
takes them as inputs. Step 1 gets everything you need lined up first, so Step 2
is a single uninterrupted `terraform apply`.

## 1. Gather your accounts and keys

Terraform needs an EC2 key pair name right away and three secrets
(`openrouter_api_key`, `telegram_bot_token`, `tailscale_auth_key`) as
environment variables at `apply` time. Get everything below ready now so
Step 2 doesn't stall halfway through waiting on a sign-up page:

1. **AWS account with credentials configured locally.** Terraform's AWS
   provider uses your default credential chain (`aws configure`, SSO, or env
   vars). Confirm it works: `aws sts get-caller-identity`.
2. **The Session Manager plugin for the AWS CLI**, installed locally:
   [instructions for your OS](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
   Confirm it works: `aws ssm start-session help` should print help text, not
   `SessionManagerPlugin is not found`. This isn't needed for the primary
   SSH-over-Tailscale path in Step 3, but it's what
   `aws ssm start-session`/`terraform output session_manager_command` need
   under the hood — the documented fallback for exactly the moment SSH or
   Tailscale itself is what's broken, so it's worth confirming *now*, while
   things are working, rather than discovering it's missing during an
   outage.
3. **An EC2 key pair**, in the region you'll deploy to, for SSH access in
   [Step 3](#3-connect-to-the-instance-over-tailscale). Set the name **once**,
   in a shell variable, then reuse that variable everywhere below — this is
   what keeps `--key-name`, the `.pem` filename, and `key_name` in
   `terraform.tfvars` (Step 2) from drifting apart, instead of relying on you
   to retype the same string correctly four times:

   ```bash
   KEY_NAME="hermes-aws"   # pick any name; you'll reuse $KEY_NAME below and in Step 2
   KEY_REGION="eu-west-2"  # must match aws_region in terraform.tfvars (Step 2); eu-west-2 is Terraform's default, see terraform/variables.tf

   aws ec2 create-key-pair \
     --key-name "$KEY_NAME" \
     --region "$KEY_REGION" \
     --query 'KeyMaterial' \
     --output text > ~/.ssh/"$KEY_NAME".pem
   chmod 600 ~/.ssh/"$KEY_NAME".pem
   ```

   - **Key pairs are scoped to a single region in AWS.** `$KEY_REGION` here
     must be the same region Terraform deploys into (`aws_region` in
     `terraform.tfvars`, or the `eu-west-2` default in
     `terraform/variables.tf` if you don't set it) — a key pair created in the
     wrong region simply won't exist as far as that `terraform apply` is
     concerned, and it'll fail with `InvalidKeyPair.NotFound`. Change
     `KEY_REGION` above if you're deploying somewhere other than `eu-west-2`.
   - This is *why* `--key-name` and the `.pem` filename must match, not just a
     style preference: in Step 2
     Terraform passes `key_name` to AWS to say "boot the instance with the
     public half of *this* key pair"; in Step 3 you point `ssh -i` at the
     private half yourself. AWS has no way to tell `ssh` which `.pem` goes
     with which `key_name` — nothing checks or connects those two strings for
     you, so if they don't match, `ssh` reads a key that doesn't correspond to
     the one on the instance and authentication fails with no clearer error
     than a hang or `Permission denied (publickey)`.
   - `chmod 600` is **not optional**. SSH refuses to use a private key that's
     readable by anyone but you and fails with `Permissions ... are too open`
     — and the permissions left behind by a shell redirect (`>`) are usually
     too loose by default.
   - Verify the file isn't empty before moving on:
     `wc -c ~/.ssh/"$KEY_NAME".pem` should print something greater than 0. A
     0-byte file usually means `create-key-pair` itself errored (check for a
     message above it, e.g. a name that's already taken) but the `>` redirect
     silently created the empty file anyway.
   - **AWS hands you the private key material exactly once, at creation
     time — it is never stored anywhere and cannot be recovered later**, not
     by AWS, not by Terraform, not by re-running the command. If the `.pem`
     file above ends up empty, wrong, or lost, re-running `create-key-pair`
     with the same `$KEY_NAME` fails with `InvalidKeyPair.Duplicate` — AWS
     won't let two key pairs share a name. You must delete the broken one
     first, then create a fresh one under the same name:
     ```bash
     aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$KEY_REGION"
     ```
     then re-run the `create-key-pair` command above.
   - **This only helps instances launched *after* you recreate the key.** EC2
     pushes a key pair's public half onto an instance's `authorized_keys`
     once, at launch — never retroactively. If an instance is already running
     with the now-broken key pair (e.g. you already ran `terraform apply` in
     Step 2 before noticing the `.pem` was bad), recreating the key pair here
     does nothing for *that* instance; you're locked out of it either way.
     Get back in via [Session Manager](#3-connect-to-the-instance-over-tailscale)
     instead (`terraform output session_manager_command`, no key pair
     required), then either manually add your new public key
     (`ssh-keygen -y -f ~/.ssh/"$KEY_NAME".pem`) to `~/.ssh/authorized_keys`
     for `ec2-user`, or force the instance to be replaced so it relaunches
     with the new key already baked in.
   - You'll type `$KEY_NAME`'s value into `terraform.tfvars` as `key_name` by
     hand in Step 2 — Terraform doesn't read these shell variables itself,
     they're just here so you only type each value once and copy-paste it
     everywhere else, instead of retyping it and risking a typo. Run
     `echo $KEY_NAME $KEY_REGION` if you need them again and the variables are
     still set in this shell. If `$KEY_REGION` isn't `eu-west-2`, also set
     `aws_region = "$KEY_REGION"` in `terraform.tfvars` — otherwise Terraform
     silently uses its own `eu-west-2` default and deploys somewhere your key
     pair doesn't exist.
   - Prefer the Console? EC2 → Key Pairs → **Create key pair** → name it
     whatever you'll use as `$KEY_NAME` → File format `.pem` → it downloads
     once (usually to `~/Downloads`); move it to `~/.ssh/`, name it
     `<that-same-name>.pem`, and `chmod 600` it exactly as above.
4. **An OpenRouter API key.** Sign up at [openrouter.ai](https://openrouter.ai)
   and create a key under Settings → API Keys. OpenRouter bills model usage
   separately from AWS; this repo only stores the key and lets the agent
   process use it.
5. **A Telegram bot token.** Message [@BotFather](https://t.me/BotFather),
   run `/newbot`, and copy the token it gives you. You won't interact with
   this bot again until [Step 5](#5-connecting-with-telegram-planned) — you're
   creating it now purely because the token needs to go into SSM alongside the
   other secrets during provisioning.
6. **A Tailscale auth key.** Sign up at [tailscale.com](https://tailscale.com)
   (free for personal use), then go to
   [console.tailscale.com/admin/settings/keys](https://console.tailscale.com/admin/settings/keys)
   and click **Generate auth key...**. This lets the instance join your tailnet
   automatically on first boot; you'll install Tailscale on your own devices
   separately in Step 3. In the dialog that opens:
   - **Description:** anything memorable, e.g. `hermes-aws`, purely for your
     own reference in the admin console later.
   - **Reusable: ON** (it defaults to off). The instance sits behind a
     self-healing Auto Scaling Group (min=max=desired=1), so a health-check
     failure can terminate and relaunch it automatically, not just when you do
     it manually — see `terraform/main.tf`. A single-use key would only let
     the *first* instance join; every replacement after that would fail to
     authenticate.
   - **Expiration:** 90 days, the maximum Tailscale allows and also the
     default. Because the ASG can replace the instance at *any* time, an
     expired key breaks silently: the replacement instance never joins your
     tailnet, and everything quietly falls back to the [Session Manager
     fallback](#3-connect-to-the-instance-over-tailscale) described in Step 3.
     Put a reminder somewhere to regenerate the key and update the SSM
     parameter before it expires — **this is a plain `aws ssm put-parameter`
     update, not a `terraform apply`**, and it doesn't affect the currently
     running instance either way, only the next time the ASG replaces it. See
     [terraform/README.md](./terraform/README.md#rotating-secrets) for the
     exact command and the reasoning.
   - **Ephemeral: ON** (under Device Settings, defaults to off). So a replaced
     instance's old tailnet entry is removed automatically the moment it goes
     offline, instead of leaving a dead node behind every time the ASG
     replaces the instance.
   - **Tags: leave OFF.** `terraform/main.tf`'s `user_data` calls
     `tailscale up` with no `--advertise-tags`, so this setup doesn't need any.
     Leave it off for another reason too: Tailscale's dialog notes that
     turning Tags on **also disables node key expiry** for the device, which
     you don't want to silently opt into here — with Tags off, node key expiry
     stays on its normal tailnet-wide default, independent of the 90-day auth
     key expiration above (that one only limits how long the key itself can
     be used to onboard new devices, not how long an already-joined device
     stays trusted).
   - Click **Generate key** and copy the result (starts with
     `tskey-auth-...`) somewhere safe immediately, Tailscale only shows it
     once.

With all six in hand, move to Step 2.

## 2. Provision the infrastructure

The Terraform in [terraform/](./terraform) provisions an EC2 instance, a
separate encrypted EBS volume for long-term memory, daily snapshots, IAM scoped
to least privilege, and a budget alert.

Every file, every variable, the full `init`/`plan`/`apply` command sequence,
what to do if Terraform prompts you interactively for a secret, and how to
rotate secrets afterward are all documented in
[terraform/README.md](./terraform/README.md#usage) — follow that from here,
using `key_name` and the three secrets gathered in Step 1 above. Once
`terraform apply` finishes, give the instance a minute to boot and join your
tailnet before moving to Step 3.

## 3. Connect to the instance over Tailscale

Admin access goes over [Tailscale](https://tailscale.com), not the instance's
public IP. The instance joined your tailnet automatically during boot in Step 2
(via the `user_data` script in `terraform/main.tf`, using the
`tailscale_auth_key` from Step 1), so:

1. Install Tailscale on your own machine (laptop and/or phone) and sign in to
   the same tailnet: [tailscale.com/download](https://tailscale.com/download).
2. Find the instance's Tailscale IP, either in the
   [Tailscale admin console](https://login.tailscale.com/admin/machines) or by
   running `tailscale status` on any device already in the tailnet, look for
   the hostname `<project_name>-agent`.
3. SSH to that IP with the key pair from Step 1:
   ```bash
   ssh -i ~/.ssh/hermes-aws.pem ec2-user@<tailscale-ip>
   ```
   (`terraform output ssh_instructions` prints a reminder of this.)

Notes:

- **`Permissions ... are too open` / `WARNING: UNPROTECTED PRIVATE KEY FILE`**:
  the `.pem` file's permissions are too loose; run
  `chmod 600 ~/.ssh/hermes-aws.pem` (see Step 1) and retry. If SSH then fails
  to authenticate rather than refusing the file, or the `.pem` is 0 bytes
  (`wc -c ~/.ssh/hermes-aws.pem`), the key material itself is missing or
  wrong — see the "lost the private key" note in Step 1, there's no way to
  recover it, only to generate a new key pair. In the meantime, the [Session
  Manager fallback](#3-connect-to-the-instance-over-tailscale) below still
  works, since it doesn't depend on this key pair at all.

- The instance's public IP (`terraform output public_ip`) still exists and
  still changes on every stop/start, exactly as before, but it's no longer
  used for admin access, only for the instance's own outbound calls to
  OpenRouter, Telegram, and Tailscale. You never need to look it up to connect.
- Because access is keyed to your device's Tailscale identity rather than your
  network's public IP, this keeps working unchanged if you're traveling or
  switching networks, there's no CIDR variable to update and no Terraform
  re-apply needed when your location changes.
- Restrict which devices can reach this node using
  [Tailscale ACLs](https://tailscale.com/kb/1018/acls) in the admin console,
  this is what replaces the security-group IP lock as the actual access-control
  layer.
- The long-term memory volume is attached, formatted (on first boot only), and
  mounted at `/mnt/memory` automatically by `user_data` — nothing manual
  needed here. See Step 4 for what actually lives on it.

**If Tailscale never comes up** (bad auth key, a transient failure in
`user_data`, etc.), there's a fallback that doesn't depend on it or on any
inbound rule: [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html).
```bash
terraform output session_manager_command
# aws ssm start-session --target <instance-id> --region <region>
```
This gets you a shell via an AWS-managed channel, authenticated by IAM rather
than network location or Tailscale's own health, so it works even when the
Tailscale bootstrap itself is the thing that's broken. It's also the fastest
way to check *why* Tailscale didn't come up: once in, check
`sudo journalctl -u tailscaled` and `sudo cat /var/log/cloud-init-output.log`
(or from your own machine, without needing any session at all:
`aws ec2 get-console-output --instance-id <instance-id>`).

## 4. Hermes persistent memory

`user_data` (`terraform/templates/user_data.sh.tpl`) formats the memory volume
on its first-ever boot only (later boots detect the existing filesystem and
skip straight to mounting), then mounts it at `/mnt/memory`:

- `/mnt/memory/conversations/<chat_id>.json` — one flat JSON file per Telegram
  chat, holding the last 20 messages of that conversation. No database, no
  vector store yet, just files — matching the "whatever your app uses" note in
  [docs/infra.md](./docs/infra.md). Trimmed to bound both disk use and the size
  (cost) of each OpenRouter request; if you want longer recall or semantic
  search later, this is the piece to swap for a real store.
- `/mnt/memory/telegram_offset.txt` — the last processed Telegram update ID,
  so a restart doesn't reprocess (or skip) messages.

This survives instance replacement (the whole reason it's a separate volume,
not part of the OS disk — see Step 2/`docs/infra.md`), and the DLM daily
snapshot policy (retain 14 days by default) is the safety net on top of that.

## 5. Connecting with Telegram

The agent (`terraform/templates/user_data.sh.tpl`, installed to
`/opt/hermes-agent/agent.py` and run as the `hermes-agent` systemd service)
does exactly what [docs/infra.md](./docs/infra.md) specifies: **long polling**,
not a webhook. It calls Telegram's `getUpdates` endpoint from inside the
instance, which holds the connection open and returns as soon as a message
arrives (or times out and gets called again). This is a deliberate choice over
Telegram's alternative webhook mode (`setWebhook`): long polling is entirely
outbound-initiated, so it needs no public HTTP endpoint, no inbound security
group rule, and no load balancer or API Gateway in front of the instance — it
fits the "no ingress at all" design with zero additional infrastructure.

For each incoming message, the agent loads that chat's history from
`/mnt/memory` (Step 4), sends it plus the new message to OpenRouter
(`openrouter_model` in `terraform.tfvars`, a Nous Hermes variant by default —
see [terraform/README.md](./terraform/README.md#variables) to change it),
and replies on Telegram with the model's response.

**To use it**: message your bot on Telegram (the one you created with
[@BotFather](https://t.me/BotFather) in Step 1) directly — nothing further to
configure, the `telegram_bot_token` from Step 1/Step 2 is already wired up.

**To check on it**, over SSH or Session Manager (Step 3):

1. **Is it running?**
   ```bash
   sudo systemctl status hermes-agent
   ```
   Look for `Active: active (running)` and a recent `Main PID`.
2. **Watch it live** — leave this running, then message your bot from your
   phone and watch a new line appear as it processes the update:
   ```bash
   sudo journalctl -u hermes-agent -f
   ```
3. **Check recent history** without needing to catch it live:
   ```bash
   sudo journalctl -u hermes-agent --since "10 minutes ago"
   ```
   A clean start logs one line like
   `hermes-agent starting, offset=0, model=nousresearch/hermes-3-llama-3.1-405b`.
   Repeated `getUpdates failed: ...` or `OpenRouter call failed: ...` lines
   instead usually mean a bad/expired key, not a broken process — a bad
   OpenRouter key, an invalid `openrouter_model` slug, or a Telegram token
   typo all surface as errors here rather than a failed boot, since the
   service itself starts fine either way and `Restart=always` keeps it
   retrying, per `terraform/templates/user_data.sh.tpl`.
4. **Confirm memory is actually being written** — after messaging the bot
   once:
   ```bash
   ls /mnt/memory/conversations/
   cat /mnt/memory/conversations/*.json
   ```
   One JSON file per Telegram chat ID, holding your message and the model's
   reply.
5. **The real test**: message your bot on Telegram and see if it replies —
   everything above is diagnostic if it doesn't.

If you want WhatsApp instead of (or alongside) Telegram, see
[Step 6](#6-possible-upgrades) below — WhatsApp's Cloud API requires a webhook,
so it needs a bit more infrastructure than Telegram does.

## 6. Possible upgrades

This design intentionally starts from the cheapest, most locked-down
configuration that still does the job: no ingress at all, admin access over
Tailscale, messaging over Telegram long polling. Two directions you might want
to extend it from here, one for functionality, one for tightening security
further. **The rule for both: never lower the security bar this design starts
from.** Any change that adds a genuinely public inbound path (an open security
group rule, a directly-exposed instance) is a regression, not an upgrade, unless
it's offset by an equivalent or stronger control (e.g. a managed edge service
that absorbs the exposure instead of the instance, plus app-layer verification).

### Adding functionality: WhatsApp webhook support

WhatsApp's Business Cloud API doesn't support long polling, only a webhook, so
supporting it means accepting *some* inbound path from the internet. The way to
do this **without** reopening the instance's own exposure:

- **API Gateway** (HTTP API) as the only public-facing piece, its own
  managed HTTPS endpoint, no cert management on your side.
- **VPC Link** connecting that route privately into the VPC.
- An internal **ALB or NLB** (no public IP of its own) as the VPC Link's
  target, forwarding to the instance's private IP. (Or skip the load balancer
  and use a VPC Link private integration via **AWS Cloud Map** instead,
  cheaper, but you're responsible for registering/deregistering the instance
  yourself rather than getting automatic target-group health checks.)
- The EC2 security group still gets **no new ingress rule** — the only thing
  that changes is that it now also accepts traffic from the internal load
  balancer/Cloud Map path, which never touches the public internet directly.
- WhatsApp's webhook verify token and payload signature (`X-Hub-Signature-256`)
  become your application-layer check on top of the network-layer isolation,
  not a replacement for it.

Expect roughly **+$16–20/month** for the load balancer (the Cloud Map option
instead would run a few dollars/month). This is strictly additive: it gives
WhatsApp a way in without giving the internet at large a way into the instance
itself.

### Tightening security further: NAT Gateway + fully private subnet

Today the instance keeps a public IP purely so its own outbound calls
(OpenRouter, Telegram, Tailscale, SSM) can leave directly via the Internet
Gateway, without needing a NAT Gateway. The security group already blocks all
inbound traffic, so this isn't an exposed inbound surface, but the instance is
still technically addressable from the internet (a port scan would see *a*
host there, just one with everything closed).

To remove that entirely:
- Move the instance into a **private subnet** (no public IP at all).
- Add a **NAT Gateway** for its own outbound calls, since OpenRouter, Telegram,
  and Tailscale are all external services with no AWS PrivateLink support, so
  VPC endpoints alone can't replace this leg (VPC endpoints would still be
  worth adding for SSM/KMS/CloudWatch traffic, to keep as much as possible off
  the NAT path).
- Everything else (Tailscale for admin access, Telegram long polling, the
  closed security group) stays exactly as-is; this only removes the instance's
  public IP, it doesn't change how anything connects to it.

Expect roughly **+$35–40/month** for the NAT Gateway (hourly charge + its own
EIP + data processing), a real cost jump for a marginal security gain given the
security group already blocks all inbound traffic, worth doing if you want
defense-in-depth against unknown future AWS/security-group misconfiguration,
not because the current setup has a known gap.
