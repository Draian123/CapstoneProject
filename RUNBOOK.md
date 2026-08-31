# Runbook

Operating the platform: deploying it, changing it, diagnosing it when it
misbehaves, and recovering it when something is lost.

Written to be usable at 2am by someone who did not build it.

---

## Quick reference

```bash
scripts/status.sh              # is anything running, and what has it cost?
scripts/up.sh dev              # deploy, and wait until it actually serves
scripts/down.sh dev            # destroy everything that bills
scripts/demo-failover.sh dev   # kill an instance, watch it recover
```

| | |
|---|---|
| Region | `us-east-1` |
| Account | `697345203222` |
| State bucket | `ce-capstone-tfstate-<account-id>` |
| Dashboard | CloudWatch → Dashboards → `ce-capstone-dev-overview` |
| Alert topic | `ce-capstone-alerts` (bootstrap layer, shared) |
| Running cost | ~USD 0.096/hour |

> **Windows note.** Git Bash rewrites arguments beginning with `/` into Windows
> paths. Passing a CloudWatch log group like `/aws/ec2/...` to the AWS CLI
> produces a confusing `AccessDenied` naming a path under Program Files. Prefix
> that one command with `MSYS_NO_PATHCONV=1` — do not export it globally, because
> Terraform is a Windows binary and needs the conversion for `-chdir`.

---

## First-time setup

Once per AWS account.

```bash
scripts/bootstrap.sh
```

Creates the state bucket, the GitHub OIDC provider and CI roles, the shared SNS
alert topic and the project budget. It prompts once for an alert email address
and stores it in `.alert-email` (gitignored).

Then:

**1. Confirm the alert subscription.** AWS sends a confirmation email. Until the
link is clicked, alarms fire into nothing — and Terraform reports success either
way, so this failure is silent.

```bash
MSYS_NO_PATHCONV=1 aws sns list-subscriptions-by-topic \
  --topic-arn "$(terraform -chdir=terraform/bootstrap output -raw alerts_topic_arn)" \
  --query 'Subscriptions[].SubscriptionArn' --output text
```

An ARN means confirmed. The literal string `PendingConfirmation` means it is
not. This is a one-time step: the topic lives in the bootstrap layer
specifically so it survives environment teardowns.

**2. Set the GitHub Actions repository variables.** Settings → Secrets and
variables → Actions → **Variables** (not Secrets — these are role ARNs, not
credentials):

```
AWS_PLAN_ROLE_ARN   = arn:aws:iam::697345203222:role/ce-capstone-gha-plan
AWS_APPLY_ROLE_ARN  = arn:aws:iam::697345203222:role/ce-capstone-gha-apply
```

**3. Enable branch protection** on `main`. Settings → Branches → Add rule:

- Require a pull request before merging
- Require status checks to pass. Add these five, **one entry each**:
  `validate`, `policy unit tests`, `security scan`, `plan dev`, `plan prod`

  > None of these contain a comma, and that is deliberate. Several GitHub UIs
  > treat a required-check list as comma-separated, so a check name containing
  > one is silently split into two names that never report — leaving the branch
  > unmergeable with no visible cause.
- Require branches to be up to date before merging

**4. Activate the `Project` cost allocation tag.** Billing → Cost allocation
tags → activate `Project`. Until then `scripts/status.sh` cannot break spend
down by project. It backfills within about 24 hours.

---

## Deploying

### Normal deployment

```bash
scripts/up.sh dev
```

Roughly six minutes. The script does not return until the target group reports
three healthy targets *and* `/health` answers over the public URL — because
"apply completed" and "the site works" are not the same event.

### Deploying an application change

Edit `app/src/server.js` and re-run `scripts/up.sh dev`.

The application is embedded in the launch template, so a change produces a new
template version, which triggers a rolling instance refresh holding 66% of
capacity healthy throughout. No requests are dropped: instances are deregistered
and connections drained before termination.

Watch it:

```bash
aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name "$(terraform -chdir=terraform/environments/dev output -raw autoscaling_group_name)" \
  --query 'InstanceRefreshes[0].[Status,PercentageComplete]' --output text
```

If the new version is broken, `auto_rollback` reverts to the previous launch
template version automatically.

### Deploying through CI

Open a pull request. The plan workflow posts the plan as a comment. On merge,
the apply workflow deploys.

**The apply workflow will not create a torn-down environment.** If dev holds no
resources it skips with an explanation, because otherwise an ordinary merge
would silently start the meter. To deploy from nothing, run the workflow
manually with `create_if_absent` enabled.

### Tearing down

```bash
scripts/down.sh dev            # prompts for confirmation
scripts/down.sh dev --yes      # end-of-session, no prompt
```

Destroys the environment layer only. The bootstrap layer — state, CI roles,
alert topic, budget — is left alone. It costs effectively nothing and destroying
it would mean losing the state that makes the next bring-up one command.

