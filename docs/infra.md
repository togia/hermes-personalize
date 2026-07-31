# Infrastructure Proposal: Personal Hermes Agent on EC2 + EBS

## What this is (and isn't)

You're running the official **NousResearch Hermes Agent CLI** on EC2 and consuming
**DeepSeek V4 Pro** for chat/tool calling plus **Qwen3 VL 32B Instruct** for image
analysis through OpenRouter — you are not hosting model weights yourself.
The instance does not need a GPU, but it does need enough memory for Hermes' Node.js
and Python runtime, gateway, skills, and local tool execution. It runs:

- `hermes gateway run`, which owns Telegram long polling, the agent loop, and tool execution
- Hermes' persistent state (sessions, memories, skills, and configuration) under
  `HERMES_HOME=/mnt/memory/hermes` on the attached EBS volume

This is the reason the setup can be cheap: it's a lightweight orchestration host, not an
inference server. All the model compute happens on OpenRouter's infrastructure and is
billed by them separately (their per-token pricing is **not** included in the estimate
below).

## Proposed architecture

```
You (laptop + phone)                    Telegram Bot API   Tailscale
via Tailscale — stable private IP       (long polling)     (coordination + DERP relay)
        │                                      ▲                  ▲
        │ encrypted tunnel                     │ outbound         │ outbound
        ▼ (no inbound rule needed)             │ 443              │ 443/UDP 41641
  Internet Gateway                             │                  │
        │                                      │                  │
        ▼                                      │                  │
┌──────────────────────────────────────────────┼──────────────────┼───┐
│ VPC (default), public subnet                 │                  │   │
│                                              │                  │   │
│  ┌───────────────────────────────────────┐   │                  │   │
│  │ EC2 t4g.small (Graviton, ARM)         │───┴──────────────────┘   │
│  │ - Hermes Agent CLI gateway             │──────▶ ┌──────────────────────┐
│  │ - IAM instance role (least privilege) │  HTTPS │ OpenRouter API       │
│  │ - SG: no ingress rules at all         │  443   │ DeepSeek V4 Pro       │
│  └───────────────────────────────────────┘        └──────────────────────┘
│              │            │                  │
│              │ attached   │ reads secrets    │
│              ▼            ▼                  │
│  ┌─────────────────────┐ ┌─────────────────────────┐
│  │ EBS gp3 volume      │ │ SSM Parameter Store     │
│  │ 20 GB, encrypted    │ │ SecureStrings:          │
│  │ DeleteOnTermination │ │ OpenRouter, Telegram,   │
│  │ = false             │ │ Tailscale auth key      │
│  │ (long-term memory)  │ └─────────────────────────┘
│  └─────────────────────┘                     │
│              │ daily snapshot                │
│              ▼                               │
│  ┌────────────────────┐                      │
│  │ Data Lifecycle Mgr │                      │
│  │ policy (daily,     │                      │
│  │ retain 14)         │                      │
│  └────────────────────┘                      │
│              │                               │
└──────────────┼───────────────────────────────┘
               ▼
     Amazon S3 (EBS snapshots,
     11 nines durability, cross-AZ)
```

The instance still has a public IP and sits in a public subnet — that hasn't changed. What's different is that the security group has **no ingress rules at all**. Every arrow into the instance in this diagram (Tailscale, Telegram, OpenRouter responses) is actually the *return* leg of a connection the instance itself initiated outbound; nothing external ever opens a new connection in. That's what makes it possible to skip a load balancer, API Gateway, and NAT Gateway entirely, there's no inbound path to route, terminate, or protect.

See `docs/infra.drawio` for the visual version of this.

## Components and rationale

