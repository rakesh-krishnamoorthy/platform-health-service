#!/bin/bash
# Runs once on first boot. Log: /var/log/cloud-init-output.log
set -euxo pipefail

dnf install -y docker
systemctl enable --now docker

docker run -d --name phs --restart always -p 80:8080 "${image}"
