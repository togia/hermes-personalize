#!/bin/bash
set -euxo pipefail

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

# IAM permissions can take a few seconds to propagate to a brand-new instance,
# so retry a handful of times rather than failing boot on the first attempt.
# set +x/-x for this whole block, through the tailscale up call below: with -x
# on, bash's trace prints the *expanded* form of every command — both the
# resolved value of a VAR=$(cmd) assignment, and any command's arguments after
# variable substitution. Leaving -x on anywhere the secret is fetched OR used
# would echo it straight into this script's own console output
# (/var/log/cloud-init-output.log, and anything that captures it).
set +x
for i in $(seq 1 5); do
  AUTH_KEY=$(aws ssm get-parameter \
    --name "${auth_key_param_name}" \
    --with-decryption \
    --region "${aws_region}" \
    --query "Parameter.Value" \
    --output text) && break
  sleep 5
done

# Use a reusable, ephemeral Tailscale auth key (both set in the Tailscale admin
# console when you generate it) — reusable because the ASG may relaunch from
# this same key more than once, ephemeral so a replaced instance's old node is
# pruned automatically instead of piling up as a dead entry in your tailnet.
tailscale up --authkey="$AUTH_KEY" --hostname="${project_name}-agent"
set -x

# The memory volume is a separate, persistent EBS volume that outlives any one
# instance, so it won't already be attached to this (possibly brand-new)
# instance — find it and attach it here. If the ASG is mid-replacement, the
# volume may still show attached to the instance being terminated for a few
# seconds; AWS auto-detaches non-root volumes on instance termination, so wait
# for that rather than force-detaching it ourselves.
for i in $(seq 1 12); do
  STATE=$(aws ec2 describe-volumes \
    --volume-ids "${memory_volume_id}" \
    --region "${aws_region}" \
    --query "Volumes[0].State" \
    --output text)
  if [ "$STATE" = "available" ]; then
    aws ec2 attach-volume \
      --volume-id "${memory_volume_id}" \
      --instance-id "$INSTANCE_ID" \
      --device /dev/sdf \
      --region "${aws_region}" && break
  fi
  sleep 10
done

# --- Format (once) and mount the persistent memory volume ---
# Nitro instances (all current-gen types, including t4g) expose EBS volumes as
# NVMe devices whose /dev/nvmeXn1 enumeration isn't guaranteed to match the
# device name given to attach-volume above. The udev-created by-id symlink,
# keyed by volume ID, is the reliable way to find the right one.
VOLUME_ID_NO_DASH=$(echo "${memory_volume_id}" | tr -d '-')
MEMORY_DEVICE="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$VOLUME_ID_NO_DASH"

for i in $(seq 1 12); do
  [ -e "$MEMORY_DEVICE" ] && break
  sleep 5
done

MEMORY_MOUNT=/mnt/memory
mkdir -p "$MEMORY_MOUNT"

# A brand-new volume has no filesystem yet — `file -sL` (the -L to follow the
# by-id symlink down to the real block device) reports "data" for one, vs.
# filesystem details for one that's already formatted. Only format once; this
# volume outlives the instance, so on every boot after the first it already
# has a filesystem and real conversation history on it.
if [ "$(file -sL "$MEMORY_DEVICE")" = "$MEMORY_DEVICE: data" ]; then
  mkfs -t ext4 "$MEMORY_DEVICE"
fi

mount "$MEMORY_DEVICE" "$MEMORY_MOUNT"
grep -q "$MEMORY_DEVICE" /etc/fstab || echo "$MEMORY_DEVICE $MEMORY_MOUNT ext4 defaults,nofail 0 2" >>/etc/fstab
mkdir -p "$MEMORY_MOUNT/conversations"
chown -R ec2-user:ec2-user "$MEMORY_MOUNT"

# --- Install the agent runtime ---
dnf install -y python3 python3-pip
pip3 install --no-cache-dir requests

# --- Fetch the remaining two secrets (Tailscale's own key was already fetched above) ---
# Same set +x/-x reasoning as the Tailscale key fetch above: don't let bash's
# trace echo decrypted secrets into the script's own console output.
set +x
for i in $(seq 1 5); do
  OPENROUTER_KEY=$(aws ssm get-parameter \
    --name "${openrouter_key_param_name}" \
    --with-decryption \
    --region "${aws_region}" \
    --query "Parameter.Value" \
    --output text) && break
  sleep 5
done

for i in $(seq 1 5); do
  TELEGRAM_TOKEN=$(aws ssm get-parameter \
    --name "${telegram_token_param_name}" \
    --with-decryption \
    --region "${aws_region}" \
    --query "Parameter.Value" \
    --output text) && break
  sleep 5
done

cat >/etc/hermes-agent.env <<EOF
OPENROUTER_API_KEY=$OPENROUTER_KEY
TELEGRAM_BOT_TOKEN=$TELEGRAM_TOKEN
OPENROUTER_MODEL=${openrouter_model}
MEMORY_DIR=$MEMORY_MOUNT
EOF
set -x
chown ec2-user:ec2-user /etc/hermes-agent.env
chmod 600 /etc/hermes-agent.env

