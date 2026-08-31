# Costs

What this platform costs, what it would have cost if built the obvious way, and
the six decisions that account for the difference.

All figures are `us-east-1` on-demand list prices as of August 2026, in USD.
Where a figure is measured rather than modelled, it says so.

---

## Headline

| | Monthly |
|---|---|
| Built the obvious way, running continuously | **~$127** |
| As designed, running continuously | **~$70** |
| As designed, as actually used | **~$13** |

A **90% reduction**, and roughly two thirds of it comes from a single decision:
not running the environment when nobody is using it.

---

## What it costs while running

| Component | Rate | Hourly | Monthly if 24/7 |
|---|---|---|---|
| NAT Gateway ×1 | $0.045/hr | $0.0450 | $32.85 |
| Application Load Balancer | $0.0225/hr | $0.0225 | $16.43 |
| EC2 — 3 × t4g.micro | $0.0084/hr each | $0.0252 | $18.40 |
| EBS — 3 × 10 GB gp3 | $0.08/GB-month | $0.0033 | $2.40 |
| CloudWatch alarms ×4 | $0.10/alarm-month | — | $0.40 |
| CloudWatch Logs | ~$0.50/GB ingested | — | ~$0.50 |
| DynamoDB on-demand | per request | — | ~$0.00 |
| VPC gateway endpoint | free | — | $0.00 |
| Elastic IP (attached) | free | — | $0.00 |
| S3 state bucket | ~$0.02/GB-month | — | ~$0.01 |
| SNS, Budgets | free at this volume | — | $0.00 |
| **Total** | | **~$0.096/hr** | **~$71** |

Two things stand out.

**The NAT Gateway is the single largest line item** — larger than all three
application instances combined. It is also the component doing the least: its
only job is letting instances reach the package repositories at boot and ship
telemetry.

**Compute is cheap; the plumbing is not.** NAT plus load balancer is $49/month
against $18 for the instances actually serving traffic. That inversion is the
most useful thing this exercise taught me about AWS pricing.

### Measured

Cost Explorer for August 2026, whole account (which includes unrelated services
from earlier bootcamp weeks):

| Service | MTD |
|---|---|
| EC2 — Compute | $0.89 |
| CloudWatch | $0.60 |
| EC2 — Other (EBS, EIP) | $0.37 |
| VPC (NAT Gateway) | $0.35 |
| Elastic Load Balancing | $0.14 |
| S3 | $0.002 |
| DynamoDB | $0.00006 |

Roughly **$2.35** attributable to this platform across the development sessions
that built it. The model above says $0.096/hour, which lines up with about 24
hours of cumulative uptime — and that is the point of the teardown workflow.

Cost Explorer lags about 24 hours, so today's usage is not yet reflected.

---

## Optimisations applied

### 1. One NAT Gateway instead of two — saves $32.85/month

The largest single saving, and the one with a real trade-off attached. Recorded
in full in [ADR 0002](docs/decisions/0002-single-nat-gateway.md).

Dev shares one gateway; prod uses one per AZ. What dev accepts is that losing
the gateway's availability zone costs the *other* zone its outbound
connectivity. It does not stop the platform serving requests: inbound traffic
arrives through a genuinely multi-AZ load balancer, and catalog reads go over a
gateway endpoint that never touches the NAT.

Degraded operations, not an outage — for 46% of the compute-and-network bill.

### 2. Graviton instead of x86 — saves $4.38/month

`t4g.micro` at $0.0084/hr against `t3.micro` at $0.0104/hr. Same vCPU and
memory, **19% cheaper**, and generally better performance per dollar.

The only cost is that the AMI architecture has to match, which is why
`instance_architecture` is a variable with a validation rule rather than a
hardcoded string. There is no application work: a dependency-free Node.js
service does not care what it runs on.

### 3. DynamoDB on-demand instead of RDS — saves ~$12.41/month

A `db.t4g.micro` bills about $11.68/month plus storage whether or not a single
query is served. On-demand DynamoDB costs essentially nothing while idle.

