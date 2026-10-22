# ☁️ Self GCP Run

<p align="center">
  <strong>Deploy a VLESS over WebSocket proxy on Google Cloud Run</strong><br>
  Practical setup, networking, Cloud NAT, Standard Tier, and cost-control guide.
</p>

<p align="center">
  <a href="https://cloud.google.com/run/docs/configuring/vpc-direct-vpc"><img alt="Cloud Run" src="https://img.shields.io/badge/Google%20Cloud-Cloud%20Run-4285F4?logo=googlecloud&logoColor=white"></a>
  <a href="https://cloud.google.com/nat/docs/overview"><img alt="Cloud NAT" src="https://img.shields.io/badge/Networking-Cloud%20NAT-34A853?logo=googlecloud&logoColor=white"></a>
  <a href="https://cloud.google.com/vpc/network-pricing"><img alt="Network Tier" src="https://img.shields.io/badge/Network%20Tier-Standard-FBBC04?logo=googlecloud&logoColor=black"></a>
  <img alt="Guide" src="https://img.shields.io/badge/Guide-End--to--end-6C63FF">
</p>

---

## 👋 Welcome

This repository runs an **Xray VLESS + WebSocket** inbound behind a small Go HTTP gateway on Cloud Run. The gateway serves a simple information page for ordinary browser requests and forwards WebSocket upgrades to Xray.

Use this guide to clone the code, configure the container, deploy it, connect Direct VPC egress, optionally route outbound traffic through Cloud NAT, and review costs.

> [!CAUTION]
> **Protect your UUID/secret.** The Docker image does not contain your UUID. Supply `VLESS_UUID` at runtime: pass `VLESS_UUID` as a runtime environment variable when starting Docker and use Secret Manager for Cloud Run. Never commit real credentials to Git. If a real UUID was exposed, rotate it and update your clients.

> [!IMPORTANT]
> **Standard Network Service Tier is not free or unlimited.** Cloud Run compute, NAT gateway usage, NAT data processing, external IP addresses, and internet data transfer can all incur charges. Check current prices for your region before changing a working service.

> [!TIP]
> **Quick cost reality check:** A low request rate does not automatically mean a low bill. For a continuously running service, even **0.5 requests/second** is about **43,200 requests/day** or **1.296 million requests over 30 days**. That can be below the commonly advertised 2-million-request Cloud Run free-tier allowance, but the allowance is not a promise that the whole service is free: compute, long-lived connections, outbound data transfer, NAT processing, and IP/gateway charges are separate considerations. Check the current pricing and your own billing account's remaining free-tier allowance.


## 📚 Quick navigation

