# Self GCP Run — Cloud Run with lower-cost network egress

This guide explains one way to route outbound traffic from Google Cloud Run through a VPC and Public Cloud NAT configured to use **Standard Network Service Tier** for its external IP addresses.

The goal is to understand the network path, control egress costs, and optionally provide a predictable outbound source IP for upstream services that use IP allowlists.

> **Important:** Standard Tier is not free bandwidth. Cloud Run compute, Cloud NAT, NAT data processing, external IP addresses, and internet data transfer may all incur charges. Compare current regional prices before adopting this architecture.

## Architecture

```text
Client
  |
  v
Cloud Run HTTPS URL (inbound traffic)
  |
  | outbound requests — Direct VPC egress: all-traffic
  v
VPC subnet
  |
  v
Cloud Router + Public Cloud NAT
(Standard Tier external IP)
  |
  v
Internet / upstream server
```

Cloud NAT provides outbound connectivity and handles return traffic for connections initiated from the VPC. It does **not** change the inbound Cloud Run URL or give the Cloud Run service a public inbound IP address.

## Prerequisites

- A Google Cloud project with billing enabled.
- The Google Cloud CLI (`gcloud`) authenticated and configured.
- Permission to configure Cloud Run, VPC networking, Cloud Router, and Cloud NAT.
- A VPC network and subnet in the same region as the Cloud Run service.
- The Compute Engine and Cloud Run APIs enabled.

Set your values first:

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

Replace all placeholders. Check for existing resources before creating anything; do not create duplicate networks, subnets, routers, or NAT gateways.

## 1. Inspect existing resources

```bash
gcloud run services describe "$SERVICE" --region="$REGION"
gcloud compute networks list
gcloud compute networks subnets list --regions="$REGION"
gcloud compute routers list --regions="$REGION"
```

Direct VPC egress requires a suitable subnet with enough free IP addresses for Cloud Run instances and deployment overlap. Choose a subnet range that does not overlap with your other networks.

## 2. Create a Cloud Router and Public Cloud NAT

If you do not already have a VPC and subnet, create them according to your network plan first. The following commands show an example of creating a router and NAT for an **existing** network and subnet:

```bash
gcloud compute routers create "$ROUTER" \
  --network="$NETWORK" \
  --region="$REGION"

gcloud compute routers nats create "$NAT" \
  --router="$ROUTER" \
  --region="$REGION" \
  --nat-custom-subnet-ip-ranges="$SUBNET" \
  --endpoint-types=ENDPOINT_TYPE_VM \
  --auto-allocate-nat-external-ips \
  --auto-network-tier=STANDARD
```

This example requests automatically allocated NAT external IP addresses using Standard Tier. If the router or NAT already exists, inspect its configuration instead of running the create command again:

```bash
gcloud compute routers nats describe "$NAT" \
  --router="$ROUTER" \
  --region="$REGION"
```

If you require a stable outbound IP for an upstream allowlist, consider a reserved external IP and configure NAT to use that address with the appropriate network tier. Confirm the NAT allocation mode and review the current Google Cloud documentation before changing an existing gateway. Changing NAT IPs or allocation settings can interrupt active connections.

## 3. Route Cloud Run outbound traffic through the VPC

For an existing Cloud Run service:

```bash
gcloud run services update "$SERVICE" \
  --region="$REGION" \
  --network="$NETWORK" \
  --subnet="$SUBNET" \
  --vpc-egress=all-traffic
```

The key option is `--vpc-egress=all-traffic`. It sends public internet egress through the VPC, where the Cloud NAT configuration can apply. With `private-ranges-only`, ordinary public destinations generally do not use this NAT path.

When deploying a new revision, include the same network, subnet, and egress flags in your normal deployment command. Preserve the existing image, environment variables, ingress policy, authentication, and scaling settings unless you intentionally want to change them.

## 4. Verify the outbound public IP

Make an outbound request from the application to a trusted IP-echo service, or use a temporary diagnostic endpoint within the same Cloud Run service to report the observed source IP. Compare that result with the external IP address allocated to Cloud NAT.

Inspect NAT IP allocation:

```bash
gcloud compute routers nats describe "$NAT" \
  --router="$ROUTER" \
  --region="$REGION"

gcloud compute routers get-nat-ip-info "$ROUTER" \
  --region="$REGION"
```

Do not expect the Cloud Run `run.app` URL to resolve to the NAT IP. The NAT IP is used for **outbound** source traffic. If the upstream server uses an IP allowlist, allow the correct NAT IP address or addresses.

## 5. Keep costs low

- **Cloud Run:** Use minimum instances of zero if cold starts are acceptable. Set CPU, memory, concurrency, timeout, and maximum instances according to measured workload needs.
- **Cloud NAT:** Include gateway usage, data processing, and external IP address charges in your estimate.
- **Network transfer:** Standard Tier traffic can still incur data transfer charges. It does not mean free or unlimited bandwidth.
- **Reduce traffic volume:** Cache repeat responses, avoid unnecessary downloads, and compress data when appropriate.
- **Limit NAT scope:** Configure NAT for only the subnet ranges that need it, where appropriate.
- **Measure before committing:** Compare Standard Tier and Premium Tier costs, latency, throughput, and reliability for your region and client locations.
- **Set billing alerts:** Review Cloud Run, Cloud NAT, external IP, and network egress line items separately in Cloud Billing.

For a low-traffic service, fixed or hourly NAT charges may outweigh the potential savings. Calculate the full cost using current regional prices rather than assuming this setup is always cheaper.

## Troubleshooting

### Outbound connection fails

Check the Cloud Run revision's VPC settings, NAT subnet coverage, routes, egress firewall rules, DNS, NAT port allocation, and the upstream server's firewall.

### The observed source IP is not the NAT IP

Verify that the deployed revision uses the intended VPC and subnet with `--vpc-egress=all-traffic`, and that the Public NAT gateway covers that subnet. Confirm that the IP check is made from inside the Cloud Run service.

### Connections drop after NAT changes

Changing NAT IPs or allocation settings can interrupt active connections. Plan a maintenance window and verify the resulting IP allocation and client reconnection behavior.

### Standard Tier is slower or less reliable for your users

Benchmark real traffic. Standard and Premium tiers have different network characteristics; cost savings should be weighed against latency, throughput, and reliability.

## Official documentation

- [Cloud Run Direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc)
- [Cloud Run networking best practices](https://cloud.google.com/run/docs/configuring/networking-best-practices)
- [Cloud NAT overview](https://cloud.google.com/nat/docs/overview)
- [Set up and manage Public NAT](https://cloud.google.com/nat/docs/set-up-manage-network-address-translation)
- [Google Cloud network pricing](https://cloud.google.com/vpc/network-pricing)
- [Cloud Run pricing](https://cloud.google.com/run/pricing)