For an environment that spends most of its life torn down, this is the
difference between a data tier that is free when unused and one that is not —
and it removes the awkward choice between paying for an idle database or
destroying it and restoring data on every bring-up.
[ADR 0003](docs/decisions/0003-dynamodb-over-rds.md).

### 4. Detailed monitoring off in dev — saves $6.30/month

EC2 detailed monitoring is $2.10 per instance per month for 1-minute metric
granularity instead of 5-minute. At three instances that is $6.30.

The CloudWatch agent already reports memory and disk at 60-second intervals, and
ALB metrics — which is where the user-facing signals live — are 1-minute by
default regardless. Detailed monitoring buys finer-grained *EC2* metrics that
nothing here alarms on.

**prod turns it on**, because there the scaling decisions and alarms should work
on 1-minute data.

### 5. gp3 instead of gp2 — saves $0.60/month

$0.08/GB-month against $0.10 — **20% cheaper** — and gp3 decouples IOPS from
volume size, so a 10 GB root volume still gets 3,000 baseline IOPS where gp2
would give 30.

Cheaper and faster. There is no argument for gp2 on a new volume.

### 6. Ephemeral environments — saves ~$57/month

The largest saving of all, and the one that is a workflow rather than a
configuration value.

| Pattern | Hours/month | Cost |
|---|---|---|
| Always on | 730 | $70.08 |
| ~6h/day, 22 working days | 132 | $12.67 |

**82% saved**, because the platform simply does not exist when nobody is using
it. `scripts/up.sh` brings it back in about six minutes with the catalog
re-seeded from code.

This is only safe because it is enforced in more than one place:

- `scripts/down.sh` makes teardown a single command, so it actually happens.
- The **apply workflow refuses to resurrect a torn-down environment** — an
  ordinary merge to `main` cannot silently start the meter.
- The **budget lives in the bootstrap layer**, so it survives teardown. A budget
  destroyed with the environment could not warn about what a failed destroy left
  behind, which is exactly when the warning is needed.
- `scripts/status.sh` answers "is anything running?" in one command.

### Also applied

- **DynamoDB gateway endpoint** — free, and keeps catalog traffic off the NAT
  Gateway, avoiding $0.045/GB in data processing charges. Interface endpoints
  would cost ~$7/month each per AZ, which is why only the free gateway endpoint
  for DynamoDB is used and not endpoints for everything.
- **Log retention: 7 days dev, 30 prod.** Retention is a cost lever, not a
  compliance obligation here. Log groups are created by Terraform rather than by
  the CloudWatch agent specifically so retention is enforced — an agent-created
  group defaults to never expire, which is a slow-growing bill nobody notices.
- **S3 lifecycle on state versions.** Versioning is required for state recovery,
  but every apply keeps a copy forever; non-current versions expire after 30
  days.
- **prod is code, not a running stack.** Maintained and planned on every pull
  request so it cannot rot, applied on demand. Keeping it running would roughly
  triple total spend for a demonstration that runs on dev.

---

## What the obvious build would have cost

Same architecture, every default taken:

| | Obvious | This platform |
|---|---|---|
| NAT Gateways | 2 × $32.85 = $65.70 | 1 × $32.85 |
| Load balancer | $16.43 | $16.43 |
| Compute | 3 × t3.micro = $22.78 | 3 × t4g.micro = $18.40 |
| Storage | 30 GB gp2 = $3.00 | 30 GB gp3 = $2.40 |
| Database | db.t4g.micro = $12.41 | DynamoDB = ~$0.00 |
| Detailed monitoring | $6.30 | $0.00 |
| Alarms + logs | $0.90 | $0.90 |
| **Running continuously** | **$127.52** | **$71.08** |
| **As actually used** | — | **$12.85** |

---

## Cost allocation

Five tags on every resource, applied through the provider's `default_tags`:

