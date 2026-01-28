# NDP Endpoint Stack Setup

This repository contains the `setup.sh` helper that bootstraps the full NDP Endpoint stack (Kafka, CKAN, EP API, and optionally JupyterHub) on a single host using Docker. It consumes a federation config document and wires credentials, groups, and URLs automatically.

## What the script does
- Fetches the federation config by ID and persists a snapshot to `federation_config.json`.
- Detects host IP, installs missing dependencies (curl, jq, git; Docker if absent), and selects `docker compose` or `docker-compose`.
- Clones and configures stack components under `full-stack/`:
  - **Kafka** (`kafka-kraft`): starts broker and Kafka UI (localhost-bound).
  - **CKAN** (`pop-ckan-docker`): builds/starts catalog, generates a sysadmin API token.
  - **JupyterHub** (`jhub`, optional): configures Keycloak OAuth, groups, callback URLs, and starts the hub.
  - **EP API** (`ep-api`): writes `.env`, starts the API container.
- Writes run artifacts and credentials to `user_info.env` (chmod 600) and a human-readable `setup_info.txt` summary.

## Inputs
- Required: federation config ID (`--config_id <id>`).
- Optional: `--env prod|test` (defaults to prod) and `--federation_url <override>`.
- The federation config provides CKAN creds, Keycloak client details, group name, pre-CKAN info, JupyterHub toggle, streaming toggle, etc.

### Group handling
If `group_name` is present (e.g., `ndp_ep/ep-123`), JupyterHub is configured with both forms: `ndp_ep/ep-123,/ndp_ep/ep-123` to satisfy deployments expecting either prefix style.

## Prerequisites
- Linux host with internet access and permission to install packages (sudo) if Docker is missing.
- Open ports: 8080 (Kafka UI, bound to localhost), 8443 (CKAN), 8001 (EP API), 8002 (JupyterHub, optional), plus Kafka broker ports 9092/9094 on the host IP when streaming is enabled.
- Adequate disk space for Docker images and containers.

## How to run
```bash
./setup.sh --config_id YOUR_CONFIG_ID --env test
```
- Use `--env prod` for production federation lookup.
- You can override the federation API base with `--federation_url https://custom.example.com`.

### Idempotency and re-runs
- Kafka/CKAN/JupyterHub/EP API steps skip work if the service is already running and required keys are present.
- Secrets are retained in `full-stack/*/.env` files; public endpoints and summaries are in `user_info.env` and `setup_info.txt`.

## Generated files and directories
- `federation_config.json`: snapshot of fetched config.
- `user_info.env`: persisted key/value pairs (config ID, URLs, generated tokens, etc.).
- `setup_info.txt`: human-readable summary of endpoints and credentials (non-secret where possible).
- `full-stack/`: contains cloned service repos, per-service `.env`, and docker-compose assets.

## Service endpoints (defaults)
- CKAN: `https://<host-ip>:8443`
- EP API: `http://<host-ip>:8001` (port adjustable via `EP_API_PORT` env)
- Kafka UI: `http://localhost:8080`
- JupyterHub (if enabled): `http://<host-ip>:8002`

## Kafka modes, credentials, and a quick test
- The broker exposes SASL_PLAINTEXT on `<host-ip>:9092` and SASL_SSL on `<host-ip>:9094`. Both require SASL/PLAIN credentials; anonymous access is disabled.
- Where to find them:
  - Endpoints: see `KAFKA_BOOTSTRAP_PLAINTEXT` and `KAFKA_BOOTSTRAP_SSL` in `user_info.env`.
  - Credentials: see `KAFKA_CLIENT_USER` and `KAFKA_CLIENT_PASSWORD` in `full-stack/kafka/.env` (password is stored only there).
- Quick kcat metadata check (replace placeholders with your values):
```bash
kcat -b 192.0.2.10:9092 \
  -X security.protocol=SASL_PLAINTEXT \
  -X sasl.mechanism=PLAIN \
  -X sasl.username=client_user \
  -X sasl.password='client_password' \
  -L
```
- Expected result: broker list output similar to `Metadata for all topics...`; it will fail without the correct SASL username/password or if you target the SSL port without TLS flags.
- Kafka UI (`http://localhost:8080`) is bound to loopback for safety; reach it from the host or via SSH tunnel.

## SSL/TLS and certificates
- **Important**: This setup uses self-signed certificates for CKAN (port 8443) and other HTTPS endpoints. These are suitable for development and testing but **not recommended for production**.
- To use real certificates in production:
  - Obtain valid certs from a trusted CA (e.g., Let's Encrypt).
  - Update the CKAN `.env` to point to your certificate files in `full-stack/ckan/.env`.
  - Update any JupyterHub TLS configuration if those services are exposed externally.
  - For Kafka SSL (port 9094), replace the self-signed certs in `full-stack/kafka/certs/` with your signed certs.
  - Clients must either trust your CA or skip verification (not recommended for production).
- See the individual service READMEs in `full-stack/*/` for service-specific certificate configuration details.

## Notes and caveats
- The script may run `sudo apt-get install` and the Docker convenience script if Docker is absent.
- JupyterHub Keycloak URLs are derived from `idp_host` and `realm_name` in the federation config; callback and logout URLs use the detected host IP on port 8002.
- Kafka external listeners use the detected host IP so other containers/services can reach the broker via SASL_PLAINTEXT/SSL.
- Pre-CKAN support is enabled only when both `pre_ckan_url` and `pre_ckan_key` are present in the federation config.

## Troubleshooting
- If Docker permissions fail after install, log out/in or ensure your user is in the `docker` group.
- To inspect logs: `docker compose -f full-stack/ckan/docker-compose.yml logs -f` (adjust path/service as needed).
- If CKAN is unhealthy, re-run `setup.sh` after giving containers time to initialize; the CKAN step is idempotent.
- Verify ports are free if services refuse to start; adjust compose port mappings if necessary.

## Cleanup
To stop services without removing data:
```bash
(cd full-stack/ckan && docker compose down)
(cd full-stack/kafka && docker compose -f docker-compose.generated.yml down)
(cd full-stack/jhub && docker compose down)
(cd full-stack/ep-api && docker compose down)
```
To remove everything, delete the `full-stack/` directory and related `.env` files (this will remove persisted configs and secrets).
