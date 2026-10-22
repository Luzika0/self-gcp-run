# ☁️ Self GCP Run

<p align="center">
  <strong>Run Cloud Run with controlled outbound networking and cost-aware egress</strong><br/>
  A practical guide to Direct VPC egress, Cloud Router, Public Cloud NAT, and Standard Network Service Tier.
</p>

<p align="center">
  <a href="https://cloud.google.com/run/docs/configuring/vpc-direct-vpc"><img alt="Cloud Run" src="https://img.shields.io/badge/Google%20Cloud-Cloud%20Run-4285F4?logo=googlecloud&logoColor=white"/></a>
  <a href="https://cloud.google.com/nat/docs/overview"><img alt="Cloud NAT" src="https://img.shields.io/badge/Networking-Cloud%20NAT-34A853?logo=googlecloud&logoColor=white"/></a>
  <a href="https://cloud.google.com/vpc/network-pricing"><img alt="Network Tier" src="https://img.shields.io/badge/Network%20Tier-Standard-FBBC04?logo=googlecloud&logoColor=black"/></a>
  <img alt="Docs" src="https://img.shields.io/badge/Docs-Setup%20Guide-6C63FF"/>
</p>

---

## 🚀 End-to-end guide: clone → container → Cloud Run → VPC/NAT

This is the start-to-finish path for deploying this repository as a VLESS over WebSocket proxy on Cloud Run. The examples use the project and network names from the example deployment; change them if your resources differ.

> [!CAUTION]
> **Do not use the repository's sample/default UUID in production.** The Dockerfile and entrypoint currently include a public example fallback. Always override it with your own UUID at deployment, use a non-obvious WebSocket path, and rotate the UUID if it was exposed. A public Cloud Run endpoint can be reached by anyone who knows its URL; the VLESS UUID is the proxy credential.

### 1. Clone the repository

Run in Cloud Shell or a terminal with Git installed:

