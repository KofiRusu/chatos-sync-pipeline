# ChatOS Sync Pipeline

Infra-only GitOps repo for safe "sync + deploy" of the real ChatOS application.

Key points:
- The real ChatOS repo lives at `DEPLOY_PATH` on the Linux host (typically `/data/ChatOS`).
- This pipeline repo lives separately at `/opt/chatos-sync-pipeline` and must not be deployed.
- Deploys are safe-by-default: no mock data, no DB wipes, no live auto-trading.

See `docs/SETUP.md` for one-time Linux + GitHub setup and security requirements.
