# ce-capstone — production-ready cloud platform

A multi-tier e-commerce storefront on AWS, built entirely with Terraform,
deployed through GitOps, and designed around one unusual constraint: **it is
destroyed every time I stop working on it.**

That constraint drove more of the architecture than anything else, and it is
the thread running through the decisions below.

> **Ironhack Cloud Engineering Bootcamp — Week 9 Capstone**
> Dennis Beitel · [github.com/Draian123](https://github.com/Draian123)

---

## What it is

```
Internet → ALB (public subnets, 2 AZs)
             → Auto Scaling Group: 3 × t4g.micro (private subnets, 2 AZs)
                 → DynamoDB catalog (VPC gateway endpoint, never via NAT)
```

The application is deliberately trivial — it shows which instance and
availability zone served your request, and lists six products read from
DynamoDB. Reload the page and the instance changes. That is the whole feature
set, because the point of this project is the infrastructure underneath it.

![Architecture overview](docs/architecture/architecture-overview.png)

**77 resources** in the dev environment, **24** in the shared bootstrap layer,
across four reusable Terraform modules.

---

## Quick start

You need Terraform ≥ 1.10, the AWS CLI with credentials, and Bash. On Windows,
the Git Bash that ships with Git for Windows works; PowerShell wrappers are
provided for each script.

```bash
git clone https://github.com/Draian123/CapstoneProject.git
cd CapstoneProject

scripts/bootstrap.sh        # once per AWS account
scripts/up.sh dev           # ~6 minutes, then prints the storefront URL
scripts/status.sh           # what is running, and what it has cost so far
scripts/down.sh dev         # stops all billing
```

`bootstrap.sh` creates the remote state bucket, the GitHub Actions OIDC roles,
and the shared alert channel. It asks once for an email address for alarm
notifications and stores it in a gitignored file.

**Confirm the SNS subscription email it triggers.** Alarms deliver nothing
until that link is clicked. It is a one-time step — see
[why](#why-the-alert-channel-lives-outside-the-environment) below.

`up.sh` does not return until the load balancer reports healthy targets and
`/health` answers over the public URL, because "apply completed" and "the site
works" are not the same event.

---

## The constraint, and what it changed

A NAT Gateway costs about USD 32/month whether or not anything uses it. Running
this platform around the clock is roughly **USD 71/month**; running it only
while actively working, with teardown in between, is about **USD 13/month**.
For a personally-funded bootcamp project that is the difference between an
environment that is comfortable to run and one that is not.

So the platform is ephemeral by default. Three consequences shaped the design:

**The layers are split by lifetime, not by service.** `terraform/bootstrap/`
holds what must survive teardown — remote state, CI roles, the alert topic, the
budget. `terraform/environments/<env>/` holds everything that bills. `down.sh`
destroys the second and never touches the first.

**CI will not resurrect a torn-down environment.** A merge to `main` applies
changes to a *running* environment; if the environment is down, the apply
workflow skips with an explanation rather than silently starting the meter.
Creating from nothing requires an explicit manual dispatch. Otherwise ordinary
GitOps would quietly undo the cost control.

**Drift detection treats "empty" as normal.** An environment holding no
resources is this platform's resting state, not a finding, so the nightly drift
job checks for that first. Without it, it would file a false issue every
morning.

### Why the alert channel lives outside the environment

An SNS email subscription only delivers after a confirmation click. If the
topic were created per environment, every bring-up would produce a fresh
unconfirmed subscription and another confirmation email — and an alert channel
that has to be re-armed on every deploy is one that eventually gets ignored.

The budget is in the bootstrap layer for a sharper reason: the moment a cost
alert matters most is right after a teardown that did not fully succeed, and a
budget destroyed alongside the environment cannot warn about what the destroy
missed.

---

## Repository layout

```
terraform/
  bootstrap/          state bucket · OIDC roles · alert topic · budget
  modules/
    networking/       VPC, subnets, NAT, security groups, flow logs, VPC endpoint
    data/             DynamoDB catalog, PITR, AWS Backup
    compute/          ALB, target group, launch template, ASG, scaling policy
    monitoring/       4 alarms, CloudWatch dashboard
  environments/
    dev/              the environment that is actually deployed
    prod/             same modules, production posture — see the tfvars diff
  policy/             OPA/Rego policies + 26 unit tests

app/                  the storefront: one file, zero npm dependencies
scripts/              bootstrap · up · down · status · demo-failover
tests/terratest/      Go infrastructure tests
monitoring/           dashboard source, alert docs, Logs Insights queries
docs/                 diagrams, ADRs, incident reports
.github/workflows/    plan · apply · tests · drift detection
```

## Documentation

| | |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Components, traffic flow, HA strategy, and the trade-offs behind each choice |
| [SECURITY.md](SECURITY.md) | Controls, IAM model, scanner findings, and the risks knowingly accepted |
| [RUNBOOK.md](RUNBOOK.md) | Deploy, operate, troubleshoot, recover |
| [COSTS.md](COSTS.md) | Line-by-line breakdown and the optimisations applied |
| [RETROSPECTIVE.md](RETROSPECTIVE.md) | What worked, what did not, what I would change |
| [docs/decisions/](docs/decisions/) | ADRs — including why a single NAT Gateway and why not RDS |
| [docs/incident-reports/](docs/incident-reports/) | The 502 window found by fault injection, and its fix |

---

## How it is verified

Nothing below is a claim about what the code should do; each was run.

| Gate | Result |
|---|---|
| OPA policy unit tests | 26/26 |
| OPA policy gate against the real plan | 0 violations |
| checkov | 235 passed, 0 failed, 33 suppressed with inline justification |
| tflint | clean across all 7 Terraform directories |
| Application tests | 11/11, with no metadata service and no DynamoDB reachable |
| Terratest | compiles and vets on every PR; builds real infrastructure on demand |

### Fault injection

`scripts/demo-failover.sh` terminates an application instance outright and
probes the storefront once per second throughout.

This is how the most interesting bug in the project was found. The Auto Scaling
group replaced the instance exactly as designed — but the load balancer kept
routing to the dead target until its own health checks noticed, and 6 requests
returned 502 in the meantime. Tuning the health check to the ALB minimum cut
that to **2 failed requests**, and recovery from 171s to **99s**.

Two is not zero and cannot be: a load balancer cannot route away from a target
before it knows the target is gone. So this platform can honestly claim
zero-downtime *deployment* — connection draining covers that — but not
zero-downtime *instance failure*. The full write-up is in
[docs/incident-reports/](docs/incident-reports/2026-08-31-failover-502-window.md).

---

## Security posture in one paragraph

No SSH. No key pair, no port 22, no bastion — operator access is SSM Session
Manager, which is audited in CloudTrail. No AWS access keys anywhere: GitHub
Actions federates through OIDC, and instances use an instance profile. IMDSv2 is
required, which closes the SSRF-to-credential-theft path. The application
instances have no public IP and sit in private subnets; the only thing reachable
from the internet is the load balancer. The instance role grants five read-only
DynamoDB actions on exactly one table ARN.

The largest known gap is that there is no HTTPS, because that needs a domain
this project does not own. It is documented rather than hidden — see
[SECURITY.md](SECURITY.md).

## Cost in one paragraph

About **USD 0.096/hour** while running: a NAT Gateway (USD 0.045), an ALB
(USD 0.023), three t4g.micro instances (USD 0.025) and their volumes. Continuous
operation would be roughly USD 71/month; as actually used, about USD 13. Six
optimisations are applied and measured in [COSTS.md](COSTS.md), the largest
being the teardown workflow itself (−82%) and a shared NAT Gateway (−USD 33).
Built the obvious way, the same architecture would be USD 127/month. Every
resource carries five cost allocation tags, enforced by a policy that fails the
build if any are missing.

---

## Contact

Dennis Beitel — [github.com/Draian123](https://github.com/Draian123)
Built for the Ironhack Cloud Engineering Bootcamp, Week 9, August 2026.
