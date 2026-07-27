# Infrastructure Proposal: Personal Hermes Agent on EC2 + EBS

## What this is (and isn't)

You're consuming the **Nous Hermes** model through **OpenRouter's API** — you are not
hosting the model weights yourself. That means the EC2 instance doesn't need a GPU or
even much CPU/RAM; it only needs to run:

- Your agent/app process (whatever calls the OpenRouter chat completions API)
- A place to persist "long-term memory" (conversation history, embeddings, a small
  vector store / SQLite / JSON files — whatever your app uses) on the attached EBS volume

This is the reason the setup can be cheap: it's a lightweight orchestration host, not an
inference server. All the model compute happens on OpenRouter's infrastructure and is
billed by them separately (their per-token pricing is **not** included in the estimate
below).

## Proposed architecture

```
You (SSH, your IP only)
        │
        ▼
  Internet Gateway
        │
        ▼
┌───────────────────────────────────────────┐
│ VPC (default), public subnet               │
│                                             │
│  ┌───────────────────────────────────────┐ │        ┌──────────────────────┐
│  │ EC2 t4g.micro (Graviton, ARM)         │ │──────▶ │ OpenRouter API       │
│  │ - Hermes personalize agent process    │ │ HTTPS  │ (hosts Nous Hermes)  │
│  │ - IAM instance role (least privilege) │ │ 443    └──────────────────────┘
│  └───────────────────────────────────────┘ │
│              │            │                 │
│              │ attached   │ reads secret     │
│              ▼            ▼                 │
│  ┌────────────────────┐ ┌────────────────┐  │
│  │ EBS gp3 volume      │ │ SSM Parameter  │  │
│  │ 20 GB, encrypted    │ │ Store          │  │
│  │ DeleteOnTermination │ │ SecureString:  │  │
│  │ = false             │ │ OPENROUTER_KEY │  │
│  │ (long-term memory)  │ └────────────────┘  │
│  └────────────────────┘                      │
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

See `infra-diagram.drawio` for the visual version of this.

## Components and rationale

| Component | Choice | Why |
|---|---|---|
| Compute | EC2 **t4g.micro** (2 vCPU burstable, 1 GiB RAM, Graviton/ARM) | Cheapest instance class that reliably runs a small Python/Node process + light memory store. Graviton is ~20% cheaper than equivalent x86 (t3) for this workload. If your memory store grows (e.g. a real vector DB like Chroma/Qdrant instead of flat files), bump to **t4g.small** (2 GiB RAM) — see cost table. |
| Storage | EBS **gp3**, 20 GB, encrypted | gp3 is cheaper than gp2 at the same performance and includes 3,000 IOPS / 125 MB/s baseline free — far more than a personal agent needs. Encryption is free and should always be on for anything holding your personal data/memories. |
| Durability of memory | 1) `DeleteOnTermination=false` on the volume, 2) EC2 **termination protection** enabled, 3) **Data Lifecycle Manager (DLM)** daily automated snapshot policy, retain 14 | This is the core requirement — "never lose the memories." EBS volumes already have 99.999% durability via in-AZ replication, but that doesn't protect against *you* accidentally terminating the instance or deleting the volume, or the volume being deleted, or logical/application-level corruption. Snapshots (stored in S3, 11 nines durability) are the actual safety net for those cases and let you roll back to any of the last 14 days. `DeleteOnTermination=false` + termination protection are cheap insurance against the single most common way people lose an EBS volume: killing the instance without realizing the attached volume goes with it by default. |
| Secrets | **SSM Parameter Store**, SecureString, for the OpenRouter API key | Free (vs. Secrets Manager's ~$0.40/secret/month) and perfectly adequate for a single personal API key. KMS-encrypted at rest, fetched by the instance role at runtime — never hardcoded. |
| IAM | Dedicated instance role, scoped to: `ssm:GetParameter` on that one parameter, `cloudwatch:PutMetricData`/logs if you want monitoring, nothing else | Least privilege — if the instance is ever compromised, the blast radius is one parameter, not your account. |
| Networking | Default VPC, public subnet, **no Elastic IP** (auto-assigned public IP instead) | Since Feb 2024 AWS charges ~$0.005/hr for *every* public IPv4, whether it's an Elastic IP or an auto-assigned one. Using auto-assign instead of an EIP means you pay $0 for the address while the instance is **stopped**, which matters if you adopt the stop/start cost optimization below. Trade-off: the public IP changes each time you stop/start. Fine for personal use (check it in the console, or point a cheap dynamic-DNS/Route 53 record at it). |
| Security Group | Inbound: SSH (22) from **your IP /32 only**. Any app port you expose, also restricted to your IP. Outbound: 443 to anywhere (needed to reach OpenRouter). | Minimizes attack surface — this is a personal box, it should not be reachable from the internet at large. |

## Cost estimate (us-east-1, on-demand, approximate)

Prices change and vary by region — treat this as directional and confirm with the
[AWS Pricing Calculator](https://calculator.aws) before committing. OpenRouter's own
per-token charges are **not** included; those are billed separately by OpenRouter based
on your usage.

### Always-on (instance running 24/7)

| Item | Rate | Monthly |
|---|---|---|
| EC2 t4g.micro (730 hrs) | $0.0084/hr | ~$6.15 |
| EBS gp3, 20 GB | $0.08/GB-mo | ~$1.60 |
| DLM snapshots (daily, retain 14, gp3 20GB, modest change rate) | ~$0.05/GB-mo, incremental | ~$1.00–2.00 |
| Public IPv4 (auto-assigned, always attached) | $0.005/hr × 730 | ~$3.65 |
| SSM Parameter Store (standard SecureString), CloudWatch basic metrics | — | $0.00 |
| **Total** | | **~$12–14/month** |

### Stop the instance when you're not using it (recommended for personal use)

EBS storage cost continues while stopped (that's the point — memory is preserved), but
compute and public-IP charges stop. If you use it ~4 hrs/day:

| Item | Monthly |
|---|---|
| EC2 t4g.micro (~120 hrs) | ~$1.00 |
| EBS gp3, 20 GB (always allocated) | ~$1.60 |
| DLM snapshots | ~$1.00–2.00 |
| Public IPv4 (only while running, ~120 hrs) | ~$0.60 |
| **Total** | **~$4–5/month** |

### If you upsize to t4g.small (2 GiB RAM, e.g. for a real vector DB)

Add roughly **+$6/month** compute to either scenario above (t4g.small is ~$0.0168/hr vs.
t4g.micro's ~$0.0084/hr).

### Free Tier note

If this AWS account is under 12 months old, EC2 (up to t3.micro-equivalent hours),
30 GB of EBS, and 750 hrs/month of public IPv4 may be free, which would make the
always-on scenario nearly $0–2/month for the first year. t4g instances are **not**
covered by the free tier (only t2/t3), so if you want to use the free tier, start with
t3.micro (x86) instead of t4g.micro until the free tier expires, then switch.

## Recommendation

Start with:
- **EC2 t4g.micro**, stopped/started on your own schedule rather than left running 24/7
- **20 GB gp3 EBS volume**, encrypted, `DeleteOnTermination=false`
- **EC2 termination protection** enabled
- **DLM daily snapshot policy**, retain 14 days
- **No Elastic IP** — auto-assigned public IP only
- **SSM Parameter Store** for the OpenRouter API key
- **Security group locked to your IP**
- An **AWS Budget alert** (free) set at, say, $15/month so you get notified before any
  surprise costs — cheap peace of mind on a personal project

This lands around **$4–14/month** depending on how much you leave it running, comfortably
cost-effective, while making it very hard to lose the data on the EBS volume short of
deleting the AWS account itself.

## Next steps (not yet done)

This is a proposal only — nothing has been provisioned. If you'd like to proceed, I can:
1. Write this as Terraform or CDK so it's reproducible and destroy/recreate-safe
2. Or walk through provisioning it directly via the AWS CLI/console

Let me know which you'd prefer before I create anything in your AWS account.
