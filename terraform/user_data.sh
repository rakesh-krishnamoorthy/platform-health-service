#!/bin/bash
# Runs once on first boot. Log: /var/log/cloud-init-output.log
set -euxo pipefail

dnf install -y docker cronie
systemctl enable --now docker

docker run -d --name phs --restart always -p 80:8080 "${image}"

# Health check: every minute, if /health doesn't answer, log it and restart the container
cat > /usr/local/bin/healthcheck.sh <<'SCRIPT'
#!/bin/bash
if curl -fs --max-time 5 http://localhost/health > /dev/null; then
  exit 0
fi
logger -t healthcheck "health check failed - restarting container phs"
docker restart phs
SCRIPT

chmod +x /usr/local/bin/healthcheck.sh
echo "* * * * * root /usr/local/bin/healthcheck.sh" > /etc/cron.d/healthcheck
systemctl enable --now crond
