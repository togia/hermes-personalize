#!/bin/bash
set -euxo pipefail

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

dnf install -y git

# Amazon Linux 2023 does not provide an ffmpeg package in its standard ARM64
# repositories. Hermes needs ffmpeg to turn Edge TTS's MP3 output into
# Ogg/Opus; its Telegram adapter then uses the native sendVoice route for an
# inline voice note. Install the upstream ARM64 static build so this does not
# depend on a third-party RPM repo.
if ! command -v ffmpeg >/dev/null 2>&1; then
  FFMPEG_ARCHIVE=/tmp/ffmpeg-release-arm64-static.tar.xz
  FFMPEG_DIR=$(mktemp -d)
  curl -fL --retry 3 --retry-delay 2 \
    -o "$FFMPEG_ARCHIVE" \
    https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-arm64-static.tar.xz
  tar -xJf "$FFMPEG_ARCHIVE" -C "$FFMPEG_DIR"
  install -m 0755 "$FFMPEG_DIR"/*/ffmpeg /usr/local/bin/ffmpeg
  install -m 0755 "$FFMPEG_DIR"/*/ffprobe /usr/local/bin/ffprobe
  rm -rf "$FFMPEG_ARCHIVE" "$FFMPEG_DIR"
fi

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

# This volume is attached outside the launch template so it can survive an ASG
# replacement. Make the default explicit: termination of this instance must
# never delete the persistent Hermes memory volume.
aws ec2 modify-instance-attribute \
  --instance-id "$INSTANCE_ID" \
  --region "${aws_region}" \
  --block-device-mappings '[{"DeviceName":"/dev/sdf","Ebs":{"DeleteOnTermination":false}}]'

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

# --- Fetch the Hermes Agent credentials (Tailscale's key was fetched above) ---
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

set -x

# --- Install and configure the official NousResearch Hermes Agent CLI ---
# HERMES_HOME is on the persistent volume, so the CLI's configuration, sessions,
# skills, and memories survive replacement of the EC2 instance.
HERMES_HOME="$MEMORY_MOUNT/hermes"
mkdir -p "$HERMES_HOME"

# Seed the CLI's own environment before its non-interactive install. The
# installer does not overwrite an existing .env, and the gateway loads these
# credentials directly from HERMES_HOME.
cat >"$HERMES_HOME/.env" <<EOF
OPENROUTER_API_KEY=$OPENROUTER_KEY
TELEGRAM_BOT_TOKEN=$TELEGRAM_TOKEN
EOF
chown -R ec2-user:ec2-user "$HERMES_HOME"
chmod 600 "$HERMES_HOME/.env"

# Install from the NousResearch repository, rather than the old local Python
# loop above. Hermes owns the native tool-calling loop: it sends the tool
# schemas to OpenRouter, receives tool calls, executes them locally, and
# supplies results to the model.
runuser -l ec2-user -c "HERMES_HOME='$HERMES_HOME' curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash -s -- --non-interactive --skip-setup --skip-browser --hermes-home '$HERMES_HOME'"

HERMES_BIN=/home/ec2-user/.local/bin/hermes
runuser -l ec2-user -c "HOME=/home/ec2-user HERMES_HOME='$HERMES_HOME' '$HERMES_BIN' config set model.provider openrouter"
runuser -l ec2-user -c "HOME=/home/ec2-user HERMES_HOME='$HERMES_HOME' '$HERMES_BIN' config set model.default '${openrouter_model}'"
runuser -l ec2-user -c "HOME=/home/ec2-user HERMES_HOME='$HERMES_HOME' '$HERMES_BIN' config set tts.provider edge"
runuser -l ec2-user -c "HOME=/home/ec2-user HERMES_HOME='$HERMES_HOME' '$HERMES_BIN' config set tts.edge.voice en-GB-SoniaNeural"

# --- Run the official CLI gateway as a supervised, auto-restarting service ---
cat >/etc/systemd/system/hermes-agent.service <<UNITEOF
[Unit]
Description=NousResearch Hermes Agent gateway (Telegram)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ec2-user
Environment=HOME=/home/ec2-user
Environment=HERMES_HOME=$HERMES_HOME
ExecStart=$HERMES_BIN gateway run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable --now hermes-agent