\`\`\`bash
git clone https://github.com/Luzika0/self-gcp-run.git
cd self-gcp-run

# Review the container and proxy configuration before deploying
ls -la
cat Dockerfile
cat config.template.json
cat entrypoint.sh
\`\`\`

The container includes Xray, the Go HTTP/WebSocket gateway, and a startup script. Cloud Run sends HTTP traffic to the gateway on port \`8080\`; Xray listens internally on \`XRAY_PORT\` (default \`8081\`). The client WebSocket path must exactly match \`WS_PATH\`.

### 2. Set your Google Cloud variables

These values match the current example environment. Confirm the project, region, and resources before running deployment commands.

\`\`\`bash
export PROJECT_ID="project-a733d9b6-3591-4ac1-b42"
export REGION="asia-southeast1"
export SERVICE="self-gcp-run"
export NETWORK="cloud-run-sg"
export SUBNET="cloudrun-standard-vpc-sg"
export ROUTER="nat-sg"
export NAT="cloudrun-standard-vpc-sg"
export AR_REPO="self-gcp-run"
export IMAGE="self-gcp-run"

gcloud auth login
gcloud config set project "$PROJECT_ID"
gcloud services enable run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  compute.googleapis.com
\`\`\`

If you are already in authenticated Cloud Shell, \`gcloud auth login\` may not be necessary. Use \`gcloud config get-value project\` to check the selected project.

### 3. Inspect your existing VPC and Cloud NAT first

Do not create duplicate resources if your VPC, subnet, router, or NAT gateway already exists.

\`\`\`bash
gcloud compute networks describe "$NETWORK"
gcloud compute networks subnets describe "$SUBNET" --region="$REGION"
gcloud compute routers describe "$ROUTER" --region="$REGION"
gcloud compute routers nats list --router="$ROUTER" --region="$REGION"

# Inspect the specific NAT gateway if it exists
gcloud compute routers nats describe "$NAT" \
  --router="$ROUTER" \
  --region="$REGION"
\`\`\`

If a command reports that a resource is missing, verify the name, project, and region before creating it. The subnet must have enough free IP addresses for Direct VPC egress instances and deployment overlap. Use a non-overlapping range and follow the current Google Cloud subnet sizing guidance.

### 4. Configure the container's credentials and path

Generate a fresh UUID locally:

\`\`\`bash
# Git Bash / Linux / Cloud Shell with uuidgen installed
uuidgen
\`\`\`

Copy the generated value into a secure place. Do not commit it to \`config.template.json\`, the README, or Git. Choose a WebSocket path that you control and keep it identical in Cloud Run and the client:

\`\`\`bash
export VLESS_UUID="REPLACE_WITH_YOUR_GENERATED_UUID"
export WS_PATH="/replace-with-a-long-random-path"
\`\`\`

The commands below pass these values to Cloud Run as environment variables. For production, Secret Manager is preferable for the UUID; do not put it in a public repository or paste it into screenshots/issues. If you store the UUID in Secret Manager, configure the Cloud Run service to access the secret and map it to \`VLESS_UUID\` rather than using the plain environment-variable example.

### 5. Build and push the container image

Create an Artifact Registry Docker repository only if it does not already exist:

\`\`\`bash
gcloud artifacts repositories describe "$AR_REPO" \
  --location="$REGION" >/dev/null 2>&1 || \
gcloud artifacts repositories create "$AR_REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --description="Container images for self-gcp-run"

export IMAGE_URI="$REGION-docker.pkg.dev/$PROJECT_ID/$AR_REPO/$IMAGE:latest"

gcloud builds submit --tag "$IMAGE_URI" .
\`\`\`

Wait for Cloud Build to finish successfully. If the repository uses a connected Cloud Build trigger, pushing to its configured branch may also build and deploy automatically; avoid triggering two deployments at the same time. Check the active revision after any build.

### 6. Deploy the Cloud Run service with Direct VPC egress

The following command uses the existing VPC and routes all outbound traffic through it. This is the option to use when you deliberately want public outbound traffic to pass through Cloud NAT, for example to use a known NAT egress IP.

\`\`\`bash
gcloud run deploy "$SERVICE" \
  --image="$IMAGE_URI" \
  --region="$REGION" \
  --port=8080 \
  --network="$NETWORK" \
  --subnet="$SUBNET" \
  --vpc-egress=all-traffic \
  --set-env-vars="XRAY_PORT=8081,VLESS_UUID=$VLESS_UUID,WS_PATH=$WS_PATH" \
  --max=1
\`\`\`

If this is a new public proxy and clients must connect directly, configure Cloud Run ingress and IAM deliberately. Only grant unauthenticated invocation if that is intended for your design; the VLESS UUID still needs to be private and strong. For an existing service, preserve its current ingress, authentication, CPU/memory, timeout, concurrency, and scaling settings unless you intend to change them.

### 7. Configure Cloud Router and Cloud NAT (only if needed)

If the existing NAT gateway already covers the subnet used by Cloud Run, **do not create another one**. Confirm its subnet coverage, IP allocation, and network tier first:

\`\`\`bash
gcloud compute routers nats describe "$NAT" \
  --router="$ROUTER" \
  --region="$REGION" \
  --format="yaml(natIpAllocateOption,autoNetworkTier,natIps,subnetworks)"
\`\`\`

If you have verified that no suitable NAT gateway exists, create a router and NAT only after confirming the names, subnet, network, and IP plan. Example for a new setup:

\`\`\`bash
# Run only if this router does not already exist
gcloud compute routers create "$ROUTER" \
  --network="$NETWORK" \
  --region="$REGION"

# Run only if this NAT does not already exist.
# Verify current Cloud NAT CLI requirements and endpoint support first.
gcloud compute routers nats create "$NAT" \
  --router="$ROUTER" \
  --region="$REGION" \
  --nat-custom-subnet-ip-ranges="$SUBNET" \
  --endpoint-types=ENDPOINT_TYPE_VM \
  --auto-allocate-nat-external-ips \
  --auto-network-tier=STANDARD
\`\`\`

The NAT configuration must cover the subnet used by Direct VPC egress. Standard Network Service Tier can have different pricing and performance from Premium Tier, but **Standard Tier does not mean free or unlimited bandwidth**. Review current Cloud NAT and network transfer pricing for your region. If a static outbound IP is required, configure a reserved IP using the appropriate NAT allocation mode and verify the actual assigned address.

### 8. Choose the VPC traffic-routing option

| Cloud Run setting | What happens | When to choose it |
|---|---|---|
| **Route all traffic to the VPC** (\`all-traffic\`) | Public outbound traffic follows the VPC route and can use Cloud NAT. | Use when you need the NAT egress IP or want all outbound traffic routed through your VPC. |
| **Route only requests to private IPs to the VPC** (\`private-ranges-only\`) | Public internet destinations normally use Cloud Run's default egress path and bypass this VPC/NAT route. | Test this when reducing NAT processing charges is more important than keeping a fixed NAT egress IP. |

To change an existing service to private-ranges-only:

\`\`\`bash
gcloud run services update "$SERVICE" \
  --region="$REGION" \
  --vpc-egress=private-ranges-only
\`\`\`

To switch back:

\`\`\`bash
gcloud run services update "$SERVICE" \
  --region="$REGION" \
  --vpc-egress=all-traffic
\`\`\`

Changing to \`private-ranges-only\` does not make public internet transfer free. It changes the route and can change the egress billing SKUs. Public outbound IP behavior can also differ. Test the VLESS connection, outbound destination access, and any IP allowlists after changing the setting.

### 9. Verify deployment and test VLESS

\`\`\`bash
gcloud run services describe "$SERVICE" \
  --region="$REGION" \
  --format="yaml(status.url,status.latestReadyRevisionName,spec.template.metadata.annotations,spec.template.spec.containers)"

gcloud run services logs read "$SERVICE" \
  --region="$REGION" \
  --limit=100
\`\`\`

Use the service URL shown by Google Cloud. Typical VLESS client settings:

| Field | Value |
|---|---|
| Protocol | VLESS |
| Address | Cloud Run service hostname or configured custom domain |
| Port | \`443\` |
| Transport | WebSocket |
| TLS | Enabled |
| SNI / WebSocket Host | The hostname used by the client |
| WebSocket path | Exactly the value of \`WS_PATH\` |
| UUID | Your private \`VLESS_UUID\` value |

Test both the browser information page and an authorized VLESS client. A browser page loading successfully does not prove that Xray, WebSocket forwarding, and outbound internet connectivity all work. HTTP status \`101\` means the WebSocket upgrade succeeded; a long-lived session's logged response size can reflect a large stream, but it is not a complete two-way network billing report.

### 10. Monitor bandwidth and control costs

- In Cloud Billing, group costs by **SKU** and compare the same date range for Cloud NAT Data Processing, Cloud NAT IP Usage, NAT Gateway Uptime, Cloud Run internet data transfer, and other network transfer SKUs.
- Do not infer total tunnel usage from the number of HTTP requests. WebSocket sessions can carry hundreds of MiB over one request.
- Use Cloud Run metrics and application-level measurements to investigate large sessions, frequent reconnects, or unexpected traffic.
- Set Cloud Billing budget alerts. Alerts notify you; they do not automatically stop traffic.
- Remove only unused reserved external IPs after confirming they are not attached to Cloud NAT or another service.
- If a static outbound IP is not required, test \`private-ranges-only\` and compare the total bill after billing data updates. Do not compare only the NAT line item; public egress may appear under different SKUs.
- Review Cloud Run CPU/memory billing, minimum instances, maximum instances, request timeout, and client reconnect behavior. Do not reduce resources blindly if it causes failed or unstable long-lived connections.

## ✨ What this guide helps you do

| Goal | What you configure |
|---|---|
| 💸 Investigate lower network costs | Compare Standard Tier networking with Premium Tier for your traffic and region |
| 🌐 Route outbound traffic | Cloud Run **Direct VPC egress** with `all-traffic` |
| 🪪 Use a known outbound IP | Public Cloud NAT external IP(s), useful for upstream IP allowlists |
| 🔎 Troubleshoot networking | Commands to inspect VPC, Cloud Router, NAT, and Cloud Run settings |

> [!IMPORTANT]
> **Standard Tier does not mean free or unlimited bandwidth.** Cloud Run compute, Cloud NAT gateway usage, NAT data processing, external IP addresses, and internet data transfer may all cost money. Compare the current prices for your region before changing a working setup.

## 📚 Contents

- [End-to-end guide: clone → container → Cloud Run → VPC/NAT](#-end-to-end-guide-clone--container--cloud-run--vpcnat)
- [Architecture](#-architecture)
- [Prerequisites and variables](#-prerequisites-and-variables)
- [Step 1 — Inspect your current setup](#-step-1--inspect-your-current-setup)
- [Step 2 — Create a VPC and subnet if needed](#-step-2--create-a-vpc-and-subnet-if-needed)
- [Step 3 — Configure Cloud Router and Standard Tier NAT](#-step-3--configure-cloud-router-and-standard-tier-nat)
- [Step 4 — Connect Cloud Run to the VPC](#-step-4--connect-cloud-run-to-the-vpc)
- [Step 5 — Verify the outbound IP](#-step-5--verify-the-outbound-ip)
- [💸 Cost optimization checklist](#-cost-optimization-checklist)
- [🧰 Troubleshooting](#-troubleshooting)
- [🔗 Official documentation](#-official-documentation)

## 🗺️ Architecture

```text
                 INBOUND
