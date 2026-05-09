# URL Shortener on Amazon EKS

This repository provisions and deploys a FastAPI URL shortener on Amazon EKS using Terraform, Helm, Redis, AWS Load Balancer Controller, and the AWS EBS CSI driver.

## What This Deploys

- VPC with public and private subnets
- NAT gateways, route tables, and internet gateway
- EKS control plane and managed node group
- IAM roles for EKS, nodes, IRSA, ALB Controller, and EBS CSI
- EKS add-ons:
  - CoreDNS
  - kube-proxy
  - VPC CNI
  - AWS EBS CSI driver
- Helm releases:
  - AWS Load Balancer Controller
  - metrics-server
  - URL shortener application
- Redis StatefulSet with EBS-backed persistence
- ALB Ingress for external access

## Prerequisites

Install and configure:

- AWS CLI
- Terraform `>= 1.9.0`
- kubectl
- Helm
- Docker
- A GitHub account or container registry account for the app image
- AWS credentials with permissions to create VPC, EKS, IAM, EC2, EBS, S3, and ALB resources

Check access:

```bash
aws sts get-caller-identity
terraform version
kubectl version --client
helm version
docker version
```

## Repository Layout

```text
app/                    FastAPI URL shortener app
helm/url-shortener/     Helm chart for app + Redis + Ingress
modules/vpc/            VPC Terraform module
modules/eks/            EKS Terraform module
modules/irsa/           IAM roles/policies for service accounts
modules/addons/         EKS add-ons and platform Helm charts
bootstrap/              Optional Terraform backend bootstrap
main.tf                 Root Terraform configuration
variables.tf            Root Terraform variables
outputs.tf              Root Terraform outputs
```

## 1. Build and Push the App Image

The Helm chart expects the app image in this format:

```text
ghcr.io/<github_user>/url-shortener:<app_image_tag>
```

Build and push:

```bash
docker build -t ghcr.io/<github_user>/url-shortener:v1.0.5 .
docker push ghcr.io/<github_user>/url-shortener:v1.0.5
```

If you use GHCR, make sure you are logged in:

```bash
docker login ghcr.io
```

## 2. Configure Terraform Variables

