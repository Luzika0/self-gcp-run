# ☁️ Self GCP Run — VLESS + gRPC

Deploy Xray VLESS over gRPC directly on Google Cloud Run. This branch replaces the old WebSocket gateway with a native Xray gRPC inbound; the old browser information page is removed.

## Architecture

```text
VLESS client -- gRPC over TLS/HTTP2 --> Cloud Run HTTPS endpoint
           -- HTTP/2 cleartext (h2c) --> Xray VLESS gRPC :8080
           --> freedom outbound --> Internet
```

**Important:** enable Cloud Run end-to-end HTTP/2. Existing WebSocket client profiles will not work; switch the client transport to gRPC. This repository change does not deploy or modify your live service.

## 1. Clone

```bash
git clone https://github.com/Luzika0/self-gcp-run.git
cd self-gcp-run
git switch feature-vless-grpc
```

## 2. Build and run locally

Git Bash / Linux / macOS:

```bash
export VLESS_UUID="YOUR_EXISTING_UUID"
export GRPC_SERVICE_NAME="grpc"
docker build -t self-gcp-run:grpc .
docker run --rm -p 127.0.0.1:8080:8080 -e VLESS_UUID="$VLESS_UUID" -e GRPC_SERVICE_NAME="$GRPC_SERVICE_NAME" -e PORT=8080 self-gcp-run:grpc
```

PowerShell:

```powershell
$env:VLESS_UUID = "YOUR_EXISTING_UUID"
$env:GRPC_SERVICE_NAME = "grpc"
docker build -t self-gcp-run:grpc .
docker run --rm -p 127.0.0.1:8080:8080 -e VLESS_UUID="$env:VLESS_UUID" -e GRPC_SERVICE_NAME="$env:GRPC_SERVICE_NAME" -e PORT=8080 self-gcp-run:grpc
```

Do not commit a real UUID. The image contains no UUID; supply it at runtime. Docker host administrators may inspect runtime environment variables.

## 3. Build and push

```bash
export PROJECT_ID="YOUR_PROJECT_ID"
export REGION="asia-southeast1"
export AR_REPO="self-gcp-run"
export IMAGE_URI="$REGION-docker.pkg.dev/$PROJECT_ID/$AR_REPO/self-gcp-run:grpc"
gcloud config set project "$PROJECT_ID"
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com
gcloud artifacts repositories create "$AR_REPO" --repository-format=docker --location="$REGION"
gcloud builds submit --tag "$IMAGE_URI" .
```

If the Artifact Registry repository already exists, skip the create command. Cloud Build builds and pushes the image; it does not deploy it.

## 4. Deploy to Cloud Run

First store your UUID in Secret Manager and grant the Cloud Run service identity access to the secret. If a secret already exists, reuse it. Example for creating a new secret:

```bash
gcloud secrets create vless-uuid --replication-policy=automatic
read -rsp "Paste VLESS UUID: " VLESS_UUID
printf '%s' "$VLESS_UUID" | gcloud secrets versions add vless-uuid --data-file=-
unset VLESS_UUID
```

Deploy with HTTP/2 end-to-end enabled:

```bash
gcloud run deploy self-gcp-run --image="$IMAGE_URI" --region="$REGION" --port=8080 --use-http2 --set-secrets="VLESS_UUID=vless-uuid:latest" --set-env-vars="GRPC_SERVICE_NAME=grpc" --max=1
```

Before updating an existing service, inspect its current settings and preserve any required VPC egress, ingress, authentication, CPU, memory, concurrency, timeout, and scaling options. This example does not configure VPC or Cloud NAT. Do not create duplicate network resources.

## 5. Client settings

| Setting | Value |
|---|---|
| Protocol | VLESS |
| Server | Cloud Run hostname or configured custom domain |
| Port | 443 |
| Transport | gRPC |
| TLS | Enabled |
| SNI | Same hostname as server |
| gRPC service name | `grpc` (or the exact `GRPC_SERVICE_NAME` value) |
| UUID | Your private runtime UUID |
| Encryption | `none` |

Client labels vary; use its gRPC service-name field, not a WebSocket path. Use a client mode compatible with the Xray gRPC configuration.

## 6. Optional VPC egress and Cloud NAT

Cloud NAT affects outbound routing only; it does not provide the public Cloud Run endpoint or gRPC/TLS. Use Direct VPC egress with `all-traffic` if public outbound traffic must use the NAT egress IP. `private-ranges-only` normally sends public destinations outside that VPC/NAT route. Inspect and reuse existing VPC, subnet, router, and NAT resources.

## 7. Troubleshooting and cost

- If startup fails, inspect Cloud Run logs and confirm Xray starts with the rendered config and listens on the configured port.
- A browser page is not a gRPC health test; this image intentionally no longer serves the old information page.
- Existing WS profiles must be changed to gRPC, TLS enabled, and the same service name.
- For secret errors, grant the Cloud Run service identity Secret Manager Secret Accessor on the UUID secret.
- Moving to gRPC does not guarantee lower costs. Monitor Cloud Run CPU/memory, long-lived sessions, outbound data transfer, Cloud NAT processing, gateway usage, and external IP charges by SKU.
- Keep minimum instances at zero unless warm capacity is required; use a sensible maximum and test concurrency.

Official docs: [Cloud Run HTTP/2](https://cloud.google.com/run/docs/configuring/http2) · [Direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc) · [Cloud NAT](https://cloud.google.com/nat/docs/overview) · [Cloud Run pricing](https://cloud.google.com/run/pricing) · [Secret Manager](https://cloud.google.com/secret-manager/docs)

**Protect your UUID. Verify the new revision and client connectivity before considering the migration complete.**
