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