**prod has deletion protection on**, so a prod destroy fails part-way until
`enable_deletion_protection` is set to `false` and applied. That is deliberate
friction, not a bug.

---

## Monitoring

Dashboard: CloudWatch → Dashboards → `ce-capstone-dev-overview`, or the
`dashboard_url` printed by `scripts/up.sh`.

The top row answers *is the service healthy for users* — request rate and
errors, latency percentiles, target health. The rows below answer *why* — CPU,
memory, scaling activity, DynamoDB, and a live log widget of errors and
warnings.

Alarm thresholds are drawn on the widgets as annotations, so you can see how
close to the edge the system is running without opening the alarm definitions.

Saved Logs Insights queries live in [`monitoring/queries/`](monitoring/queries/);
each alarm and its reasoning is documented in
[`monitoring/alerts/`](monitoring/alerts/README.md).

```bash
# Health of the whole platform, in one command
scripts/status.sh dev
```

---

## Troubleshooting

### Storefront returning 5xx

Alarm: `ce-capstone-dev-elb-5xx`

The load balancer could not get a valid response from any healthy target.

```bash
# 1. How many targets are actually in service?
aws elbv2 describe-target-health \
  --target-group-arn "$(terraform -chdir=terraform/environments/dev output -raw target_group_arn)" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
  --output table
```

- **Zero healthy targets** → every instance is failing. Almost always a bad
  application version; go to *Instance failing health checks* below. Consider
  `git revert` and re-apply.
- **Some healthy** → the failing instances are being replaced. Check whether the
  count is recovering before intervening.
- **All healthy but still 5xx** → the application is returning errors itself.
  Run `monitoring/queries/errors.txt`.

```bash
MSYS_NO_PATHCONV=1 aws logs start-query \
  --log-group-name "/aws/ec2/ce-capstone-dev/app" \
  --start-time "$(( $(date -u +%s) - 3600 ))" --end-time "$(date -u +%s)" \
  --query-string "$(cat monitoring/queries/errors.txt)"
```

### Instance failing health checks

Alarm: `ce-capstone-dev-unhealthy-hosts`

This alarm does not mean "an instance failed" — the ASG replaces those by
itself. It means an instance failed **and the automation has not fixed it**
within three minutes.

The dangerous case is a bad launch template version, where every replacement
fails identically and the group grinds through instances without recovering.

```bash
# Did the instance ever finish bootstrapping?
MSYS_NO_PATHCONV=1 aws logs start-query \
  --log-group-name "/aws/ec2/ce-capstone-dev/app" \
  --start-time "$(( $(date -u +%s) - 1800 ))" --end-time "$(date -u +%s)" \
  --query-string "$(cat monitoring/queries/bootstrap-failures.txt)"
```

The last line before the silence is the failing step. Usual causes, in order of
likelihood:

1. **Package install failed** — the NAT Gateway or its route is broken, so
   `dnf` could not reach the repositories.
2. **`node --check` failed** — the embedded application has a syntax error.
   This should have been caught by `npm test`; check whether CI was skipped.
3. **Service never answered its own probe** — the app started and crashed.
   `systemctl status ce-capstone` on the instance.

To get onto an instance — no SSH, no key pair:

```bash
aws ssm start-session --target i-0abc123...
sudo journalctl -u ce-capstone -n 100 --no-pager
sudo cat /var/log/ce-capstone-bootstrap.log
```

### Sustained high CPU

Alarm: `ce-capstone-dev-cpu-high`

The threshold sits above the scaling setpoint, so this means scaling is not
keeping up or has hit `max_size` — not merely that the system is busy.

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$(terraform -chdir=terraform/environments/dev output -raw autoscaling_group_name)" \
  --query 'AutoScalingGroups[0].[DesiredCapacity,MaxSize,length(Instances)]' --output text
```

If desired equals max, the group is capped. Raise `max_size` in
`terraform.tfvars` and apply. If desired is below max but not growing, check
Activity History for launch failures — usually an instance type unavailable in
an AZ, or an account limit.

If nothing is actually serving traffic, suspect `/stress` being hit.

### Elevated latency

Alarm: `ce-capstone-dev-latency-p95`

Usually the first alarm to fire in a gradual incident.

```bash
MSYS_NO_PATHCONV=1 aws logs start-query \
  --log-group-name "/aws/ec2/ce-capstone-dev/app" \
  --start-time "$(( $(date -u +%s) - 3600 ))" --end-time "$(date -u +%s)" \
  --query-string "$(cat monitoring/queries/slow-requests.txt)"