| Component | Choice | Why |
|---|---|---|
| Compute | EC2 **t4g.small** (2 vCPU burstable, 2 GiB RAM, Graviton/ARM) | Sized for the full Hermes Agent CLI runtime (Node.js + Python), its messaging gateway, local tools, and persistent state. Graviton remains cost-effective for this orchestration workload. |
| Storage | Two encrypted **gp3** volumes, 20 GB each | The root volume holds Amazon Linux and the Hermes runtime; the separate memory volume holds `HERMES_HOME` and survives replacement. gp3 includes 3,000 IOPS / 125 MB/s baseline. |
| Durability of memory | 1) `DeleteOnTermination=false` on the volume, 2) EC2 **termination protection** enabled, 3) **Data Lifecycle Manager (DLM)** daily automated snapshot policy, retain 14 | This is the core requirement — "never lose the memories." EBS volumes already have 99.999% durability via in-AZ replication, but that doesn't protect against *you* accidentally terminating the instance or deleting the volume, or the volume being deleted, or logical/application-level corruption. Snapshots (stored in S3, 11 nines durability) are the actual safety net for those cases and let you roll back to any of the last 14 days. `DeleteOnTermination=false` + termination protection are cheap insurance against the single most common way people lose an EBS volume: killing the instance without realizing the attached volume goes with it by default. |
| Secrets | **SSM Parameter Store**, SecureString, for the OpenRouter API key, Telegram bot token, and Tailscale auth key | Free (vs. Secrets Manager's ~$0.40/secret/month) and perfectly adequate for a handful of personal secrets. KMS-encrypted at rest, fetched by the instance role at runtime — never hardcoded. An existing Google key is retained only as an unused compatibility parameter. |
| IAM | Dedicated instance role, scoped to: `ssm:GetParameter` on the runtime secrets, `kms:Decrypt` on the default SSM key, `cloudwatch:PutMetricData`/logs if you want monitoring, nothing else | Least privilege — if the instance is ever compromised, the blast radius is the agent's runtime secrets, not your account. |
| Networking | Default VPC, public subnet, **no Elastic IP** (auto-assigned public IP instead) | Since Feb 2024 AWS charges ~$0.005/hr for *every* public IPv4, whether it's an Elastic IP or an auto-assigned one. Using auto-assign instead of an EIP means you pay $0 for the address while the instance is **stopped**, which matters if you adopt the stop/start cost optimization below. Trade-off: the public IP changes each time you stop/start — this no longer matters for admin access (see Tailscale below), and it never mattered for outbound calls, which don't care what the address is. |
| Security Group | **No ingress rules at all.** Outbound: 443 (OpenRouter, Telegram, Tailscale coordination, SSM), 53/UDP (DNS), 41641/UDP (Tailscale direct connections, optional). | Nothing external can open a new connection to this instance, full stop. Admin access and messaging both ride on connections the instance itself initiates outbound (see Tailscale and Telegram rows), so there's nothing to open inbound and no load balancer, API Gateway, or NAT Gateway needed to front it. |
| Remote admin access | **Tailscale**, installed via `user_data` on first boot, joins the instance to your private tailnet using an auth key from SSM. You SSH to the instance's stable Tailscale IP instead of its (changing) public IP. | Solves both the "my IP changes when I travel" problem (no more editing a CIDR variable and re-applying Terraform every time you're on a new network) and the "don't expose SSH to the internet" problem, at the same time, for free. Tailscale's own ACLs (configured in the Tailscale admin console, not in this Terraform) should restrict which of your devices can reach this node. |
| Admin access fallback | **AWS Systems Manager Session Manager** (`aws ssm start-session`), IAM-only, no inbound rule | Covers the case where `user_data`'s Tailscale join never comes up (bad auth key, transient failure, etc.). It's a second path in, but not a second inbound rule — Session Manager uses an AWS-managed outbound channel, same "no ingress" property as Tailscale, just independent of whether Tailscale itself is healthy. |
| Messaging and tools | **Hermes Telegram gateway** with native OpenRouter tool calling and vision routing | Hermes sends tool schemas to DeepSeek V4 Pro through OpenRouter, receives model-selected tool calls, executes them on the instance, and sends results back to the model. Image analysis is routed separately through OpenRouter to Qwen3 VL 32B Instruct. Telegram long polling remains outbound-only, avoiding a public HTTP endpoint. Microsoft Edge TTS uses `en-GB-SoniaNeural`, is transcoded to Ogg/Opus, and Hermes sends it through Telegram's native `sendVoice` voice-note route; `sendAudio` remains for MP3/M4A attachments. |

