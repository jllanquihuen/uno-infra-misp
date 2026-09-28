#!/usr/bin/env bash
#
# user-data bootstrap for the isolated MISP EC2 instance.
#
# Goal: leave the VM ready so an operator (or SSM Run Command) can run
# provision.sh + deploy.sh from this repo. It deliberately does NOT run the
# full MISP deploy here - first boot of MISP is long and better triggered
# explicitly once secrets/.env are in place.
#
# Runs as root via cloud-init on first boot.
set -euxo pipefail

REPO_URL="${repo_url}"
REPO_BRANCH="${repo_branch}"
DATA_VOLUME_ENABLED="${data_volume_enabled}"
DATA_VOLUME_ID="${data_volume_id}"
CLONE_DIR="/opt/misp/uno-infra-misp"

# --- Base packages ----------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends git ca-certificates curl unzip nvme-cli jq

# --- AWS CLI v2 -------------------------------------------------------------
# Needed on the instance itself for secrets-bootstrap.sh (Secrets Manager) and
# backup.sh (S3), using the instance IAM role. Installed from the official bundle.
if ! command -v aws >/dev/null 2>&1; then
  ARCH="$(uname -m)"
  case "$${ARCH}" in
    x86_64)  AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
    aarch64) AWSCLI_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
    *)       AWSCLI_URL="" ;;
  esac
  if [ -n "$${AWSCLI_URL}" ]; then
    tmpd="$(mktemp -d)"
    curl -fsSL "$${AWSCLI_URL}" -o "$${tmpd}/awscliv2.zip" \
      && unzip -q "$${tmpd}/awscliv2.zip" -d "$${tmpd}" \
      && "$${tmpd}/aws/install" \
      || echo "WARN: AWS CLI install failed; install manually if secrets/backups are needed." >&2
    rm -rf "$${tmpd}"
  fi
fi

# --- Time sync (NTP) --------------------------------------------------------
# ANCI recommends keeping the clock/timezone in sync so logs and scheduled tasks
# stay consistent. Ubuntu ships systemd-timesyncd; ensure it is enabled.
timedatectl set-ntp true 2>/dev/null || systemctl enable --now systemd-timesyncd 2>/dev/null || true

mkdir -p /opt/misp/data

# --- Optional: mount the separate data volume at /opt/misp/data -------------
# On EC2 Nitro, EBS volumes surface as NVMe devices whose enumeration order is
# NOT tied to the Terraform device_name (e.g. /dev/xvdf), so we must NOT assume a
# fixed name like /dev/nvme1n1. We locate the data volume robustly:
#   1) Prefer the NVMe device whose serial matches the attached EBS volume-id
#      (nvme id-ctrl exposes the vol-xxxx serial). This is unambiguous.
#   2) Fallback: the single whole disk that has NO partitions and NO filesystem
#      and is NOT the root disk (a freshly attached, unformatted data volume).
# Mounting is done by filesystem UUID in fstab, which is stable across reboots
# regardless of the NVMe device name.
if [ "$${DATA_VOLUME_ENABLED}" = "1" ]; then
  DATA_DEV=""

  # Root device (to exclude it from candidates).
  ROOT_SRC="$(findmnt -no SOURCE / || true)"
  ROOT_DISK="$(lsblk -no PKNAME "$${ROOT_SRC}" 2>/dev/null || true)"
  [ -n "$${ROOT_DISK}" ] && ROOT_DISK="/dev/$${ROOT_DISK}"

  # 1) Match by EBS volume-id via NVMe serial (strip dashes; EBS serial is volXXXX).
  if command -v nvme >/dev/null 2>&1 && [ -n "$${DATA_VOLUME_ID}" ]; then
    want="$(printf '%s' "$${DATA_VOLUME_ID}" | tr -d '-')"   # vol-0abc -> vol0abc
    for dev in /dev/nvme*n1; do
      [ -b "$${dev}" ] || continue
      serial="$(nvme id-ctrl -o json "$${dev}" 2>/dev/null | grep -o '"sn"[^,]*' | tr -cd 'a-zA-Z0-9')"
      case "$${serial}" in
        *"$${want}"*) DATA_DEV="$${dev}"; break ;;
      esac
    done
  fi

  # 2) Fallback: whole disk, no partitions, no filesystem, not the root disk.
  if [ -z "$${DATA_DEV}" ]; then
    while read -r name type; do
      [ "$${type}" = "disk" ] || continue
      dev="/dev/$${name}"
      [ "$${dev}" = "$${ROOT_DISK}" ] && continue
      # skip disks that already have children (partitions)
      [ -n "$(lsblk -no NAME "$${dev}" | tail -n +2)" ] && continue
      # skip disks that already have a filesystem
      [ -n "$(blkid -o value -s TYPE "$${dev}" 2>/dev/null)" ] && continue
      DATA_DEV="$${dev}"; break
    done < <(lsblk -dno NAME,TYPE)
  fi

  if [ -n "$${DATA_DEV}" ]; then
    # Format only if it has no filesystem yet (idempotent across reboots).
    if [ -z "$(blkid -o value -s TYPE "$${DATA_DEV}" 2>/dev/null)" ]; then
      mkfs.ext4 -m 0 "$${DATA_DEV}"
    fi
    UUID="$(blkid -o value -s UUID "$${DATA_DEV}")"
    if [ -n "$${UUID}" ] && ! grep -q "$${UUID}" /etc/fstab; then
      echo "UUID=$${UUID} /opt/misp/data ext4 defaults,nofail 0 2" >> /etc/fstab
    fi
    mount -a || true
  else
    echo "WARN: data volume enabled but no candidate NVMe device found; data will live on root disk." >&2
  fi
fi

# --- Clone the repo so provision.sh/deploy.sh are available -----------------
mkdir -p /opt/misp
if [ ! -d "$${CLONE_DIR}/.git" ]; then
  git clone --branch "$${REPO_BRANCH}" "$${REPO_URL}" "$${CLONE_DIR}"
fi
chmod +x "$${CLONE_DIR}"/deploy/podman/*.sh || true

# --- Point the deploy at the data volume ------------------------------------
# The stack reads MISP_DATA_DIR from .env; we drop a persistent marker so an
# operator (or SSM automation) can seed .env with the right data path. This keeps
# ALL persistent data (MariaDB, files, configs, gnupg, ...) on the data EBS
# volume mounted at /opt/misp/data.
echo "MISP_DATA_DIR=/opt/misp/data" > /opt/misp/misp-data-dir.env

# --- Leave a hint for the operator ------------------------------------------
cat > /etc/motd <<'MOTD'
============================================================
 MISP host (isolated). Repo cloned at /opt/misp/uno-infra-misp
 Next steps (run as a normal user with sudo / via SSM):
   cd /opt/misp/uno-infra-misp
   sudo ./deploy/podman/provision.sh          # one-time: podman, registries, ports
   cp template.env .env                        # base config
   ./deploy/podman/secrets-bootstrap.sh        # hydrate secrets from Secrets Manager
   echo MISP_DATA_DIR=/opt/misp/data >> .env   # persist data on the data EBS volume
   ./deploy/podman/deploy.sh                   # bring up the MISP stack
============================================================
MOTD

echo "user-data bootstrap complete."