```

If p99 is far above p95, a small number of pathological requests are
responsible. If p50 has moved too, the whole fleet is struggling — check CPU and
whether scaling is keeping up.

Run `traffic-profile.txt` to distinguish cause from symptom: errors rising *with*
traffic points at capacity; errors rising while traffic is flat points at
something breaking on its own.

### Storefront shows an empty catalog

Nothing alarms on this by design — the app stays healthy and serves its last
known catalog, because a health check that failed on DynamoDB would empty the
entire target group at once.

```bash
curl -s "$(terraform -chdir=terraform/environments/dev output -raw storefront_url)/health" | jq .catalog
```

`degraded: true` means DynamoDB is unreachable. Run
`monitoring/queries/catalog-health.txt`:

- **`AccessDenied`** → the instance role lost its DynamoDB grant.
- **Timeout** → the VPC gateway endpoint or its route table association is
  broken. Check `dynamodb_vpc_endpoint_id` still exists and is associated with
  both private route tables.
- **`ResourceNotFoundException`** → the table name changed but the launch
  template was not refreshed.

### Terraform state is locked

```
Error acquiring the state lock
```

Usually a cancelled apply. Confirm nothing is genuinely running — check the
Actions tab — then:

```bash
terraform -chdir=terraform/environments/dev force-unlock <LOCK_ID>
```

Never force-unlock while an apply might still be in flight; two concurrent
applies against one state will corrupt it.

### CI cannot authenticate to AWS

```
Credentials could not be loaded
```

The `AWS_PLAN_ROLE_ARN` / `AWS_APPLY_ROLE_ARN` repository **variables** are not
set — see [First-time setup](#first-time-setup). If they are set and it still
fails, the trust policy did not match: check that the workflow ran from this
repository and, for apply, from `main`.

---

## Recovery

### Restore the catalog

**Point-in-time recovery** — 35-day window, ~5 minute RPO. Covers a bad write or
an accidental delete. Restores to a *new* table:

```bash
aws dynamodb restore-table-to-point-in-time \
  --source-table-name ce-capstone-dev-products \
  --target-table-name ce-capstone-dev-products-restored \
  --restore-date-time "2026-08-31T10:00:00Z"
```

Verify the restored table, then either repoint `PRODUCTS_TABLE` in the compute
module, or copy the items back and delete the restored table.

**AWS Backup** — daily snapshots, 7-day retention in dev. Covers what PITR
cannot: deletion of the table itself.

```bash
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name ce-capstone-dev-backup-vault \
  --query 'RecoveryPoints[].[RecoveryPointArn,CreationDate]' --output table
```

### Rebuild everything

The environment is disposable by design, so total loss of the environment is a
routine operation rather than a disaster:

```bash
scripts/up.sh dev
```

Six minutes, and the catalog is re-seeded from `terraform/modules/data/variables.tf`.

### Recover Terraform state

The state bucket is versioned, and `prevent_destroy` is set on it.

```bash
aws s3api list-object-versions \
  --bucket "ce-capstone-tfstate-$(aws sts get-caller-identity --query Account --output text)" \
  --prefix ce-capstone/dev/terraform.tfstate \
  --query 'Versions[].[VersionId,LastModified]' --output table

aws s3api get-object \
  --bucket ce-capstone-tfstate-<account> \
  --key ce-capstone/dev/terraform.tfstate \
  --version-id <VERSION_ID> restored.tfstate
```

If state is lost entirely but resources still exist, the fastest honest path is
to delete the orphaned resources by tag (`Project=ce-capstone`) and re-run
`scripts/up.sh`. Re-importing 77 resources by hand is slower and more error-prone
than rebuilding something that takes six minutes to create.

### Region failure

Not survivable as designed. Single-region by choice — see
[ARCHITECTURE.md](ARCHITECTURE.md#high-availability). Recovery would mean
changing `aws_region`, creating a state bucket in the new region, and running
`scripts/up.sh`. RTO is however long that takes; RPO for the catalog is ~5
minutes if the DynamoDB PITR data survived, and zero if the seed data is treated
as the source of truth, which for this catalog it is.

---

## Routine operations

### Scaling

```bash
# Permanent: edit terraform.tfvars, then
scripts/up.sh dev

# Temporary, e.g. before a demo — will be reverted by the next apply
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$(terraform -chdir=terraform/environments/dev output -raw autoscaling_group_name)" \
  --desired-capacity 4
```

Note that a manual change is drift, and the nightly drift job will file an issue
for it. That is the system working.

### Cost check

```bash
scripts/status.sh              # both environments + month-to-date spend
```

If this reports an environment UP that should not be, that is the failure mode
the budget forecast alert exists to catch. Run `scripts/down.sh`.

### Rotating the alert email

```bash
echo "new@example.com" > .alert-email
terraform -chdir=terraform/bootstrap apply
```

Confirm the new subscription; the old one is removed automatically.

### Verifying resilience

```bash
scripts/demo-failover.sh dev
```

Terminates an instance and probes throughout. Expect ~99s to full capacity and
around two failed requests — see
[the incident report](docs/incident-reports/2026-08-31-failover-502-window.md)
for why that number is not zero.