## Cost estimate (us-east-1, on-demand, approximate)

Prices change and vary by region — treat this as directional and confirm with the
[AWS Pricing Calculator](https://calculator.aws) before committing. OpenRouter's own
per-token charges are **not** included; those are billed separately by OpenRouter based
on your usage.

### Always-on (instance running 24/7)

| Item | Rate | Monthly |
|---|---|---|
| EC2 t4g.small (730 hrs) | $0.0168/hr | ~$12.25 |
| EBS gp3, 20 GB root + 20 GB memory | $0.08/GB-mo | ~$3.20 |
| DLM snapshots (daily, retain 14, gp3 20GB, modest change rate) | ~$0.05/GB-mo, incremental | ~$1.00–2.00 |
| Public IPv4 (auto-assigned, always attached) | $0.005/hr × 730 | ~$3.65 |
| SSM Parameter Store (standard SecureString), CloudWatch basic metrics | — | $0.00 |
| **Total** | | **~$20–21/month** |

### Stop the instance when you're not using it (recommended for personal use)

EBS storage cost continues while stopped (that's the point — memory is preserved), but
compute and public-IP charges stop. If you use it ~4 hrs/day:

| Item | Monthly |
|---|---|
| EC2 t4g.small (~120 hrs) | ~$2.00 |
| EBS gp3, 20 GB root + 20 GB memory (always allocated) | ~$3.20 |
| DLM snapshots | ~$1.00–2.00 |
| Public IPv4 (only while running, ~120 hrs) | ~$0.60 |
| **Total** | **~$7–8/month** |

### If you downsize to t4g.micro (1 GiB RAM)

The full Hermes Agent CLI is heavier than the former custom Python loop. Downsizing
saves roughly **$6/month** of always-on compute but risks memory pressure and is not
recommended unless you have verified your enabled tools and skills fit.

### Free Tier note

If this AWS account is under 12 months old, EC2 (up to t3.micro-equivalent hours),
30 GB of EBS, and 750 hrs/month of public IPv4 may be free, which would make the
always-on scenario nearly $0–2/month for the first year. t4g instances are **not**
covered by the free tier (only t2/t3), so if you want to use the free tier, start with
t3.small (x86) instead of t4g.small until the free tier expires, then switch.

## Recommendation

Start with:
- **EC2 t4g.small**, stopped/started on your own schedule rather than left running 24/7
- **20 GB gp3 root volume** plus a separate **20 GB gp3 memory volume**, both encrypted;
  the memory volume has `DeleteOnTermination=false`
- **EC2 termination protection** enabled
- **DLM daily snapshot policy**, retain 14 days
- **No Elastic IP** — auto-assigned public IP only
- **SSM Parameter Store** for the OpenRouter API key, Telegram bot token, and Tailscale auth key
- **Security group with no ingress rules at all** — admin access via Tailscale, messaging via Telegram long polling, both outbound-initiated
- An **AWS Budget alert** (free) at $25/month, above normal always-on infrastructure spend

This lands around **$7–21/month** depending on how much you leave it running, comfortably
cost-effective, while making it very hard to lose the data on the EBS volume short of
deleting the AWS account itself. Adding Tailscale and Telegram doesn't move this number —
both are free at personal scale — which is the point: **this design is cheap and secure
for the same reason**. Because there is no inbound path into the instance at all, there is
also no load balancer, API Gateway, or NAT Gateway to pay for or to secure. Cost and attack
surface shrink together here, not as a trade-off against each other.