Client ──────── HTTPS ────────> Cloud Run service
                                      |
                                      | OUTBOUND: all-traffic
                                      v
                                Direct VPC egress
                                      |
                                      v
                                   VPC subnet
                                      |
                                      v
                              Cloud Router + NAT
                              Standard Tier IP(s)
                                      |
                                      v
                              Internet / upstream
```

**Key distinction:** Cloud NAT provides outbound internet connectivity for connections initiated from the VPC and handles their return traffic. It does **not** change your inbound Cloud Run `run.app` URL or give Cloud Run a public inbound IP address.

## ✅ Prerequisites and variables

Before you start, you need:

- A Google Cloud project with billing enabled.
- The Google Cloud CLI (`gcloud`) installed, authenticated, and configured.
- Permission to configure Cloud Run, VPC networks/subnets, Cloud Router, and Cloud NAT.
- A region for your Cloud Run service and networking resources.
- A plan for a non-overlapping subnet CIDR range.

Set your values in Cloud Shell. Change every placeholder to match your project.

```bash
PROJECT_ID="YOUR_PROJECT_ID"
REGION="asia-southeast1"
SERVICE="google-cloud-run-proxy"
NETWORK="YOUR_VPC_NETWORK"
SUBNET="YOUR_SUBNET"
ROUTER="YOUR_CLOUD_ROUTER"
NAT="YOUR_CLOUD_NAT"

