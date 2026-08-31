# Backup screenshots

The demo is worth 7 of the 25 presentation points, and a live demo that fails
on stage costs most of them. These exist so that a broken demo becomes a
five-second pivot instead of a two-minute debugging session in front of an
audience.

Capture them **while the environment is up**, the day before.

## What is here

| File | Status |
|---|---|
| `01-storefront-live.jpg` | ✅ Captured — storefront serving, instance ID and AZ visible, six catalog rows from DynamoDB |

## Still to capture

These need an AWS console login, so they have to be taken by hand.

```bash
scripts/up.sh dev          # bring it up first
```

**`02-dashboard.png`** — CloudWatch → Dashboards → `ce-capstone-dev-overview`.
Reload the storefront thirty or forty times first so the request rate and
latency widgets have a visible shape rather than a flat line. Capture the whole
dashboard, not one widget.

**`03-target-health.png`** — EC2 → Target Groups → `ce-capstone-dev-tg` →
Targets. Three healthy targets across two availability zones, in one frame.
This is the multi-AZ claim in a single image.

**`04-failover.png`** — a terminal showing a completed
`scripts/demo-failover.sh` run: the healthy count dropping to 2 and returning to
3, the recovery time, and the failed-request count. If the live demo fails, this
is the slide that saves the deep dive.

**`05-pipeline-blocked.png`** — a pull request where the policy gate failed.
Produce one deliberately:

```bash
git checkout -b demo/policy-violation
# In terraform/environments/dev/terraform.tfvars, set min_size = 1
git commit -am "demo: lower min_size below the policy floor"
git push -u origin demo/policy-violation
```

Open the PR and wait for `plan dev` to fail. Screenshot the failed check and the
policy message naming `min_size`. **Then close the PR and delete the branch** —
it must not be merged.

**`06-alarm-email.png`** — the SNS notification from a real alarm transition.
The failover run triggers `ce-capstone-dev-unhealthy-hosts`; screenshot the
email. This proves the alerting path works end to end, which nothing else in the
demo shows.

## During the presentation

Have this folder open in an image viewer, ordered, before you start. If
something fails: say "I have this captured", switch, and keep going. Do not
debug on stage — see `../demo-script.md`.
