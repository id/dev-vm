#!/usr/bin/env bash

set -e

DEV_USER=${1:-emqx}

DEVICE=/dev/nvme1n1
UNIT=$(systemd-escape --suffix mount --path /data)
cat <<EOF | sudo tee /etc/systemd/system/$UNIT
[Unit]
Description=Mount $DEVICE to /data
Requires=local-fs.target
After=local-fs.target

[Mount]
What=$DEVICE
Where=/data
Type=ext4
Options=defaults

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF | sudo tee /usr/local/bin/mount-data.sh
#!/bin/bash

set -euo pipefail

if [ ! -b $DEVICE ]; then
    echo "No extra data volume found"
    exit 1
fi

echo "Found extra data volume, format and mount to /data"
sudo mount
sudo lsblk
if ! sudo mkfs.ext4 -L data $DEVICE; then
  echo "Volume already formatted, trying to mount"
fi

sudo mkdir -p /data
sudo mount -L data /data
sudo mkdir -p /data/docker
sudo chown -R root:docker /data/docker
sudo systemctl restart docker.service

sudo mkdir -p /data/work
sudo chown -R $DEV_USER:$DEV_USER /data/work
ln -s /data/work ~/work
sudo systemctl daemon-reload
sudo systemctl enable --now $UNIT
EOF
sudo chmod +x /usr/local/bin/mount-data.sh

export DEBIAN_FRONTEND=noninteractive
DPKG_ARCH=$(dpkg --print-architecture) # amd64/arm64
UNAME_ARCH=$(uname -m) # x86_64/aarch64

echo 'DefaultLimitNOFILE=65536' | sudo tee -a /etc/systemd/system.conf
echo 'DefaultLimitSTACK=16M:infinity' | sudo tee -a /etc/systemd/system.conf

# Raise Number of File Descriptors
echo '* soft nofile 65536' | sudo tee -a /etc/security/limits.conf
echo '* hard nofile 65536' | sudo tee -a /etc/security/limits.conf

# Double stack size from default 8192KB
echo '* soft stack 16384' | sudo tee -a /etc/security/limits.conf
echo '* hard stack 16384' | sudo tee -a /etc/security/limits.conf

sudo apt-get update -y -qq
sudo apt-get install -y -qq apt-transport-https ca-certificates software-properties-common
sudo apt-get update -y -qq
sudo apt-get install -y -qq curl gnupg lsb-release jq git zip unzip curl wget net-tools dnsutils
sudo apt-get install -y -qq build-essential autoconf automake autotools-dev cmake debhelper pkg-config zlib1g-dev unixodbc unixodbc-dev libssl-dev
sudo apt-get install -y -qq emacs vim tmux htop jq git
sudo apt-get install -y -qq python3 python3-pip python3-venv
sudo apt-get install -y -qq locales-all

sudo ln -sf /usr/bin/python3 /usr/bin/python
sudo ln -sf /usr/bin/pip3 /usr/bin/pip

# docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh ./get-docker.sh
sudo systemctl enable containerd.service
sudo systemctl enable docker.service
THIS_USER=$(whoami)
sudo usermod -a -G docker $THIS_USER
cat << EOF | sudo tee /etc/docker/daemon.json
{
   "data-root": "/data/docker"
}
EOF

sudo useradd -m -s /bin/bash -G docker,sudo $DEV_USER
echo "$DEV_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers.d/$DEV_USER
sudo mkdir /home/$DEV_USER/.ssh
sudo chown -R $DEV_USER:$DEV_USER /home/$DEV_USER/.ssh
sudo chmod 700 /home/$DEV_USER/.ssh
sudo cp ~/.ssh/authorized_keys /home/$DEV_USER/.ssh/authorized_keys
sudo chown $DEV_USER:$DEV_USER /home/$DEV_USER/.ssh/authorized_keys
sudo chmod 600 /home/$DEV_USER/.ssh/authorized_keys

# java
curl -fsSL https://apt.corretto.aws/corretto.key | sudo gpg --dearmor -o /usr/share/keyrings/corretto.key
echo "deb [arch=$DPKG_ARCH signed-by=/usr/share/keyrings/corretto.key] https://apt.corretto.aws stable main" | sudo tee /etc/apt/sources.list.d/corretto.list
sudo apt-get -y update && sudo apt-get -y install java-11-amazon-corretto-jdk maven

# aws tools
wget -q https://awscli.amazonaws.com/awscli-exe-linux-$UNAME_ARCH.zip -O /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install

# yq
wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$DPKG_ARCH -O /tmp/yq
sudo mv /tmp/yq /usr/bin/yq
sudo chmod +x /usr/bin/yq

# clean up
sudo journalctl --rotate
sudo journalctl --vacuum-time=1s

# delete all .gz and rotated file
sudo find /var/log -type f -regex ".*\.gz$" -delete
sudo find /var/log -type f -regex ".*\.[0-9]$" -delete

# wipe log files
sudo find /var/log/ -type f -exec cp /dev/null {} \;
