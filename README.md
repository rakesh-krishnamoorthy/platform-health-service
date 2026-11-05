# platform-health-service

[![CI/CD](https://github.com/rakesh-krishnamoorthy/platform-health-service/actions/workflows/ci-cd.yml/badge.svg)](https://github.com/rakesh-krishnamoorthy/platform-health-service/actions/workflows/ci-cd.yml)

A small Flask service that runs in Docker on an AWS EC2 instance. Terraform creates the infrastructure, GitHub Actions tests and publishes the image, and a cron job on the instance restarts the container if it stops responding.

| Endpoint | Response |
|---|---|
| `GET /` | `Hello from platform-health-service!` |
| `GET /health` | `{"status":"ok"}` |

## At a glance

| Area | How it's handled |
|---|---|
| Hosting | One `t3.micro` running Amazon Linux 2023 (free-tier eligible) |
| Starts after a restart | Docker is enabled at boot and the container uses `--restart always` |
| Network exposure | The security group allows inbound TCP 80 only |
| Admin access | SSM Session Manager: no SSH rule, no key pair, no inbound admin port |
| Failure detection | Cron calls `/health` every minute, logs a failure and restarts the container |
| Automation | Terraform for the infrastructure, `user_data.sh` for the instance setup |
| CI | Unit tests, image build, a container smoke test, then a push to GHCR |

## Architecture

![Architecture diagram](docs/architecture.png)

### Request path

1. A user sends `GET http://<public-ip>/health`.
2. The request reaches the instance's public IP in the default VPC. The security group allows inbound TCP 80 only, so anything else, including SSH on 22, is dropped.
3. Docker forwards host port 80 to port 8080 inside the `phs` container.
4. gunicorn (2 workers, 2 threads each) passes the request to the Flask app, which returns the response.

### Components

| Part | Responsibility |
|---|---|
| `.github/workflows/ci-cd.yml` | Runs the unit tests, builds the image, starts it and checks `/health`, then pushes it to GHCR tagged `latest` and the short commit SHA |
| `terraform/` | Creates the security group, the IAM role for SSM and the EC2 instance |
| `terraform/user_data.sh` | Runs once on first boot: installs Docker and cron, starts the container, installs the health check |
| `healthcheck.sh` (cron) | Calls `/health` every minute. If there is no answer within 5 seconds, it logs the failure and restarts the container |

### Access control

- Port 80 is the only inbound port. There is no SSH rule and no key pair.
- Admin access is through SSM Session Manager. The instance role has `AmazonSSMManagedInstanceCore`, and the SSM agent connects out over 443, so no inbound port is needed. Sessions are authenticated with IAM.
- IMDSv2 is required and the root volume is encrypted.
- The container runs as a non-root user.

## Repository layout

```
app/app.py                     Flask app
tests/test_app.py              Unit tests
Dockerfile                     Image (python:3.12-slim, gunicorn, non-root user)
requirements.txt               Pinned dependencies
.github/workflows/ci-cd.yml    CI/CD pipeline
terraform/                     main.tf, variables.tf, outputs.tf, user_data.sh
docs/architecture.png          Architecture diagram
```

## Prerequisites

To run locally:

- Docker
- Python 3.12

To deploy:

- Terraform 1.6 or newer
- AWS CLI v2 with a profile that can create EC2 instances, security groups and IAM roles
- A default VPC in the target region
- The [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for the AWS CLI

## Run locally

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python -m unittest discover tests -v

docker build -t platform-health-service .
docker run -d -p 8080:8080 --name phs platform-health-service
curl localhost:8080/health
docker rm -f phs
```

## Deploy to AWS

The instance pulls `ghcr.io/rakesh-krishnamoorthy/platform-health-service:latest`. The image is public, so no registry login is needed.

```bash
cd terraform
export AWS_PROFILE=<your-profile>
export AWS_REGION=ap-southeast-2
terraform init
terraform plan
terraform apply
```

The default region is `ap-southeast-2` because the account I used only allows that region. Any region with `t3.micro` works:

```bash
export AWS_REGION=us-east-1
terraform apply -var="region=$AWS_REGION"
```

First boot takes about 1-2 minutes while Docker installs and the image downloads.

### Rolling out a new image

`user_data.sh` only runs on first boot, so a new image doesn't reach the instance by itself. After CI has pushed it, open an SSM session and run:

```bash
IMAGE=ghcr.io/rakesh-krishnamoorthy/platform-health-service:latest
sudo docker pull "$IMAGE"
sudo docker rm -f phs
sudo docker run -d --name phs --restart always -p 80:8080 "$IMAGE"
```

## Validation

Run these from the `terraform/` directory.

```bash
# app responds
curl "$(terraform output -raw health_url)"    # {"status":"ok"}
curl "$(terraform output -raw app_url)"       # Hello from platform-health-service!

# SSH is not reachable from outside
nc -zv -w 5 "$(terraform output -raw public_ip)" 22    # times out

# admin shell through SSM
aws ssm start-session --target "$(terraform output -raw instance_id)"
```

The session starts in `sh` as `ssm-user`, which has sudo. On the instance:

```bash
sudo docker ps                         # phs is up, 0.0.0.0:80->8080
cat /etc/cron.d/healthcheck            # runs every minute

# simulate a hung app and watch the health check recover it
sudo docker pause phs
sleep 90
sudo journalctl -t healthcheck         # "health check failed - restarting container phs"
sudo docker ps                         # phs is running again
```

Reboot test, from your machine:

```bash
aws ec2 reboot-instances --instance-ids "$(terraform output -raw instance_id)"
# wait a minute or two, then
curl "$(terraform output -raw health_url)"
```

### Checked on the deployed instance

| Check | Result |
|---|---|
| `GET /health` and `GET /` from outside | `200` from gunicorn with the expected bodies |
| TCP 22 from outside | Times out |
| Security group inbound rules | TCP 80 from `0.0.0.0/0` only |
| Instance settings | No key pair, IMDSv2 required |
| Docker and cron | Both enabled at boot, cron entry in place |
| Container | Runs as `appuser` with restart policy `always` |

## CI/CD

The workflow runs on pushes to `main` and on pull requests.

1. **test** installs the dependencies and runs the unit tests.
2. **build-and-push** builds the image, starts the container and polls `/health`, failing the job if it never answers. On `main` it then logs in to GHCR with the built-in `GITHUB_TOKEN` and pushes `latest` and the short commit SHA.

No AWS credentials are stored in GitHub. Deployment to EC2 is done with Terraform from my machine.

Example output from [run 41904835171](https://github.com/rakesh-krishnamoorthy/platform-health-service/actions/runs/41904835171):

```
test
  test_health (test_app.AppTests.test_health) ... ok
  test_home (test_app.AppTests.test_home) ... ok
  test_unknown_path_returns_404 (test_app.AppTests.test_unknown_path_returns_404) ... ok
  Ran 3 tests in 0.075s
  OK

build-and-push
  Smoke test the container
    {"status":"ok"}
  Push image
    6929888: digest: sha256:026a71bcd40d55b26420c95073dc2bcf7b15465770451281ce42279b65484cd1 size: 2198
    latest: digest: sha256:026a71bcd40d55b26420c95073dc2bcf7b15465770451281ce42279b65484cd1 size: 2198
```

Both tags point to the same digest, and the EC2 instance pulled that digest on first boot, which traces the deployment back to commit `6929888`. To see what an instance is running:

```bash
sudo docker image inspect "$(sudo docker inspect phs --format '{{.Image}}')" --format '{{.RepoDigests}}'
```

## Cleanup

```bash
cd terraform
terraform destroy
```

This removes the instance, its volume, the security group and the IAM role and instance profile. The image in GHCR can be deleted from the package settings on GitHub.

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `curl` times out right after apply | Instance still booting | Wait 1-2 minutes, then check `/var/log/cloud-init-output.log` |
| `curl` keeps timing out | Security group changed, or instance stopped | Check the instance state and the port 80 rule, or run `terraform plan` to spot drift |
| Connection refused | Container not running | `sudo docker ps -a`, `sudo docker logs phs` |
| `docker ps` is empty right after boot | `user_data.sh` is still pulling the image | Wait and check again |
| `docker ps` stays empty | First boot failed, usually on the image pull. The script stops at the first error, so the health check isn't installed either | Read `/var/log/cloud-init-output.log`, fix the cause, then run `terraform apply -replace=aws_instance.app` |
| `journalctl -t healthcheck` shows no entries | Normal. The script only logs failures | Nothing to do |
| `UnauthorizedOperation ... explicit deny in a service control policy` | The organisation policy blocks that region | Use a region the account allows |
| `TargetNotConnected` from `aws ssm start-session` | SSM agent not registered yet, no outbound internet, or the wrong region | Wait a couple of minutes after boot, check `AWS_REGION` and the instance profile |
| `docker: permission denied` on the instance | `ssm-user` isn't in the docker group | Use `sudo docker ...` |
| Public IP changed | Instance was stopped and started, or replaced | `terraform output public_ip` |

## Operations note: what I check during an outage

1. **Is it really down?** Run `curl -v http://<ip>/health` from outside. A timeout points at the network or instance, connection refused points at the container, and a 5xx points at the app.
2. **Is the instance running?** Use the EC2 console or `aws ec2 describe-instance-status`. If status checks are failing, read `aws ec2 get-console-output`, then stop and start the instance.
3. **Is the network path intact?** The security group should still allow TCP 80 and the instance should still have a public IP. `terraform plan` shows anything changed by hand.
4. **Is the container running?** Connect with SSM and run `sudo docker ps -a`. If it's restarting in a loop, `sudo docker logs phs` usually shows why.
5. **Does it answer locally?** Run `curl localhost/health` on the instance. If that works but the outside check doesn't, the problem is in front of the instance, not in the app.
6. **What has the health check done?** `sudo journalctl -t healthcheck` shows each failed check and restart. Repeated restarts mean restarting isn't fixing it.
7. **Is the host healthy?** Check `df -h` (a full disk breaks Docker), `free -m` (a t3.micro has 1 GB) and `uptime`.

To get back to a known good state quickly: `sudo docker restart phs`, then reboot the instance, and as a last resort `terraform apply -replace=aws_instance.app` for a fresh one.

## Assumptions and limitations

- **Single instance.** There is no redundancy. With more time I'd use an Auto Scaling group behind an Application Load Balancer, which would also replace the cron health check with load balancer health checks.
- **HTTP only.** There is no domain or TLS certificate. In production TLS would terminate on a load balancer with an ACM certificate.
- **The health check doesn't page anyone.** Failures go to the system journal. Real alerting would publish to SNS or ship logs to CloudWatch with an alarm.
- **The health check runs on the same instance.** If the whole instance dies it can't report it. An external check, such as a Route 53 health check or a CloudWatch alarm on EC2 status checks, would cover that.
- **The health check has no backoff.** If the app is broken, it restarts the container every minute until someone fixes it.
- **First boot has no retry.** A failed image pull stops `user_data.sh` before the health check is installed, and the instance has to be replaced.
- **No automatic deploy to EC2.** CI publishes the image, and the instance only pulls it on first boot. A next step would be a deploy job using GitHub OIDC and `aws ssm send-command`.
- **The instance uses the mutable `latest` tag.** Pinning `var.image` to a commit SHA tag or a digest would make deployments repeatable.
- **CI doesn't check Terraform.** `terraform fmt` and `terraform validate` are run by hand. Adding them to the workflow is a small next step.
- **Local Terraform state.** That's fine for one person. A team would use an S3 backend with locking.
- **SSM sessions aren't recorded in detail.** Session Manager keeps a session history, but command logging to S3 or CloudWatch isn't configured.
- **Default VPC and a public subnet.** This avoids paying for a NAT gateway or load balancer.
- **Outbound traffic is open** so the instance can install packages, pull the image and reach SSM. It could be narrowed to 443 or replaced with VPC endpoints.
- **Cost.** `t3.micro` is free-tier eligible on the account I used. AWS bills public IPv4 addresses separately, so an account without a free-tier allowance or credits may see a small charge. Run `terraform destroy` when finished.