gcloud config set project "$PROJECT_ID"
gcloud services enable compute.googleapis.com run.googleapis.com
```

> [!TIP]
> Run the inspection commands first. Reuse existing resources when possible; do not create a second VPC, subnet, router, or NAT gateway just because the examples below show how.

## 🔍 Step 1 — Inspect your current setup

```bash
gcloud run services describe "$SERVICE" --region="$REGION"

gcloud compute networks list
gcloud compute networks subnets list --regions="$REGION"
gcloud compute routers list --regions="$REGION"

# Inspect NAT configurations on routers in this region
gcloud compute routers list --regions="$REGION"
```

For a known router, list its NAT gateways:

```bash
gcloud compute routers nats list \
  --router="$ROUTER" \
  --region="$REGION"
```

Direct VPC egress needs sufficient free subnet IP addresses for Cloud Run instances and deployment overlap. A subnet with a range of **/26 or larger** is a sensible starting point for this setup; choose a range that does not overlap with connected networks and check current Google Cloud requirements.

## 🧱 Step 2 — Create a VPC and subnet if needed

**Skip this section if your VPC and subnet already exist.** The example uses a custom-mode VPC and a sample private IPv4 range. Confirm the range is unused in your environment before running it.

```bash
gcloud compute networks create "$NETWORK" \
  --subnet-mode=custom

