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
DATA_DEVICE_HINT="${data_device_hint}"
CLONE_DIR="/opt/misp/uno-infra-misp"

# --- Base packages ----------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends git ca-certificates curl unzip

# --- Optional: mount the separate data volume at /opt/misp/data -------------
# The data volume (if created) shows up as an NVMe device. We format it once
# (only if it has no filesystem) and mount it persistently.
if [ -n "$${DATA_DEVICE_HINT}" ] && [ -b "$${DATA_DEVICE_HINT}" ]; then
  if ! blkid "$${DATA_DEVICE_HINT}"; then
    mkfs.ext4 -m 0 "$${DATA_DEVICE_HINT}"
  fi
  mkdir -p /opt/misp/data
  if ! grep -q "/opt/misp/data" /etc/fstab; then
    echo "$${DATA_DEVICE_HINT} /opt/misp/data ext4 defaults,nofail 0 2" >> /etc/fstab
  fi
  mount -a || true
fi

# --- Clone the repo so provision.sh/deploy.sh are available -----------------
mkdir -p /opt/misp
if [ ! -d "$${CLONE_DIR}/.git" ]; then
  git clone --branch "$${REPO_BRANCH}" "$${REPO_URL}" "$${CLONE_DIR}"
fi
chmod +x "$${CLONE_DIR}"/deploy/podman/*.sh || true

# --- Leave a hint for the operator ------------------------------------------
cat > /etc/motd <<'MOTD'
============================================================
 MISP host (isolated). Repo cloned at /opt/misp/uno-infra-misp
 Next steps (run as a normal user with sudo / via SSM):
   cd /opt/misp/uno-infra-misp
   sudo ./deploy/podman/provision.sh       # one-time: podman, registries, ports
   cp template.env .env                     # then configure (or hydrate from Secrets Manager)
   ./deploy/podman/deploy.sh                # bring up the MISP stack
============================================================
MOTD

echo "user-data bootstrap complete."