# --- Install the agent itself ---
mkdir -p /opt/hermes-agent
cat >/opt/hermes-agent/agent.py <<'PYEOF'
#!/usr/bin/env python3
"""Long-polls Telegram for messages and answers them via a Hermes model on OpenRouter.

Conversation history is kept as one flat JSON file per chat under MEMORY_DIR,
per the design in docs/infra.md — no database, just files on the persistent
EBS volume, trimmed to the most recent messages to bound both disk use and
the size (cost) of each OpenRouter request.
"""
import json
import os
import time

import requests

OPENROUTER_API_KEY = os.environ["OPENROUTER_API_KEY"]
TELEGRAM_BOT_TOKEN = os.environ["TELEGRAM_BOT_TOKEN"]
OPENROUTER_MODEL = os.environ["OPENROUTER_MODEL"]
MEMORY_DIR = os.environ.get("MEMORY_DIR", "/mnt/memory")

TELEGRAM_API = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}"
OPENROUTER_API = "https://openrouter.ai/api/v1/chat/completions"

OFFSET_FILE = os.path.join(MEMORY_DIR, "telegram_offset.txt")
CONVERSATIONS_DIR = os.path.join(MEMORY_DIR, "conversations")
MAX_HISTORY_MESSAGES = 20
SYSTEM_PROMPT = (
    "You are a helpful personal assistant, replying concisely over Telegram. "
    "This is a private, single-user conversation, and the full history of it is "
    "persisted to disk and passed back to you on every turn -- there is no privacy "
    "feature or policy that erases or withholds anything the user has told you. "
    "Treat facts the user shares (their name for you, preferences, etc.) as "
    "durably remembered, and use them in later replies rather than claiming you "
    "can't retain them."
)

os.makedirs(CONVERSATIONS_DIR, exist_ok=True)


def load_offset():
    if os.path.exists(OFFSET_FILE):
        with open(OFFSET_FILE) as f:
            return int(f.read().strip() or 0)
    return 0


def save_offset(offset):
    with open(OFFSET_FILE, "w") as f:
        f.write(str(offset))


def history_path(chat_id):
    return os.path.join(CONVERSATIONS_DIR, f"{chat_id}.json")


def load_history(chat_id):
    path = history_path(chat_id)
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return []


def save_history(chat_id, history):
    with open(history_path(chat_id), "w") as f:
        json.dump(history[-MAX_HISTORY_MESSAGES:], f)


def ask_openrouter(history, text):
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    messages.extend(history)
    messages.append({"role": "user", "content": text})
    response = requests.post(
        OPENROUTER_API,
        headers={
            "Authorization": f"Bearer {OPENROUTER_API_KEY}",
            "Content-Type": "application/json",
            "X-Title": "hermes-personalize",
        },
        json={"model": OPENROUTER_MODEL, "messages": messages},
        timeout=60,
    )
    response.raise_for_status()
    return response.json()["choices"][0]["message"]["content"]


def send_telegram_message(chat_id, text):
    requests.post(
        f"{TELEGRAM_API}/sendMessage",
        json={"chat_id": chat_id, "text": text},
        timeout=30,
    )


def handle_update(update):
    message = update.get("message")
    if not message or "text" not in message:
        return
    chat_id = message["chat"]["id"]
    text = message["text"]

    history = load_history(chat_id)
    try:
        reply = ask_openrouter(history, text)
    except Exception as exc:
        print(f"OpenRouter call failed: {exc}", flush=True)
        reply = "Sorry, I hit an error talking to the model. Try again in a moment."

    history.append({"role": "user", "content": text})
    history.append({"role": "assistant", "content": reply})
    save_history(chat_id, history)

    send_telegram_message(chat_id, reply)


def main():
    offset = load_offset()
    print(f"hermes-agent starting, offset={offset}, model={OPENROUTER_MODEL}", flush=True)
    while True:
        try:
            response = requests.get(
                f"{TELEGRAM_API}/getUpdates",
                params={"offset": offset, "timeout": 30},
                timeout=35,
            )
            response.raise_for_status()
            updates = response.json().get("result", [])
        except Exception as exc:
            print(f"getUpdates failed: {exc}", flush=True)
            time.sleep(5)
            continue

        for update in updates:
            offset = update["update_id"] + 1
            try:
                handle_update(update)
            except Exception as exc:
                print(f"Failed to handle update {update.get('update_id')}: {exc}", flush=True)
            save_offset(offset)


if __name__ == "__main__":
    main()
PYEOF
chown -R ec2-user:ec2-user /opt/hermes-agent

# --- Run it as a supervised, auto-restarting service ---
cat >/etc/systemd/system/hermes-agent.service <<'UNITEOF'
[Unit]
Description=Hermes personalize Telegram/OpenRouter agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ec2-user
EnvironmentFile=/etc/hermes-agent.env
ExecStart=/usr/bin/python3 /opt/hermes-agent/agent.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable --now hermes-agent