| Tag | Value | Purpose |
|---|---|---|
| `Project` | `ce-capstone` | Scopes the budget and Cost Explorer filters |
| `Environment` | `dev` / `prod` | Separates environment spend |
| `Owner` | `dennis-beitel` | Who to ask |
| `CostCenter` | `ironhack-bootcamp` | Which budget it bills to |
| `ManagedBy` | `terraform` | Distinguishes IaC-managed from hand-created |

Two details make this reliable rather than aspirational.

**Provider `default_tags` do not reach ASG-launched instances or their volumes.**
That is precisely where the spend is, so the compute module passes the same tag
map explicitly through `tag_specifications` on the launch template and a
`dynamic "tag"` block on the Auto Scaling group. Without that, cost allocation
would have had a hole exactly where it mattered.

**Tagging is enforced, not encouraged.** `terraform/policy/tagging.rego` fails
the build if any cost-bearing resource is missing a required tag or has one set
to an empty string. Untagged spend is invisible spend — it cannot be filtered in
Cost Explorer and cannot be caught by a tag-scoped budget.

> The `Project` tag must be activated once in Billing → Cost allocation tags
> before it can be filtered on. It backfills within ~24 hours.

---

## Budget and alerting

One budget, `ce-capstone-monthly`, $40/month, filtered to `Project=ce-capstone`:

| Threshold | Type | Catches |
|---|---|---|
| 80% | Actual | Spend running ahead of plan |
| 100% | Forecast | A failed teardown, on day two rather than day twenty |

The forecast notification is the one that earns its keep. Actual spend crossing
80% tells you something already happened; a forecast crossing 100% tells you
something is *still happening* — which is the signature of a NAT Gateway nobody
noticed was left running.

It lives in the bootstrap layer so it survives environment teardown, for exactly
that reason.

---

## Scaling projections

If this became a real service, at 50% average CPU with target tracking:

| Load | Instances | Compute | Total/month |
|---|---|---|---|
| Baseline | 3 | $18.40 | ~$71 |
| 2× traffic | 4–5 | ~$27 | ~$80 |
| 5× traffic | 8–10 | ~$55 | ~$108 |
| Max (`max_size` 6, dev) | 6 | $36.80 | ~$89 |

Compute scales with load; the fixed $49/month of NAT plus load balancer does
not. At low traffic the platform is dominated by fixed costs — which is the
usual shape, and the reason serverless is attractive below a certain volume.

### What to do next, in order of value

1. **Compute Savings Plan.** A 1-year no-upfront plan is ~28% off on-demand
   compute. Not applicable here because the fleet does not run continuously —
   the commitment would bill during the 90% of hours the environment is torn
   down. This is a real workload optimisation that this workload correctly
   declines.
2. **Spot instances for part of the fleet.** Up to 70% off. Attractive at larger
   fleet sizes with a mixed-instances policy; rejected here because with three
   instances, one interruption is a third of capacity.
3. **A NAT instance instead of the gateway.** ~$3/month against $32.85. Rejected
   because it reintroduces a host to patch and monitor — see
   [ADR 0002](docs/decisions/0002-single-nat-gateway.md). The saving is real; it
   is bought with operational burden.
4. **`t4g.nano` instead of `t4g.micro`.** Halves compute to $9.20/month. Viable
   for this application, which idles at low double-digit MB of memory, but 512 MB
   leaves no headroom for a Node.js process under load.

---

## Honest accounting

Things that are not free and are easy to forget:

- **Cost Explorer API calls cost $0.01 each.** `scripts/status.sh` makes two per
  run. It shows in the measured data above as $0.30 for the month, which is more
  than DynamoDB, S3 and SNS combined.
- **CloudWatch was the second-largest line item** at $0.60 — four alarms at
  $0.10/month plus flow log ingestion. Flow logs are a security control worth
  paying for, but they are not free, and at higher traffic the ingestion charge
  would grow faster than anything else here.
- **Data transfer out** is $0.09/GB after the first 100 GB/month. Negligible at
  demo traffic; the first thing to model for a real storefront serving images.
- **NAT data processing** is $0.045/GB on top of the hourly charge. The DynamoDB
  gateway endpoint exists partly to keep the catalog read path out of that
  meter.
