# GitOps Sync + Deploy Setup (One-Time)

This repo is **infra-only**. It deploys the real ChatOS application repo located at `DEPLOY_PATH` on the Linux host.

- ChatOS app repo (target): `/data/ChatOS` (default)
- Pipeline repo (this repo): `/opt/chatos-sync-pipeline`

## 1) Linux host prerequisites

```bash
# Create a dedicated deploy user
sudo useradd -m -s /bin/bash chatos-deploy

# Ensure the ChatOS app repo path exists
sudo mkdir -p /data/ChatOS
sudo chown -R chatos-deploy:chatos-deploy /data/ChatOS

# Clone the ChatOS app repo (real app)
sudo -u chatos-deploy git clone https://github.com/KofiRusu/ChatOS-v2.3 /data/ChatOS

# Create the pipeline repo path
sudo mkdir -p /opt/chatos-sync-pipeline
sudo chown -R chatos-deploy:chatos-deploy /opt/chatos-sync-pipeline

# Clone the pipeline repo (this repo)
sudo -u chatos-deploy git clone https://github.com/KofiRusu/chatos-sync-pipeline /opt/chatos-sync-pipeline

# Install basics
sudo apt-get update
sudo apt-get install -y git curl util-linux
```

If you plan to use Docker Compose fallback restarts:

```bash
sudo usermod -aG docker chatos-deploy
```

If you plan to use systemd services, ensure these units exist and are restartable:
- `chatos-backend.service`
- `chatos-frontend.service` (optional)

## 2) Add the GitHub Actions SSH key

On your local machine:

```bash
ssh-keygen -t ed25519 -C "chatos-deploy" -f ./chatos_deploy_key
```

On the Linux server, add the public key to the deploy user:

```bash
sudo -u chatos-deploy mkdir -p /home/chatos-deploy/.ssh
sudo -u chatos-deploy cat ./chatos_deploy_key.pub >> /home/chatos-deploy/.ssh/authorized_keys
sudo -u chatos-deploy chmod 700 /home/chatos-deploy/.ssh
sudo -u chatos-deploy chmod 600 /home/chatos-deploy/.ssh/authorized_keys
```

## 3) Configure GitHub Secrets

Add these secrets in the pipeline repo settings:

- `DEPLOY_HOST`: `your.server.example.com` or `203.0.113.10`
- `DEPLOY_USER`: `chatos-deploy`
- `DEPLOY_PATH`: `/data/ChatOS` (the real ChatOS repo)
- `DEPLOY_SSH_KEY`: the full private key contents from `./chatos_deploy_key`
- `DEPLOY_KNOWN_HOSTS`: recommended, output of `ssh-keyscan -H your.server.example.com`
- `DEPLOY_DRY_RUN`: optional, set to `true` to only print actions on push

Example for `DEPLOY_KNOWN_HOSTS`:

```bash
ssh-keyscan -H your.server.example.com
```

Paste the entire output as the secret value.

## 4) (Optional) Allow DB migrations

By default, deployments will NOT run Alembic migrations.
To allow migrations, set this on the Linux host (not in GitHub):

```bash
echo 'export ALLOW_DB_MIGRATIONS=true' | sudo tee /etc/profile.d/chatos-migrations.sh
```

Only enable this temporarily when you explicitly want migrations.

## 5) Safety guards (fail-closed)

The deploy script refuses to run if any of these are set to a truthy value:
- `ENABLE_MOCK_DATA`, `USE_MOCK_DATA`, `MOCK_DATA`
- `AUTO_TRADE_LIVE`, `LIVE_TRADING`, `TRADING_LIVE`
- `WIPE_DB`, `RESET_DB`

It also refuses to run as root and only operates within `DEPLOY_PATH`.
If `DEPLOY_PATH` looks like the pipeline repo, the deploy will abort.

## 6) Manual deploy (optional)

You can trigger a manual deploy from GitHub Actions (workflow dispatch):
- `dry_run`: defaults to `true`
- `ref`: defaults to `main`

The script will only deploy the target ref when the local branch matches it.

## 7) First deploy

Push to `main` in the pipeline repo. GitHub Actions will SSH into the server and run:

```bash
/opt/chatos-sync-pipeline/scripts/deploy_remote.sh
```

The script uses a lock file at `/data/ChatOS/.deploy.lock` to avoid concurrent deploys.

## Troubleshooting

- If the deploy user cannot restart systemd services, configure systemd permissions
  or use Docker Compose and add the user to the `docker` group.
- If deploys stop, verify `.deploy.lock` is not left behind by a stale session.