gcloud compute networks subnets create "$SUBNET" \
  --network="$NETWORK" \
  --region="$REGION" \
  --range="10.10.0.0/26"
```

This creates only the network and subnet. It does not create a Cloud Router or NAT gateway. If the command reports that a resource already exists, inspect and reuse that resource rather than deleting it.

## 🌐 Step 3 — Configure Cloud Router and Standard Tier NAT

### 3.1 Create a Cloud Router

Skip this if the router already exists in the selected region and is attached to the intended VPC.

```bash
gcloud compute routers create "$ROUTER" \
  --network="$NETWORK" \
  --region="$REGION"
```

### 3.2 Create Public Cloud NAT with Standard Tier IP allocation

For a new NAT gateway that covers the Cloud Run subnet:

```bash
gcloud compute routers nats create "$NAT" \
  --router="$ROUTER" \
  --region="$REGION" \
  --nat-custom-subnet-ip-ranges="$SUBNET" \
  --endpoint-types=ENDPOINT_TYPE_VM \
  --auto-allocate-nat-external-ips \
  --auto-network-tier=STANDARD
```

This example requests automatic NAT external IP allocation at **Standard Network Service Tier** for the selected subnet. Confirm the supported endpoint types and current CLI options for your networking configuration before applying it.

### 3.3 Verify the NAT configuration

```bash
gcloud compute routers nats describe "$NAT" \
  --router="$ROUTER" \
  --region="$REGION"

gcloud compute routers get-nat-ip-info "$ROUTER" \
  --region="$REGION"
```

> [!WARNING]
> If a router or NAT gateway already exists, do not rerun the create commands. Inspect its allocation mode and settings first. Changing NAT IP allocation or replacing addresses can interrupt active connections.

### 🔐 Do you need a fixed outbound IP?

If an upstream server uses an IP allowlist, a known NAT external IP can be useful. Automatic allocation may allocate more than one IP as capacity needs change. For a controlled address, consider reserving a static external IP at the intended network tier and configuring NAT to use it. Follow the current Cloud NAT documentation for the required allocation mode and verify the final IP allocation after configuration.

## 🚀 Step 4 — Connect Cloud Run to the VPC

For an existing Cloud Run service:

```bash
gcloud run services update "$SERVICE" \
  --region="$REGION" \
  --network="$NETWORK" \
  --subnet="$SUBNET" \
  --vpc-egress=all-traffic
```

The important setting is:

- `--network` and `--subnet`: select the VPC path.
- `--vpc-egress=all-traffic`: routes public internet egress through the VPC so the configured NAT path can apply.

With `private-ranges-only`, ordinary public internet destinations generally do not use this VPC egress path.

If you deploy a new revision with `gcloud run deploy`, add the same network, subnet, and egress flags to your normal command. Keep your existing image, environment variables, ingress policy, authentication, and scaling settings unless you intend to change them.

## 🧪 Step 5 — Verify the outbound IP

1. Deploy the new Cloud Run revision and wait for it to become ready.
2. Make an outbound request **from the application running on Cloud Run** to a trusted IP-echo endpoint, or temporarily add a protected diagnostic endpoint.
3. Compare the observed source IP with the IP address(es) allocated to Cloud NAT.
4. If your upstream server has an allowlist, add the correct NAT address(es) there.

Inspect NAT allocation again:

```bash
gcloud compute routers nats describe "$NAT" \
  --router="$ROUTER" \
  --region="$REGION"

gcloud compute routers get-nat-ip-info "$ROUTER" \
  --region="$REGION"