Create a local tfvars file from the example:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
aws_region          = "eu-north-1"
project             = "url-shortener"
environment         = "dev"
vpc_cidr            = "10.2.0.0/16"
azs                 = ["eu-north-1a", "eu-north-1b"]
kubernetes_version  = "1.30"
node_instance_types = ["t3.small"]
capacity_type       = "ON_DEMAND"
node_desired_size   = 2
node_min_size       = 1
node_max_size       = 4
app_image_tag       = "v1.0.5"
github_user         = "<github_user>"
```

Notes:

- `t3.small` is used because it is Free Tier eligible in `eu-north-1` and remains x86.
- Avoid `t4g.*` unless your app image supports ARM.
- Keep `terraform.tfvars` local. It is ignored by Git.

## 3. Configure Terraform Backend

Create a local backend config:

```bash
cp backend.hcl.example backend.hcl
```

Edit `backend.hcl`:

```hcl
bucket       = "your-terraform-state-bucket"
key          = "dev/eks/terraform.tfstate"
region       = "eu-north-1"
use_lockfile = true
encrypt      = true
```

Keep `backend.hcl` local. It is ignored by Git because it contains account-specific state backend details.

### Optional: Bootstrap Backend Resources

If you do not already have an S3 state bucket, use the `bootstrap/` Terraform config:

```bash
cd bootstrap
terraform init
terraform apply
```

Capture the outputs:

```bash
terraform output
```

Then use the generated S3 bucket name in the root `backend.hcl`.

Return to the repo root:

```bash
cd ..
```

## 4. Initialize Terraform

```bash
terraform init -backend-config=backend.hcl
```

Terraform will download providers and configure the S3 backend.

## 5. Create a Plan

```bash
terraform plan -out=tfplan
```

Review the plan before applying.

## 6. Apply Infrastructure and App

```bash
terraform apply tfplan
```

Expected timing:

- VPC and IAM: a few minutes
- EKS control plane: 8 to 15 minutes
- Managed node group: 10 to 20 minutes
- Add-ons and Helm releases: several minutes

Total first deployment can take 25 to 45 minutes.

## 7. Configure kubectl

Terraform prints a `configure_kubectl` output. You can also run:

```bash
aws eks update-kubeconfig --region eu-north-1 --name url-shortener-dev
```

Verify access:

```bash
kubectl get nodes
kubectl get pods -A
```

## 8. Verify the Deployment

Check Helm releases:

```bash
helm list -A
```

Expected releases:

```text
aws-load-balancer-controller   kube-system    deployed
metrics-server                 kube-system    deployed
url-shortener                  url-shortener  deployed
```

Check app resources:

```bash
kubectl get pods,pvc,svc,ingress -n url-shortener
```

Expected:

```text
url-shortener-app-*    1/1 Running
url-shortener-redis-0  1/1 Running
Redis PVC              Bound
Ingress                has an ALB address
```

## 9. Test the App

Get the ALB DNS name:

```bash
ALB=$(kubectl get ingress url-shortener-ingress \
  -n url-shortener \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "$ALB"
```

The default Helm value uses this host:

```text
url-shortener.local
```

Because the Ingress is host-based, use the `Host` header when curling the raw ALB DNS name:

```bash
curl -H "Host: url-shortener.local" "http://$ALB/health"
curl -H "Host: url-shortener.local" "http://$ALB/ready"
```

Expected health response:

```json
{"status":"ok"}
```

Create a short URL:

```bash
curl -X POST "http://$ALB/shorten" \
  -H "Host: url-shortener.local" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com"}'
```

Example response:

```json
{"short_code":"abc123","short_url":"/r/abc123"}
```

Check stats:

```bash
curl -H "Host: url-shortener.local" "http://$ALB/stats/<short_code>"
```

Redirect:

```bash
curl -I -H "Host: url-shortener.local" "http://$ALB/r/<short_code>"
```

If you configure a real DNS record pointing to the ALB, update `helm/url-shortener/values.yaml`:

```yaml
ingress:
  host: your-domain.example.com
```

Then run:

```bash
terraform plan -out=tfplan
terraform apply tfplan
```

After DNS is configured, plain curl works:

```bash
curl http://your-domain.example.com/health
```

## Important Local Files

These files should stay local and are ignored by Git:

```text
.terraform/
*.tfstate
*.tfstate.*
tfplan
*.tfplan
terraform.tfvars
backend.hcl
```

Why:

- `.terraform/` is generated by `terraform init`.
- `*.tfstate` files can contain sensitive infrastructure data.
- `tfplan` files are temporary and environment-specific.
- `terraform.tfvars` contains real environment values.
- `backend.hcl` contains account-specific backend settings.

Commit `.terraform.lock.hcl`. It pins provider versions and checksums for reproducible Terraform runs.

## Troubleshooting

### `Invalid single-argument block definition`

Cause: Terraform variable blocks were written in mixed one-line/multi-line syntax.

Fix: use standard multi-line syntax:

```hcl
variable "name" {
  type    = string
  default = "value"
}
```

### `Requested AMI for this version 1.29 is not supported`

Cause: EKS Kubernetes `1.29` is no longer available/supported for the managed node AMI in this region.

Fix: use a currently supported version, such as:

```hcl
kubernetes_version = "1.30"
```

Check available versions:

```bash
aws eks describe-cluster-versions --region eu-north-1
```

### `The specified instance type is not eligible for Free Tier`

Cause: the node group used an instance type not allowed by the current account/region Free Tier policy.

Fix: use a Free Tier eligible x86 type:

```hcl
node_instance_types = ["t3.small"]
```

Check eligible types:

```bash
aws ec2 describe-instance-types \
  --region eu-north-1 \
  --filters Name=free-tier-eligible,Values=true \
  --query 'InstanceTypes[].InstanceType' \
  --output text
```

### AWS Load Balancer Controller CrashLoopBackOff

Check logs:

```bash
kubectl logs -n kube-system deployment/aws-load-balancer-controller --all-containers --tail=100
```

If logs mention VPC discovery:

```text
failed to introspect vpcID
specify --aws-vpc-id instead
```

Make sure the Helm release passes:

```hcl
set {
  name  = "region"
  value = var.aws_region
}

set {
  name  = "vpcId"
  value = var.vpc_id
}
```

### Ingress Error: `IngressClass "nginx" not found`

Cause: the cluster has AWS ALB IngressClass, not NGINX.

Check:

```bash
kubectl get ingressclass
```

Use:

```yaml
ingress:
  className: alb
```

### Redis Pending: `storageclass.storage.k8s.io "standard" not found`

Cause: Redis PVC requested `standard`, but EKS has `gp2`.

Fix:

```yaml
redis:
  persistence:
    storageClass: gp2
```

If a failed release left a stale unbound PVC:

```bash
kubectl delete pvc redis-data-url-shortener-redis-0 -n url-shortener
```

Only delete this PVC if it has no data you need.

### ALB Does Not Return `/health`

If this returns 404:

```bash
curl http://$ALB/health
```

Use the Ingress host header:

```bash
curl -H "Host: url-shortener.local" "http://$ALB/health"
```

The raw ALB DNS name does not match the Ingress host rule.

### ALB Controller AccessDenied

Check Ingress events:

```bash
kubectl describe ingress url-shortener-ingress -n url-shortener
```

If you see missing actions such as:

```text
ec2:GetSecurityGroupsForVpc
wafv2:GetWebACLForResource
```

Update the ALB controller IAM policy in `modules/irsa/main.tf`, then run:

```bash
terraform plan -out=tfplan
terraform apply tfplan
```

## Useful Commands

```bash
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
terraform output
```

```bash
kubectl get nodes
kubectl get pods -A
kubectl get pods,pvc,svc,ingress -n url-shortener
kubectl describe ingress url-shortener-ingress -n url-shortener
kubectl logs -n url-shortener deployment/url-shortener-app --all-containers --tail=100
```

```bash
helm list -A
helm status url-shortener -n url-shortener
helm template url-shortener helm/url-shortener --namespace url-shortener
```

## Cleanup

To destroy the main infrastructure:

```bash
terraform destroy
```

If you used `bootstrap/`, those resources have `prevent_destroy = true` because state buckets and lock tables should not be deleted accidentally.

If you intentionally want to delete backend resources, remove or adjust `prevent_destroy` in `bootstrap/main.tf`, then run the bootstrap destroy separately.

## Pushing to GitHub

Before pushing:

```bash
git status
```

Make sure these are not tracked:

```text
terraform.tfvars
backend.hcl
tfplan
.terraform/
*.tfstate
```

Files that should be committed include:

```text
README.md
.gitignore
.terraform.lock.hcl
terraform.tfvars.example
backend.hcl.example
main.tf
variables.tf
outputs.tf
modules/
helm/
app/
Dockerfile
```