- [Architecture](#-architecture)
- [Before you begin](#-before-you-begin)
- [1. Clone the repository](#1-clone-the-repository)
- [2. Set project variables](#2-set-project-variables)
- [3. Inspect existing networking](#3-inspect-existing-networking)
- [4. Create or configure VPC and subnet](#4-create-or-configure-vpc-and-subnet)
- [5. Configure Cloud Router and Cloud NAT](#5-configure-cloud-router-and-cloud-nat)
- [6. Configure UUID and WebSocket path](#6-configure-uuid-and-websocket-path)
- [🐳 Run with Docker Compose](#-run-with-docker-compose)
- [7. Build the container image](#7-build-the-container-image)
- [8. Deploy to Cloud Run](#8-deploy-to-cloud-run)
- [9. Choose VPC egress routing](#9-choose-vpc-egress-routing)
- [10. Configure your VLESS client](#10-configure-your-vless-client)
- [11. Verify and troubleshoot](#11-verify-and-troubleshoot)
- [⚡ Xray and Cloud Run performance tuning](#-xray-and-cloud-run-performance-tuning)
- [📊 Request rate and realistic cost expectations](#-request-rate-and-realistic-cost-expectations)
- [💸 Cost optimization](#-cost-optimization)
- [🔗 Official documentation](#-official-documentation)

## 🗺️ Architecture

### With all outbound traffic routed through Cloud NAT

```text
VLESS client
    │ HTTPS / WebSocket (TLS)
    ▼
Cloud Run public HTTPS endpoint
    │
    ▼
Go gateway ───────► Xray (VLESS)
                         │ outbound connection
                         ▼
                  Direct VPC egress
                         │
                         ▼
                    VPC subnet
                         │
                         ▼
                Cloud Router + NAT
                         │
                         ▼
                  Public internet
```

Cloud NAT is for outbound connections from resources using the VPC. It does **not** provide the inbound Cloud Run URL or a public inbound IP for your service. The Cloud Run HTTPS endpoint and the NAT egress IP serve different purposes.

## ✅ Before you begin

You need:

- A Google Cloud project with billing enabled.
- Google Cloud CLI (`gcloud`) in Cloud Shell or installed locally.
- Permission to manage Cloud Run, Cloud Build, Artifact Registry, VPC, Cloud Router, and Cloud NAT.
- A region and an available, non-overlapping subnet range.
- A fresh VLESS UUID and a WebSocket path.
- An understanding of which outbound route you need: a fixed NAT IP, or lower NAT usage without a fixed NAT egress IP.

**Safety first:** Inspect resources before creating them. Reuse an existing VPC, subnet, router, and NAT gateway whenever possible; duplicate resources can add cost and make troubleshooting harder.

## 1. Clone the repository

Run in Cloud Shell or a terminal with Git installed:

```bash
git clone https://github.com/Luzika0/self-gcp-run.git
cd self-gcp-run

# Review the files before building
ls -la
```

Main files:

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the gateway and Xray container |
| `gateway.go` | Serves the browser page and forwards WebSocket traffic |
| `config.template.json` | Xray inbound/outbound configuration template |
| `entrypoint.sh` | Validates environment variables and starts Xray and the gateway |

Cloud Run routes HTTP traffic to the gateway on port `8080`. Xray listens internally on `XRAY_PORT` (default `8081`). The client WebSocket path must match `WS_PATH` exactly.

## 2. Set project variables

The values below match the example deployment. Change them if your project or resource names differ.

```bash
export PROJECT_ID="project-a733d9b6-3591-4ac1-b42"
export REGION="asia-southeast1"
export SERVICE="self-gcp-run"

export NETWORK="cloud-run-sg"
export SUBNET="cloudrun-standard-vpc-sg"
export ROUTER="nat-sg"
export NAT="cloudrun-standard-vpc-sg"

export AR_REPO="self-gcp-run"
export IMAGE_NAME="self-gcp-run"

gcloud config set project "$PROJECT_ID"
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  compute.googleapis.com
```

If using Cloud Shell, you may already be authenticated. Check the selected project before running commands:

```bash
gcloud config get-value project
```

## 3. Inspect existing networking

Run these commands before creating anything:

```bash
gcloud run services describe "$SERVICE" --region="$REGION"

gcloud compute networks list
gcloud compute networks subnets list --regions="$REGION"
gcloud compute routers list --regions="$REGION"

gcloud compute routers nats list \
  --router="$ROUTER" \
  --region="$REGION"
```

If the NAT gateway exists, inspect it:

```bash
gcloud compute routers nats describe "$NAT" \
  --router="$ROUTER" \
  --region="$REGION"
```

If a command says a resource is missing, verify the project, name, and region before creating it. Direct VPC egress requires sufficient free subnet IP addresses for running instances and deployment overlap. Use a non-overlapping subnet and follow current Google Cloud subnet sizing guidance.

## 4. Create or configure VPC and subnet

**Skip this section if your VPC and subnet already exist.** Check your address plan before using the sample range.

```bash
# Create a custom-mode VPC only if it does not exist
gcloud compute networks create "$NETWORK" \
  --subnet-mode=custom

# Create a subnet only if it does not exist
gcloud compute networks subnets create "$SUBNET" \
  --network="$NETWORK" \
  --region="$REGION" \
  --range="10.10.0.0/26"
```

The sample range `10.10.0.0/26` is only an example. Confirm it does not overlap with any existing VPC, VPN, or connected network. Do not run create commands against existing resources; inspect and reuse them.

## 5. Configure Cloud Router and Cloud NAT

### 5.1 Create a Cloud Router only if needed

```bash
gcloud compute routers create "$ROUTER" \
  --network="$NETWORK" \
  --region="$REGION"
```

Skip this command if the router already exists in the correct region and is attached to the intended VPC.

### 5.2 Create a NAT gateway only if needed

First verify that no existing NAT gateway covers the Cloud Run subnet. If you need a new one, check the current Google Cloud CLI documentation and supported endpoint types for your configuration before running:

```bash
gcloud compute routers nats create "$NAT" \
  --router="$ROUTER" \
  --region="$REGION" \
  --nat-custom-subnet-ip-ranges="$SUBNET" \
  --endpoint-types=ENDPOINT_TYPE_VM \
  --auto-allocate-nat-external-ips \
  --auto-network-tier=STANDARD
```

This example requests automatic NAT external IP allocation at **Standard Network Service Tier** for the selected subnet. The supported configuration can depend on the endpoint types and current Google Cloud features. If the command is rejected, check the current Cloud NAT documentation rather than repeatedly creating or replacing resources.

Verify the result:

```bash
gcloud compute routers nats describe "$NAT" \
  --router="$ROUTER" \
  --region="$REGION"

gcloud compute routers get-nat-ip-info "$ROUTER" \
  --region="$REGION"
```

> [!WARNING]
> Changing NAT IP allocation or replacing an IP can interrupt active connections and affect upstream IP allowlists. Do not change a working NAT gateway without checking its current configuration and planning for reconnection.

### Do I need a static outbound IP?

A known NAT IP is useful if a destination server allowlists your outbound IP. If you do not need a fixed IP, you may be able to simplify networking, but confirm the impact on your application first. Automatic allocation can use multiple addresses as capacity changes; verify the actual IPs rather than assuming there will be only one.

## 6. Configure UUID and WebSocket path

Generate a unique UUID in Cloud Shell or a Linux/Git Bash terminal with `uuidgen`:

```bash
uuidgen
```

Set the values for the deployment shell. Replace the examples with your own values:

```bash
export VLESS_UUID="REPLACE_WITH_YOUR_GENERATED_UUID"
export WS_PATH="/replace-with-a-long-random-path"
```

Keep the UUID private. For production, prefer Secret Manager over a plain environment variable. If using Secret Manager, grant the Cloud Run service identity access and map the secret to `VLESS_UUID`; do not put a real UUID into source control or a shared command history.

The WebSocket path must be identical in Cloud Run and the VLESS client. If you change it, update every authorized client.


## 🐳 Run with Docker Compose

All settings are passed to the running container as environment variables. **You do not need a `.env` file.** The Docker image contains no real UUID or secret. Docker Compose publishes the gateway only on `127.0.0.1:8080`; Xray stays internal to the container.

### 1. Set variables in your terminal

**Git Bash / Linux / macOS:**

```bash
export VLESS_UUID="PASTE_YOUR_EXISTING_UUID_SECRET_HERE"
export WS_PATH="/replace-with-a-long-random-path"
```

**Windows PowerShell:**

```powershell
$env:VLESS_UUID = "PASTE_YOUR_EXISTING_UUID_SECRET_HERE"
$env:WS_PATH = "/replace-with-a-long-random-path"
```

Use your existing UUID secret locally; do not paste it into GitHub or this README. Keep the WebSocket path identical in your VLESS client.

### 2. Build and start with Docker Compose

```bash
docker compose up -d --build
docker compose ps
docker compose logs --tail=100
```

Compose passes `VLESS_UUID` and `WS_PATH` from your shell into the container at startup. If either required variable is missing, Compose stops with a clear error instead of starting with a sample secret.

Open `http://127.0.0.1:8080` on the Docker host to verify the information page. For a remote server, configure a TLS reverse proxy in front of this local-only port and enable WebSocket forwarding. Configure the VLESS client with the public hostname, TLS enabled, WebSocket transport, your UUID, and the same `WS_PATH`.

### 3. Stop or rebuild

```bash
docker compose down
docker compose up -d --build
```

### 4. Run directly with `docker run` (no Compose)

**Git Bash / Linux / macOS:**

```bash
docker build -t self-gcp-run:local .
docker run -d --name self-gcp-run \
  --restart unless-stopped \
  -p 127.0.0.1:8080:8080 \
  -e VLESS_UUID="$VLESS_UUID" \
  -e WS_PATH="$WS_PATH" \
  -e PORT=8080 \
  -e XRAY_PORT=8081 \
  self-gcp-run:local
```

**Windows PowerShell:**

```powershell
docker build -t self-gcp-run:local .
docker run -d --name self-gcp-run --restart unless-stopped `
  -p 127.0.0.1:8080:8080 `
  -e VLESS_UUID="$env:VLESS_UUID" `
  -e WS_PATH="$env:WS_PATH" `
  -e PORT=8080 -e XRAY_PORT=8081 `
  self-gcp-run:local
```

View logs with `docker logs --tail=100 self-gcp-run`; stop/remove with `docker rm -f self-gcp-run`. Environment variables are supplied when the container starts, not baked into the image. Users with Docker host access may inspect container environment variables, so protect access to the Docker host.

> [!WARNING]
> This configuration binds HTTP to host loopback for local testing or a same-host reverse proxy. Do not expose the port publicly without TLS and firewall rules. For production, use your hosting platform's secret manager when available. Environment variables avoid committing secrets to source control but are not a substitute for host access controls.

## 7. Build the container image

Create an Artifact Registry Docker repository only if it does not already exist:

```bash
gcloud artifacts repositories describe "$AR_REPO" \
  --location="$REGION" >/dev/null 2>&1 || \
gcloud artifacts repositories create "$AR_REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --description="Container images for self-gcp-run"
```

Build and push the image with Cloud Build:

```bash
export IMAGE_URI="$REGION-docker.pkg.dev/$PROJECT_ID/$AR_REPO/$IMAGE_NAME:latest"

gcloud builds submit --tag "$IMAGE_URI" .
```

Wait for the build to complete successfully. If a GitHub-connected Cloud Build trigger already deploys your branch, check its configuration to avoid triggering duplicate deployments.

## 8. Deploy to Cloud Run

The following command routes **all outbound traffic through the VPC**. Use it when you intentionally need the Cloud NAT path, for example to use a known NAT egress IP.

```bash
gcloud run deploy "$SERVICE" \
  --image="$IMAGE_URI" \
  --region="$REGION" \
  --port=8080 \
  --network="$NETWORK" \
  --subnet="$SUBNET" \
  --vpc-egress=all-traffic \
  --set-env-vars="XRAY_PORT=8081,VLESS_UUID=$VLESS_UUID,WS_PATH=$WS_PATH" \
  --max=1
```

**Before deploying:** If this is an existing production service, preserve its current ingress, authentication, CPU, memory, concurrency, timeout, and scaling configuration unless you deliberately want to change them. The example above is a starting point, not a complete copy of every possible production setting.

If clients need to connect directly to a public proxy endpoint, configure Cloud Run ingress and IAM intentionally. Allowing unauthenticated invocation makes the HTTPS endpoint publicly reachable; the VLESS UUID must remain secret and strong.

## 9. Choose VPC egress routing

This is the most important choice when balancing NAT costs and outbound IP requirements.

| Cloud Run setting | What it does | Use it when |
|---|---|---|
| **Route all traffic to the VPC** — `all-traffic` | Public outbound traffic follows the VPC route and can use Cloud NAT. | You need a known NAT egress IP or intentionally want all outbound traffic routed through the VPC. |
| **Route only requests to private IPs to the VPC** — `private-ranges-only` | Public internet destinations normally use Cloud Run's default egress path and bypass this VPC/NAT route. | You want to reduce NAT processing and do not require public traffic to use the NAT IP. |

### Switch to private-ranges-only

For an existing service, this changes the egress setting without deleting the VPC or NAT resources:

```bash
gcloud run services update "$SERVICE" \
  --region="$REGION" \
  --vpc-egress=private-ranges-only
```

To switch back:

```bash
gcloud run services update "$SERVICE" \
  --region="$REGION" \
  --vpc-egress=all-traffic
```

After changing the setting, test VLESS connectivity, outbound destinations, and any IP allowlists. Public outbound IP behavior may change.

> [!NOTE]
> `private-ranges-only` does **not** make public internet traffic free. It changes the route; data-transfer charges may still apply and may appear under different billing SKUs. Compare the total bill before and after the change.

## 10. Configure your VLESS client

Use the deployed Cloud Run service URL or your configured custom domain.

| Client field | Value |
|---|---|
| Protocol | VLESS |
| Server / address | Cloud Run hostname or configured custom domain |
| Port | `443` |
| Transport | WebSocket (`ws`) |
| TLS / security | Enabled |
| SNI | The hostname used by the client |
| WebSocket Host | Usually the same hostname |
| WebSocket path | Exactly the value of `WS_PATH` |
| UUID | Your private `VLESS_UUID` value |

Cloud Run provides HTTPS/TLS at its platform edge. Do not assume a custom hostname or path works until it has been configured and tested. Never copy a sample UUID from documentation into a production client.

## 11. Verify and troubleshoot

### Check the deployed service and revision

```bash
gcloud run services describe "$SERVICE" \
  --region="$REGION" \
  --format="yaml(status.url,status.latestReadyRevisionName,spec.template.metadata.annotations,spec.template.spec.containers)"
```

### Read recent logs

```bash
gcloud run services logs read "$SERVICE" \
  --region="$REGION" \
  --limit=100
```

### Test both the page and the proxy

1. Open the service URL in a browser and confirm the information page responds.
2. Connect an authorized VLESS client with the correct UUID, TLS, hostname, and WebSocket path.
3. Test browsing through the proxy.
4. If using Cloud NAT, compare the observed outbound IP from inside the running service with the configured NAT IP.
5. Check Cloud Run logs and Billing if connections fail or costs rise unexpectedly.

A successful browser page does not prove that the VLESS tunnel is working. HTTP status `101` indicates a successful WebSocket upgrade. A long-lived WebSocket can carry a large amount of data under one request, so request counts alone do not measure total proxy usage.

<details>
<summary><strong>❌ Outbound requests fail</strong></summary>

Check that the active Cloud Run revision uses the intended network and subnet, the NAT covers the subnet if you use `all-traffic`, DNS resolves, egress firewall rules allow the destination, NAT ports are available, and the upstream server permits the connection.

</details>

<details>
<summary><strong>🌍 The outbound IP is not the NAT IP</strong></summary>

Confirm that the service uses `--vpc-egress=all-traffic`, the correct network/subnet, and the intended active revision. Test from inside the running Cloud Run service, not from your laptop. With `private-ranges-only`, public destinations normally do not use the NAT egress IP.

</details>

<details>
<summary><strong>🔌 Connections drop after a network change</strong></summary>

NAT IP replacement or routing changes can interrupt active sessions. Verify the new configuration, test client reconnection, and plan changes carefully if clients depend on a fixed IP.

</details>

<details>
<summary><strong>🐢 Standard Tier is slower than expected</strong></summary>

Benchmark latency, throughput, and reliability from your actual client locations. Compare Standard and Premium Network Service Tier for your use case; choose based on total cost and performance, not tier name alone.

</details>

## ⚡ Xray and Cloud Run performance tuning

This repository currently uses **VLESS + WebSocket**: Cloud Run terminates HTTPS, the Go gateway forwards WebSocket upgrades to Xray on localhost, and Xray uses the `freedom` outbound. This is a lightweight design; avoid adding another proxy, TLS layer, or sidecar unless measurements show a real need.

### Recommended baseline for balanced cost and throughput

| Area | Recommended baseline | Why / trade-off |
|---|---|---|
| Transport | Keep the working VLESS + WebSocket path | Changing to another transport requires client and server changes and may break existing clients. |
| Cloud Run network | Keep Direct VPC egress and `all-traffic` when the NAT egress IP is required | Preserves the intended Cloud NAT path and Standard Tier configuration. |
| Execution environment | Test **second generation** for sustained proxy traffic with Direct VPC egress | Google documents better networking performance, especially with packet loss. It requires at least 512 MiB memory and can have slower cold starts. |
| Memory | Start from the currently working 512 MiB setting; inspect peak usage and restarts before changing it | Too little memory can cause restarts or instability; extra memory can increase cost under some billing configurations. |
| CPU / billing | Keep current CPU and billing mode until you benchmark sustained WebSocket traffic | Instance-based and request-based billing behave differently for long-lived sessions. Compare the actual bill before switching. |
| Scaling | Keep minimum instances at zero if cold starts are acceptable; set a tested maximum | A low maximum limits scale-out costs but can cap concurrent sessions and throughput. |
| Xray outbound | Keep the existing `freedom` outbound unless you intentionally need a different route | Extra routing, DNS, or proxy layers can add latency and failure points. |
| Logging | Do not enable debug logging for normal operation | Debug logs add noise and can increase log ingestion costs. Enable temporarily when troubleshooting, then revert. |
| MTU | Keep the VPC network at Google's recommended default MTU of 1460 for Cloud Run | Do not try random MTU changes as a performance tweak. |

Official references: [Cloud Run networking best practices](https://cloud.google.com/run/docs/configuring/networking-best-practices), [execution environments](https://cloud.google.com/run/docs/configuring/execution-environments), and [Direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc).

### Test second-generation execution without changing the NAT route

This is an **optional performance experiment**, not a required change. Run it only when you are ready to create a new Cloud Run revision and test it. It does not change the repository or run automatically during a build:

```bash
gcloud run services update "$SERVICE" \
  --region="$REGION" \
  --execution-environment=gen2
```

Keep the current network, subnet, `--vpc-egress=all-traffic`, Cloud NAT, memory, CPU, concurrency, timeout, and scaling settings unchanged during the first comparison. Check the new revision and confirm the NAT egress IP before deciding whether to keep it. Roll back by restoring the previous revision if the result is worse.

Second generation requires at least 512 MiB memory. It can improve sustained networking performance but does not guarantee a speed increase for every client or destination, and it does not make network transfer or Cloud NAT free.

### Benchmark correctly before changing Xray settings

1. Record a baseline from the same client and location: download speed, upload speed, latency, reconnect success, and the Cloud Run revision.
2. Test at least three conditions: idle/light browsing, one sustained download, and several simultaneous connections. Use lawful test destinations you control or are authorized to use.
3. In Cloud Monitoring, compare instance CPU and memory, instance count, request count, and restarts. In Cloud Billing, compare Cloud NAT data processing and network data-transfer GiB separately.
4. Change **one setting at a time** and repeat the same tests. Keep the change only if performance or total cost improves without breaking connections.
5. For throughput, remember Cloud Run documents up to 1 Gbps per individual instance for Direct VPC egress; this is a platform ceiling, not a speed guarantee. Destination capacity, client network, packet loss, and NAT/network routing can all be bottlenecks.

### Avoid these common “optimization” mistakes

- Do not switch to `private-ranges-only` if public proxy traffic must exit through your Cloud NAT IP.
- Do not raise the maximum instance count just to chase speed without checking NAT capacity, cost, and concurrency.
- Do not reduce memory based only on average usage; use peak usage and restart history.
- Do not assume a low HTTP request rate means low bandwidth: one WebSocket can carry a long, high-volume session.
- Do not add compression to the proxy by default; it can consume CPU and usually does not help already-compressed HTTPS traffic carried through the tunnel.
- Do not enable WebSocket heartbeat or change Xray transport settings without confirming client compatibility and measuring whether idle connections actually need it.
- Do not replace the working WebSocket transport with XHTTP, gRPC, or another protocol as a “drop-in” tuning change; it requires compatibility checks and client-side changes.

## 📊 Request rate and realistic cost expectations

### What does 0.5 requests/second mean?

If Cloud Monitoring really shows an average of **0.5 HTTP requests per second continuously**, the arithmetic is:

| Period | Approximate requests |
|---|---:|
| 1 second | 0.5 |
| 1 minute | 30 |
| 1 hour | 1,800 |
| 1 day | 43,200 |
| 30 days | 1,296,000 |

These are request counts, **not a cost estimate**. The real bill depends on how long requests remain open, CPU and memory configuration, data transferred, region, billing mode, free-tier eligibility/remaining allowance, and networking resources.

### Important for VLESS over WebSocket

- A WebSocket connection normally starts with an HTTP upgrade request and then remains open. One long-lived WebSocket is not the same as a new HTTP request every second.
- If a chart shows **0.5 requests/second**, first confirm which metric it is measuring. It might be request rate, connection activity, or another metric; do not treat it as a direct measurement of active users or bandwidth.
- A small number of long-lived connections can transfer many GiB while producing relatively few HTTP requests.
- Repeated reconnects, health checks, browser refreshes, and client retry loops can increase request counts without representing useful proxy traffic.
- A successful information page or a low request count does not prove that Cloud NAT is carrying the proxy's outbound data.

### Find what is actually costing money

1. Open [Cloud Billing Reports](https://console.cloud.google.com/billing/reports) and select the correct billing account, project, and date range.
2. Group or filter costs by **SKU**. Review Cloud Run CPU, Cloud Run memory, Cloud Run requests, network data transfer, Cloud NAT data processing, Cloud NAT gateway usage, and external IP usage separately.
3. Compare the **usage quantity** as well as the dollar amount. For network SKUs, check the billed GiB; for Cloud Run, check the CPU/memory usage and request quantity where available.
4. Allow for billing data to update before judging a configuration change. Compare equivalent time windows and similar traffic.
5. Create a budget alert. A budget alert is a notification, **not** an automatic spending cap or shutdown.

### Which network configuration should I choose?

| Your goal | Configuration to evaluate | Trade-off |
|---|---|---|
| Route public outbound traffic through the NAT gateway and use its egress IP | Direct VPC egress with `all-traffic`, plus a correctly configured Cloud NAT | NAT processing, gateway/IP usage, and internet data transfer may all be billed. |
| Use VPC/NAT only for private destinations | `private-ranges-only` | Public destinations normally bypass this VPC/NAT route; they will not use the NAT egress IP, and other network transfer charges may still apply. |
| Only expose the Cloud Run HTTPS endpoint; no container-initiated internet traffic needs NAT | Reassess whether Cloud NAT is needed at all | Removing NAT can break outbound connections or fixed-IP requirements. Do not remove it until those dependencies are tested. |

**For this repository's proxy use case:** client traffic that the container forwards to public internet destinations is outbound traffic. If you deliberately need that traffic to use your Standard-tier NAT IP, keep the intended VPC egress route and verify it with an actual outbound-IP test and billing SKU data. Switching to `private-ranges-only` can reduce NAT processing, but it also changes the public egress path and may defeat the fixed-IP/Standard-tier objective. Compare the complete bill before deciding.

### A practical low-cost checklist

- [ ] Keep minimum instances at zero unless you have measured a real need for always-warm instances.
- [ ] Use the smallest CPU and memory settings that can handle real concurrent sessions without memory pressure or restarts.
- [ ] Set a sensible maximum-instance limit to reduce unexpected scale-out, while understanding that a low cap can cause connection failures under load.
- [ ] Check request-based versus instance-based billing and the current Cloud Run pricing rules. Long-lived WebSocket sessions can keep resources occupied; do not assume idle-looking proxy sessions cost nothing.
- [ ] Avoid unnecessary client reconnect loops and overly frequent health checks.
- [ ] Verify whether the service truly needs all outbound traffic to use Cloud NAT before paying for NAT processing.
- [ ] Do not delete or recreate NAT gateways/IPs merely to test costs; configuration changes can interrupt sessions and alter egress IPs.
- [ ] Track bytes/GiB and network SKUs. For a proxy, transferred data is often more important than HTTP request count.
- [ ] Use a budget alert and review the billing report regularly.

## 💸 Cost optimization

Use this checklist to review the largest cost drivers:

- [ ] **Network transfer:** Review outbound data-transfer SKUs first if bandwidth is your largest charge.
- [ ] **Cloud NAT processing:** NAT processing is separate from internet data transfer. If you do not need a NAT egress IP, test `private-ranges-only` and compare costs after billing data updates.
- [ ] **NAT gateway and IPs:** Check gateway uptime and external IP charges. Release only addresses confirmed to be unused.
- [ ] **Cloud Run compute:** Review CPU/memory billing, minimum instances, maximum instances, concurrency, and request timeout. Long-lived WebSocket sessions can keep instances active.
- [ ] **Reconnect behavior:** Avoid unnecessary background reconnect loops and repeated retries.
- [ ] **Data volume:** Monitor unusually large sessions and repeated downloads. VLESS transports data; it does not automatically compress the traffic.
- [ ] **Network tier:** Compare current Standard and Premium Tier prices, performance, and destination-dependent transfer costs.
- [ ] **Billing alerts:** Create budget alerts and review Cloud Run, Cloud NAT, IP, and transfer SKUs separately.

### Understand the bill

| Billing item | What it usually represents |
|---|---|
| Cloud NAT Data Processing | Traffic processed by Cloud NAT; charged separately from internet data transfer |
| Cloud NAT Gateway Uptime | NAT gateway usage |
| Cloud NAT IP Usage / Static IP | External IP allocation or usage, depending on the SKU |
| Cloud Run Internet Data Transfer Out | Outbound transfer billed under a Cloud Run network SKU |
| Carrier Peering / other Network Data Transfer Out | Outbound transfer billed under the specific network route and SKU |
| Cloud Run CPU / Memory | Compute resources used by the service |

Use [Cloud Billing Reports](https://console.cloud.google.com/billing/reports), filter to the same project and date range, and group by SKU. Compare **both cost and usage quantity (GiB)** before and after a routing change. A budget alert notifies you; it does not automatically stop spending.

## 🔗 Official documentation

| Topic | Guide |
|---|---|
| Direct VPC egress | [Configure Direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc) |
| Cloud Run networking | [Networking best practices](https://cloud.google.com/run/docs/configuring/networking-best-practices) |
| Cloud NAT concepts | [Cloud NAT overview](https://cloud.google.com/nat/docs/overview) |
| Cloud NAT setup | [Set up and manage Public NAT](https://cloud.google.com/nat/docs/set-up-manage-network-address-translation) |
| Network pricing | [VPC network pricing](https://cloud.google.com/vpc/network-pricing) |
| Cloud Run pricing | [Cloud Run pricing](https://cloud.google.com/run/pricing) |
| Artifact Registry | [Create Docker repositories](https://cloud.google.com/artifact-registry/docs/docker/store-docker-container-images) |

---

<p align="center">
  <strong>☁️ Configure carefully · Verify egress · Protect credentials · Monitor costs</strong><br>
  <sub>Community documentation for learning and planning. Review current Google Cloud documentation and pricing before changing production networking.</sub>
</p>