```

**Do not expect the `run.app` URL to resolve to the NAT IP.** Cloud NAT is used for outbound source traffic, not as the inbound address of your Cloud Run service.

## 💸 Cost optimization checklist

- [ ] **Cloud Run:** Use minimum instances of zero if cold starts are acceptable; size CPU and memory based on measurements.
- [ ] **Scaling:** Set sensible concurrency and maximum instances; too-low limits may cause 429 responses, while high limits do not guarantee capacity.
- [ ] **Cloud NAT:** Include gateway usage, NAT data processing, and external IP charges in your estimate.
- [ ] **Network transfer:** Standard Tier can still incur internet data transfer charges. It is not free bandwidth.
- [ ] **Reduce data volume:** Cache repeat requests, avoid redundant downloads, and compress where appropriate.
- [ ] **Scope NAT carefully:** Cover only the subnet ranges that require it, when appropriate.
- [ ] **Compare tiers:** Benchmark cost, latency, throughput, and reliability for your region and client locations.
- [ ] **Billing alerts:** Review Cloud Run, Cloud NAT, external IP, and network egress line items separately.

For a low-traffic service, the fixed or hourly NAT costs may outweigh any network-tier savings. Calculate the total cost using current regional prices instead of assuming this architecture is always cheaper.

## 🧰 Troubleshooting

<details>
<summary><strong>❌ Outbound requests fail</strong></summary>

Check that the Cloud Run revision uses the intended VPC and subnet, NAT covers that subnet, routes and egress firewall rules allow the destination, DNS resolves, NAT ports are available, and the upstream firewall permits the connection.

</details>

<details>
<summary><strong>🌍 The observed public IP is not the NAT IP</strong></summary>

Confirm `--vpc-egress=all-traffic`, the selected network/subnet, the NAT subnet coverage, and the active Cloud Run revision. Make the IP check from inside the running service, not from your laptop.

</details>

<details>
<summary><strong>🔌 Connections drop after changing NAT</strong></summary>

Replacing NAT IPs or changing allocation settings can interrupt existing sessions. Plan a maintenance window, verify the new allocation, and test client reconnect behavior.

</details>

<details>
<summary><strong>🐢 Standard Tier is slower for your traffic</strong></summary>

Benchmark real requests from your target client locations. Compare latency, throughput, and reliability with Premium Tier before deciding whether the cost trade-off is worthwhile.

</details>

<details>
<summary><strong>💳 The bill is higher than expected</strong></summary>

Check Cloud Run compute, Cloud NAT gateway and data processing, external IP addresses, and network data transfer separately in Cloud Billing. Set budgets and alerts; a budget alert notifies you but does not automatically cap spending.

</details>

## 🔗 Official documentation

| Topic | Google Cloud guide |
|---|---|
| 🚀 Direct VPC egress | [Configure Direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc) |
| 🧭 Networking | [Cloud Run networking best practices](https://cloud.google.com/run/docs/configuring/networking-best-practices) |
| 🌐 NAT concepts | [Cloud NAT overview](https://cloud.google.com/nat/docs/overview) |
| ⚙️ NAT setup | [Set up and manage Public NAT](https://cloud.google.com/nat/docs/set-up-manage-network-address-translation) |
| 💸 Network pricing | [VPC network pricing](https://cloud.google.com/vpc/network-pricing) |
| 💸 Cloud Run pricing | [Cloud Run pricing](https://cloud.google.com/run/pricing) |

---

<p align="center">
  <strong>☁️ Configure carefully · Verify egress · Monitor your bill</strong><br/>
  <sub>Documentation for learning and planning. Review current Google Cloud documentation and prices before changing production networking.</sub>
</p>


## 🖥️ Cloud Run proxy service and browser information page

This repository can run an Xray **VLESS over WebSocket (WS)** inbound behind a small Go HTTP gateway. The gateway lets ordinary browser requests display a friendly information page while WebSocket upgrade requests are forwarded to Xray.

### Request flow

```text
Browser opens /
      |
      v
Go gateway serves the service information page

VLESS client connects to configured WebSocket path
      |
      v
Go gateway forwards the WebSocket request to Xray
      |
      v
