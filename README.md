# ☁️ Self GCP Run — VLESS + gRPC + Web Status

Run **Xray VLESS over gRPC** on Google Cloud Run and show a small status page when the service URL is opened in a browser.

> **Safety:** the gRPC fix is on `main`. Build and deploy to a separate Cloud Run test service first; do not replace a working production service until both the browser endpoint and a VLESS client work. Never commit your real UUID or an `.env` file. If a real UUID has been pasted into chat, a public issue, or any other shared place, rotate it and update Secret Manager.

## ✨ What this version does

- 🌐 Serves a simple status page at `/` and `OK` at `/healthz`.
- 🔐 Uses Cloud Run HTTPS/TLS at the edge and HTTP/2 to the Envoy container.
- 🚇 Routes gRPC requests to a local Xray VLESS inbound.
- 🔑 Reads the VLESS UUID from a runtime environment variable; use Secret Manager on Cloud Run.
- 🧭 Keeps the Xray listener on loopback port `10000`; Envoy listens on Cloud Run's container port `8080`.

## 🧱 Architecture

```text
VLESS client ── gRPC + TLS / HTTP/2 ──> Cloud Run HTTPS
                                             │ HTTP/2
                                             ▼
                                       Envoy :8080
                                      /            \
                             Browser /              \ application/grpc
                                    ▼                ▼
                              Status page       Xray :10000
                                                     │
                                                freedom outbound
```

The status page is **not** a VLESS connectivity test. Cloud Run terminates public TLS; do not configure TLS inside Xray for this deployment. Envoy must preserve the gRPC request path and forward upstream using HTTP/2.

## 📁 Files

| File | Purpose |
|---|---|
| `Dockerfile` | Packages Envoy and Xray into one container |
| `envoy.yaml` | Browser status response and gRPC routing |
| `config.template.json` | Xray VLESS/gRPC inbound and freedom outbound |
| `entrypoint.sh` | Validates the UUID, renders config, starts both processes |
| `docker-compose.yml` | Local test container |
| `.dockerignore` | Excludes local secrets and Git metadata from builds |

## 1. Prerequisites

Install:
- Git
- Docker Desktop (for local testing)
- Google Cloud CLI (`gcloud`)
- A Google Cloud project with billing enabled
- A private VLESS UUID that you control

Set your project and region in Git Bash:

```bash
export PROJECT_ID="YOUR_GOOGLE_CLOUD_PROJECT_ID"
export REGION="asia-southeast1"
export AR_REPO="self-gcp-run"
export SERVICE="self-gcp-run-grpc-test"
gcloud config set project "$PROJECT_ID"
```

Replace the example project ID with yours. Keep your existing working service and its settings unchanged while testing.

## 2. Clone the main branch

For a new local checkout:

```bash
git clone --branch main https://github.com/Luzika0/self-gcp-run.git
cd self-gcp-run
```

For an existing checkout:

```bash
git fetch origin
git switch main
git pull --ff-only origin main
git status
```

Save or commit any local changes before switching branches.

## 3. Build and test locally

Build the image:

```bash
docker build -t self-gcp-run:test .
```

Run it locally in Git Bash:

```bash
read -rsp "VLESS UUID: " VLESS_UUID
echo
export VLESS_UUID
export GRPC_SERVICE_NAME=grpc
docker run --rm --name self-gcp-run-test \
  -p 127.0.0.1:8080:8080 \
  -e VLESS_UUID -e GRPC_SERVICE_NAME \
  self-gcp-run:test
```

In a second terminal, check the browser endpoints:

```bash
curl -i http://127.0.0.1:8080/
curl -i http://127.0.0.1:8080/healthz
```

Expected:
- `/` responds with HTTP `200` and a status page.
- `/healthz` responds with HTTP `200` and `OK`.

Stop the container with `Ctrl+C`. These checks only validate the browser endpoints. Test VLESS separately with a gRPC-capable client.

## 4. Enable Google Cloud APIs

```bash
gcloud services enable run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com
```

Create an Artifact Registry Docker repository once:

```bash
gcloud artifacts repositories create "$AR_REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --description="Self GCP Run container images"
```

If it already exists, skip the create command.

## 5. Build and push the container

```bash
export IMAGE_URI="$REGION-docker.pkg.dev/$PROJECT_ID/$AR_REPO/self-gcp-run:grpc"
gcloud builds submit --tag "$IMAGE_URI" .
```

Wait for Cloud Build to finish successfully before continuing.

## 6. Store the UUID in Secret Manager

Create the secret only if it does not already exist:

```bash
gcloud secrets create vless-uuid --replication-policy=automatic
```

If the secret already exists, skip that command. Add a new version securely from your local terminal:

```bash
read -rsp "VLESS UUID: " VLESS_UUID
echo
printf '%s' "$VLESS_UUID" | gcloud secrets versions add vless-uuid --data-file=-
unset VLESS_UUID
```

The UUID is entered locally and is not written into the repository. Avoid shell tracing while entering secrets.

Create a dedicated runtime service account once:

```bash
gcloud iam service-accounts create self-gcp-run-sa \
  --display-name="Self GCP Run test service"
```

If it already exists, skip the create command. Grant access to this secret:

```bash
gcloud secrets add-iam-policy-binding vless-uuid \
  --member="serviceAccount:self-gcp-run-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"
```

