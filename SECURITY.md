# Security

The controls implemented, the reasoning behind them, and — in the same detail —
the risks knowingly accepted.

The second half matters as much as the first. A security document that lists
only what was done is a marketing document. Every scanner finding in this
repository is either fixed or has a written reason, and those reasons are in
[Accepted risks](#accepted-risks) rather than buried in a suppression file.

---

## Summary

| | |
|---|---|
| Long-lived AWS credentials | **None.** OIDC federation for CI, instance profile for EC2 |
| Inbound SSH | **None.** No port 22 rule, no key pair, no bastion |
| Public IPs on application instances | **None.** Private subnets only, verified by test |
| IMDS | v2 required, hop limit 1 |
| Encryption at rest | EBS, S3 and DynamoDB all encrypted |
| checkov | 235 passed · 0 failed · 33 suppressed with inline justification |
| Custom policy gate | 26 rules, enforced on every plan, blocking |
| Largest known gap | No HTTPS — no domain, therefore no certificate |

---

## Identity and access

### There are no access keys

This is the control the rest depends on, because a leaked key is how most cloud
incidents actually begin.

**GitHub Actions** federates through an OIDC identity provider. A workflow
exchanges a short-lived, GitHub-signed JWT for temporary AWS credentials. There
is nothing in the repository's secrets to steal, and nothing to rotate.

Two roles, with trust policies doing the separation:

| Role | Trusted subject | Permissions |
|---|---|---|
| `ce-capstone-gha-plan` | `:pull_request` and `:ref:refs/heads/main` | `ReadOnlyAccess` + state bucket |
| `ce-capstone-gha-apply` | `:ref:refs/heads/main` **only** | Scoped deploy policy + state bucket |

A pull request — including one opened from a fork — cannot mint a token whose
subject claim is `refs/heads/main`, so it cannot assume the apply role no matter
what a malicious workflow edit tries. The privilege boundary is enforced by STS,
not by workflow logic that an attacker could also edit.

**EC2 instances** use an instance profile. The AWS CLI picks up short-lived
credentials from the metadata service; there are no credentials on disk and none
in the application code.

The policy gate enforces this rather than trusting it: `aws_iam_access_key` and
`aws_iam_user` are both hard denies. A pull request that adds either fails.

### The deploy role is not an administrator

`ce-capstone-gha-deploy` is scoped three ways.

**By service** — only the services this platform uses.

**By region** — every regional action carries a
`aws:RequestedRegion = us-east-1` condition. This is the meaningful boundary on
the action-broad statements: Terraform must create resources that do not exist
yet, so resource-level ARNs are impossible for creates, but a compromised
pipeline still cannot spin resources up in another region. That is the usual
crypto-mining blast radius, and it is closed.

**By name** — IAM is the dangerous surface, so role, policy and instance-profile
actions are restricted to ARNs matching `ce-capstone-*`. CI cannot touch any
other identity in the account, and cannot escalate by attaching
`AdministratorAccess` to a role of its own making.

Two explicit `Deny` statements hold even if the allows are later widened by
mistake, since an explicit deny cannot be overridden:

- All IAM user and access key management.
- All S3 outside the Terraform state bucket.

### The instance role grants five actions

```
dynamodb:GetItem, BatchGetItem, Query, Scan, DescribeTable
  on  arn:aws:dynamodb:us-east-1:<account>:table/ce-capstone-dev-products
```

Read-only, because the storefront never writes. One table ARN, not a wildcard.
Plus two AWS-managed policies: `CloudWatchAgentServerPolicy` for telemetry, and
`AmazonSSMManagedInstanceCore`, which is what makes it possible to have no SSH
ingress rule and no bastion host at all.

---

## Network security

Covered in detail in [ARCHITECTURE.md](ARCHITECTURE.md#security-groups-are-chained-not-flat).
The security-relevant points:

**Security groups are chained, and reference each other rather than CIDRs.** The
application accepts traffic from the load balancer's security group — not from a
range that something else could occupy. The load balancer's *egress* is
restricted to the application tier, so a compromised load balancer cannot reach
anything else in the VPC.

**Application instances have no public IP and no route from the internet.** The
Terratest suite asserts this against AWS rather than against the Terraform
source, so a future change that quietly attaches a public IP fails a test.

**The default security group is stripped of all rules.** Nothing is placed in
it, but AWS creates it permissive by default and something attached to it by
accident would inherit allow-all between members.

**VPC flow logs** record accepted and rejected connections to CloudWatch, with
short retention as a deliberate cost choice.

**No SSH.** No key pair exists, no port 22 rule exists, and there is no bastion.
Operator access is SSM Session Manager, which needs no inbound port and logs
every session to CloudTrail. This removes an entire class of exposure — leaked
private keys, a bastion to patch, brute-force attempts in the logs.

---

## Data protection

**In transit:** HTTP from the internet to the load balancer — see
[Accepted risks](#no-https). ALB-to-target traffic is HTTP inside private
subnets, reachable only from the ALB security group. All AWS API traffic is
TLS, and the state bucket policy explicitly denies any request where
`aws:SecureTransport` is false.

**At rest:** EBS root volumes encrypted; the state bucket uses SSE-S3 with
bucket keys, versioning and a full public access block; DynamoDB is encrypted
with an AWS-owned key.

**Instance metadata:** IMDSv2 is required (`http_tokens = "required"`) with a
hop limit of 1. This closes the server-side request forgery path that turns an
application bug into stolen instance-role credentials — historically one of the
most damaging cloud vulnerability classes. Both settings are enforced by the
policy gate, so a change that weakens either fails the build.

**Secrets:** there are none to manage. No database password (IAM-authenticated
DynamoDB), no API keys, no credentials in user-data.

The one piece of personal data — the alert email — is never committed. It is
supplied at apply time through `TF_VAR_alert_email` and stored in a gitignored
file, because this repository is public.

---

## Policy as code

`terraform/policy/` holds six Rego policy files enforced by OPA against
`terraform show -json` output on every plan, in both the pull request and the
apply workflow. A violation fails the build.

Evaluating the **plan** rather than the HCL source is the point. The plan has
variables resolved, modules expanded and provider `default_tags` merged in — so
a policy cannot be defeated by moving a value into a variable.

| Policy | Enforces |
|---|---|
| `tagging.rego` | Five cost allocation tags on every cost-bearing resource, non-empty |
| `network.rego` | No administrative port open to the internet; only 80/443 public; no public IPs; ALB drops invalid headers |
| `data_protection.rego` | EBS/S3 encryption; all four S3 public-access controls; DynamoDB PITR; IMDSv2 and hop limit; log retention set |
| `iam.rego` | No `AdministratorAccess`/`PowerUserAccess`/`IAMFullAccess` attachments; no `Action:* on Resource:*`; no IAM users or access keys |
| `availability.rego` | Minimum 3 instances across ≥2 AZs; ELB health checks; health checks enabled |

`availability.rego` is the interesting one: it makes the project's own
high-availability requirement a build failure rather than a sentence in a README
that nothing enforces. Lowering `min_size` to 1 does not quietly work.

**26 unit tests** assert each rule both fires on bad input and stays quiet on
good input. A policy that has silently stopped matching is indistinguishable
from one that passes, which is how policy suites rot into decoration. One test
specifically asserts that *destroying* a non-compliant resource is allowed —
otherwise the gate would block cleanup of the very thing it objects to.

---

## Scanner results

checkov runs on every pull request over all Terraform: **235 passed, 0 failed,
33 suppressed.**

Every suppression is inline, next to the resource, with its reason on the same
line. None are in a blanket config file, because a suppression list read far
from the code it affects is a suppression list nobody re-examines.

---

## Accepted risks

### No HTTPS

**Risk:** traffic between users and the load balancer is unencrypted, and is
open to interception and modification on the path.

**Why:** an ACM certificate requires a domain, and this project owns none. This
is the single largest gap in the posture and the root cause of five separate
scanner findings (`CKV_AWS_2`, `CKV_AWS_103`, `CKV_AWS_378`, `CKV2_AWS_20`,
`CKV_AWS_260`).

**Mitigation:** no credentials, session tokens or personal data cross this
connection — the storefront is a read-only public catalog with no authentication
and no user input.

**To close it:** register a domain, request an ACM certificate, add a 443
listener with a modern TLS policy, and redirect 80 → 443. Roughly USD 12/year
and about twenty lines of Terraform. The `alb_zone_id` output already exists for
the Route 53 alias record.

### No customer-managed KMS keys

**Risk:** CloudWatch log groups, DynamoDB and the backup vault use AWS-managed
or AWS-owned keys rather than customer-managed ones, so key rotation and access
are not independently controlled.

**Why:** a CMK is ~USD 1/month plus per-request charges, per key. The data is a
public product catalog and application logs containing instance IDs and request
paths. Everything is still encrypted at rest.

### The SNS topic is not encrypted

This one is worth reading twice, because the obvious fix is worse than the
problem.

**Risk:** alarm notifications are stored unencrypted.

**Why:** enabling SSE with the AWS-managed key (`alias/aws/sns`) would
**silently break alarm delivery.** The CloudWatch service principal cannot use
an AWS-managed key, so every notification would fail to publish while the
scanner reported green. Doing it correctly requires a customer-managed key with
a key policy granting `cloudwatch.amazonaws.com` and `budgets.amazonaws.com`
`kms:GenerateDataKey`.

The topic carries alarm state transitions — "CPU is high" — not sensitive data.
A silent outage in the alerting path is a strictly worse outcome than
unencrypted alarm text, and a control that breaks the thing it protects is not a
control.

### No WAF

**Risk:** no managed protection against the OWASP Top 10 or volumetric attacks.

**Why:** AWS WAF is ~USD 5/month per web ACL plus per-rule and per-request
charges, against a storefront serving six read-only catalog rows with no
authentication, no user input, and no write path. The application accepts no
input beyond a single clamped integer query parameter.

**Mitigation:** the ALB drops invalid header fields, closing request-smuggling
and header-injection vectors. Output is HTML-escaped and a restrictive
Content-Security-Policy is sent. AWS Shield Standard provides L3/L4 DDoS
protection at no cost.

### No ALB access logs

**Risk:** no request-level forensic record at the load balancer.

**Why:** it would require a second S3 bucket and its policy. Request telemetry
is already covered from three directions: ALB CloudWatch metrics, structured
per-request application logs in CloudWatch Logs, and VPC flow logs.

### Deletion protection is off in dev

**Risk:** the load balancer and catalog table can be destroyed without
confirmation.

**Why:** that is the entire point of `scripts/down.sh`. Deletion protection in
dev would defeat the cost control that makes this project affordable to run.
**prod sets `enable_deletion_protection = true`**, and `down.sh` warns that a
prod destroy will fail until it is deliberately turned off — which is the
correct amount of friction.

### The deploy role has action-broad statements

**Risk:** `ec2:*`, `elasticloadbalancing:*` and similar are not resource-scoped.

**Why:** Terraform creates resources that do not exist yet, so create actions
cannot carry resource ARNs. This is inherent to infrastructure-as-code
pipelines, not a shortcut.

**Mitigation:** the region condition, the name-scoping on all IAM actions, and
the two explicit `Deny` statements. In practice a compromised pipeline can
create and destroy this platform's own resource types in one region, and can
neither create identities nor reach any other S3 bucket.

---

## Verification

| Control | How it is proven |
|---|---|
| No public IPs on instances | Terratest asserts against the AWS API, not the source |
| IMDSv2 required | Policy gate; a change fails the build |
| No IAM users or access keys | Policy gate; hard deny |
| ≥3 instances across ≥2 AZs | Policy gate, plus Terratest sampling real requests until both AZs answer |
| Security group chaining | Terratest asserts the groups are distinct; checkov checks the rules |
| No secrets in the repository | `.gitignore` covers `*.auto.tfvars` and `.alert-email`; checkov scans for hardcoded secrets |
| Encryption at rest | checkov + policy gate |
| Self-healing under failure | `scripts/demo-failover.sh`, measured three times |

## Compliance mapping

Not a certification claim — a map of which controls would be evidence for which
common framework requirements.

| Control | CIS AWS Foundations | AWS Well-Architected (SEC) |
|---|---|---|
| No IAM users; federated CI access | 1.x | SEC02 |
| Least-privilege scoped roles | 1.16 | SEC03 |
| No unrestricted administrative ports | 5.2 | SEC05 |
| Default security group has no rules | 5.3 | SEC05 |
| VPC flow logs enabled | 3.x | SEC04 |
| Encryption at rest | 2.x | SEC08 |
| S3 public access blocked, TLS enforced | 2.1.x | SEC08 |
| CloudTrail (account-level, pre-existing) | 3.1 | SEC04 |
| IMDSv2 enforced | — | SEC06 |
| Automated policy enforcement in CI | — | SEC01 |

**Not covered:** no AWS Config rules, no GuardDuty, no Security Hub. All three
carry per-account monthly costs that were out of scope for a personally-funded
project, and all three would be the first additions in a real account.