Xray validates the VLESS UUID and handles proxy traffic
```

The browser page and the VLESS connection are separate functions. A successful browser page load only shows that the HTTP endpoint responded; it does not prove that a VLESS client can connect or that outbound internet access is working.

### Browser page and UUID verification

The gateway supports a browser form that checks the submitted UUID on the server before returning the information page. Keep these points in mind:

- The UUID is a credential. Do not publish a live UUID in README files, screenshots, public issue reports, or client import links.
- Configure the production UUID through Cloud Run environment configuration or Secret Manager rather than relying on a sample/default value in source code.
- Use HTTPS when entering credentials. Do not enter a UUID into an untrusted page.
- The current simple verification form is not a full identity system. If the information page is sensitive, add rate limiting and short-lived authenticated sessions before exposing it publicly.
- Browser UUID verification does **not** authenticate a VLESS connection by itself; Xray validates the UUID used by the VLESS client separately.

### VLESS + WebSocket + TLS client settings

For a Cloud Run HTTPS endpoint, the typical client values are:

| Field | Value |
|---|---|
| Protocol | VLESS |
| Server / address | The hostname of the actual Cloud Run URL or configured custom domain |
| Port | `443` |
| Transport | WebSocket (`ws`) |
| TLS / security | TLS |
| SNI | The hostname used by the client |
| WebSocket Host header | Usually the same hostname |
| WebSocket path | Must exactly match `WS_PATH` and Xray's `wsSettings.path` |
| UUID | The value configured for `VLESS_UUID` |

**Do not copy a sample UUID from this documentation into production.** The actual UUID must match the value configured in Cloud Run and Xray. If a UUID was ever committed publicly, rotate it and update authorized clients.

Cloud Run's `run.app` URL provides HTTPS/TLS at the platform edge. Do not assume that a different hostname, custom domain, or path works until you test it with the deployed revision. Keep the WebSocket path identical on both the client and Xray.

### Environment variables

| Variable | Purpose |
|---|---|
| `PORT` | HTTP port that Cloud Run routes requests to; normally `8080` |
| `XRAY_PORT` | Internal Xray listener port; the gateway and Xray must agree |
| `VLESS_UUID` | VLESS client credential configured in Xray |
| `WS_PATH` | WebSocket path; must match the client configuration |

Set or update a service variable with Cloud Run, for example:

```bash
gcloud run services update YOUR_SERVICE \\
  --region=YOUR_REGION \\
  --update-env-vars=WS_PATH=/YOUR_WS_PATH
```

For a real UUID, prefer Secret Manager or another controlled secret-management method. Avoid putting secrets in shell history, source control, logs, or command examples shared with others.

### Deploying source changes

If your repository is connected to Cloud Build or another CI/CD pipeline, pushing to the configured branch may trigger a new image build and deployment. Check the build result and the active Cloud Run revision before testing. If no automatic trigger is configured, build and deploy using your existing pipeline; do not replace a working service URL or alter network settings unless needed.

After deployment, test both paths:

1. Open the service root URL in a browser and confirm the information page responds.
2. Connect using an authorized VLESS client with the correct hostname, port, UUID, TLS, and WebSocket path.
3. Check Cloud Run logs for startup errors, HTTP errors, and failed proxy requests.

### 💸 Cost notes for the proxy and information page

The HTML information page and a UUID comparison use very little compute during occasional visits. They should not materially change the bill on their own. The larger cost factors can be:

- Cloud Run CPU and memory while requests are active, including long-lived WebSocket requests.
- Repeated client reconnects, including a VPN app reconnecting in the background.
- Outbound internet data transfer and destination-dependent transfer pricing.
- Cloud NAT gateway usage, NAT data processing, and external IP charges when traffic uses the VPC/NAT path.

Cloud Run's minimum instance setting of zero does not terminate an active request. WebSocket connections are subject to the configured request timeout; reconnecting clients can create new requests repeatedly. If you do not need the proxy overnight, disconnect clients or disable automatic reconnection rather than increasing the timeout solely to reduce cost.

To investigate a bill, compare Cloud Run compute, Cloud NAT, and network data-transfer line items for the same time range. A count of HTTP `101` responses is a count of WebSocket upgrades, not a count of unique users, total connection duration, or an exact cost calculation.