## 7. Deploy as a separate Cloud Run test service

This creates or updates the **test** service name in `$SERVICE`, not your existing `self-gcp-run` service:

```bash
gcloud run deploy "$SERVICE" \
  --image="$IMAGE_URI" \
  --region="$REGION" \
  --platform=managed \
  --port=8080 \
  --use-http2 \
  --service-account="self-gcp-run-sa@$PROJECT_ID.iam.gserviceaccount.com" \
  --set-secrets="VLESS_UUID=vless-uuid:latest" \
  --set-env-vars="GRPC_SERVICE_NAME=grpc" \
  --min=0 \
  --max=1 \
  --allow-unauthenticated
```

Only use `--allow-unauthenticated` if you want the status page and proxy endpoint publicly reachable. VLESS UUID authentication is still required by Xray, but a public endpoint may attract unwanted traffic. For a private endpoint, configure Cloud Run ingress/IAM appropriately and ensure your client can reach it.

Cloud Run automatically provides `PORT`; Envoy listens on port `8080` in this image. `--use-http2` is essential for HTTP/2 end-to-end.

### Preserve network and billing settings

The example above does **not** configure VPC or Cloud NAT. If you require Cloud NAT for a stable outbound IP, inspect the existing service first and copy the appropriate networking settings to the test service. Do not create a duplicate VPC, subnet, Cloud Router, or NAT just for this migration.

Before applying any deployment command to an existing service, inspect its current configuration:

```bash
gcloud run services describe self-gcp-run --region="$REGION" --format=export
```

Preserve any needed VPC egress, ingress, CPU, memory, request timeout, concurrency, billing mode, scaling, and service-account options. A new test service will not automatically inherit these.

## 8. Verify the deployed browser endpoint

Get the test URL:

```bash
gcloud run services describe "$SERVICE" \
  --region="$REGION" \
  --format='value(status.url)'
```

Open the returned URL in a browser. Also test the health endpoint:

```bash
SERVICE_URL="$(gcloud run services describe "$SERVICE" --region="$REGION" --format='value(status.url)')"
curl -i "$SERVICE_URL/"
curl -i "$SERVICE_URL/healthz"
```

Both should return HTTP `200`. If not, inspect logs:

```bash
gcloud run services logs read "$SERVICE" --region="$REGION" --limit=100
```

## 9. VLESS client settings

Use these values in your client:

| Setting | Value |
|---|---|
| Protocol | VLESS |
| Address | Hostname from the Cloud Run URL (without `https://`) |
| Port | `443` |
| UUID | Your secret UUID |
| Encryption | `none` |
| Transport | gRPC |
| gRPC service name | `grpc` |
| TLS | Enabled |
| SNI / Server name | Same hostname as the Cloud Run URL |
| ALPN | `h2`, if the client offers this setting |

Use a client version compatible with Xray VLESS/gRPC. Existing WebSocket profiles must be changed to gRPC; a WebSocket path is not used. For custom domains, configure the domain for Cloud Run and use that hostname consistently for address and SNI.

## 10. Troubleshooting

### Browser shows an upstream protocol error
1. Confirm the latest test revision is healthy.
2. Confirm the service was deployed with `--use-http2`.
3. Review Cloud Run logs and container startup output.
4. Check that Envoy starts and listens on `8080`.

### Browser works but VLESS does not
1. Confirm the client transport is gRPC, TLS is enabled, and the service name matches exactly.
2. Confirm the UUID matches the Secret Manager value.
3. Confirm Envoy routes `application/grpc` requests to Xray using HTTP/2.
4. Review Xray and Envoy logs.

### Container fails to start
1. Confirm the image builds successfully.
2. Confirm Xray binary is at `/usr/local/bin/xray` in the selected Xray image.
3. Confirm the Cloud Run runtime service account has Secret Manager access.
4. Check the revision logs for JSON parsing, binary, or configuration errors.

### Cost and NAT
- Keep minimum instances at zero unless you need warm capacity.
- Set a sensible maximum instance count and monitor CPU/memory and request usage.
- gRPC tunnels can be long-lived; test reconnect behavior and Cloud Run request timeout constraints.
- Cloud NAT processes outbound traffic; it does not provide the public HTTPS endpoint or fix HTTP/2 routing.
- Monitor Cloud Run, outbound transfer, Cloud NAT data processing, and static/external IP charges separately. gRPC does not guarantee lower cost.

## 🔒 Security checklist

- [ ] Keep the UUID out of Git, README files, screenshots, and chat.
- [ ] Use Secret Manager for the Cloud Run UUID.
- [ ] Limit maximum instances and monitor unexpected traffic.
- [ ] Test on a separate Cloud Run service before changing production.
- [ ] Keep your VPC/NAT configuration only if required and avoid duplicate resources.
- [ ] Pin image versions or digests after validation for reproducible production builds.

## 📚 Official documentation

- [Cloud Run HTTP/2](https://cloud.google.com/run/docs/configuring/http2)
- [Deploying to Cloud Run](https://cloud.google.com/run/docs/deploying)
- [Secret Manager](https://cloud.google.com/secret-manager/docs)
- [Direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc)
- [Cloud NAT overview](https://cloud.google.com/nat/docs/overview)
- [Cloud Run pricing](https://cloud.google.com/run/pricing)
