# Alerts

Four alarms, defined in `terraform/modules/monitoring/main.tf` and delivered to
one SNS topic subscribed by email.

Every alarm here means something different. That is the design constraint: a set
of alarms that all fire together during the same incident teaches the operator
to ignore the channel, and an alarm nobody acts on is worse than no alarm,
because it costs attention and returns nothing.

Each one below states what it detects, why the threshold is where it is, and
what to do when it fires. If an alarm ever fires and the answer is "nothing",
that alarm should be deleted rather than tolerated.

---

## `ce-capstone-<env>-elb-5xx` — critical

| | |
|---|---|
| **Metric** | `AWS/ApplicationELB` · `HTTPCode_ELB_5XX_Count` · Sum |
| **Condition** | more than 5 per minute, for 2 consecutive minutes |
| **Missing data** | treated as not breaching |
| **Runbook** | [Storefront returning 5xx](../../RUNBOOK.md#storefront-returning-5xx) |

The load balancer generated the error itself, which means it could not get a
valid response from *any* healthy target. This is the strongest single signal
that the site is broken for real users.

Note the distinction from `HTTPCode_Target_5XX_Count`: that one means the
application returned an error, which is a bug. This one means there was nothing
to ask, which is an outage.

The threshold is 5 rather than 1 because a single 5xx during an instance refresh
is normal — a connection can be in flight when a target deregisters. Two
consecutive breaching minutes filters that out while still catching a real
failure inside three minutes.

Missing data is not breaching because a torn-down environment produces no
datapoints, and this platform is torn down between working sessions.

---

## `ce-capstone-<env>-unhealthy-hosts` — high

| | |
|---|---|
| **Metric** | `AWS/ApplicationELB` · `UnHealthyHostCount` · Maximum |
| **Condition** | at least 1 unhealthy target, for 3 consecutive minutes |
| **Runbook** | [Instance failing health checks](../../RUNBOOK.md#instance-failing-health-checks) |

Capacity is eroding. This fires *before* users notice, while the remaining
instances still absorb the traffic.

Under normal operation this should self-resolve: the Auto Scaling group uses ELB
health checks, so it terminates and replaces a failing instance without help.
The alarm therefore is not "an instance failed" — it is "an instance failed and
the automation has not fixed it". Three minutes is roughly how long replacement
takes, so an alarm that stays in ALARM means the self-healing is not working, or
the replacement is failing the same way.

That second case is the dangerous one: a bad launch template version means every
replacement fails identically, and the group grinds through instances without
ever recovering.

---

## `ce-capstone-<env>-cpu-high` — medium

| | |
|---|---|
| **Metric** | `AWS/EC2` · `CPUUtilization` · Average, by Auto Scaling group |
| **Condition** | above 80% (70% in prod) for 2 consecutive 5-minute periods |
| **Runbook** | [Sustained high CPU](../../RUNBOOK.md#sustained-high-cpu) |

Saturation. The threshold deliberately sits *above* the target-tracking scaling
setpoint of 50% (40% in prod), which is the whole point: the scaling policy is
supposed to hold the fleet near its setpoint, so CPU sustained well above it
means scaling is not keeping up, or the group has hit `max_size`.

If this alarm fired at the setpoint it would fire every time the system worked
correctly.

Ten minutes of breach before alerting is deliberate. Burst traffic that the
scaling policy handles on its own is not an incident, and waking someone for it
is how alert fatigue starts.

---

## `ce-capstone-<env>-latency-p95` — medium

| | |
|---|---|
| **Metric** | `AWS/ApplicationELB` · `TargetResponseTime` · p95 |
| **Condition** | above 1.0s (0.5s in prod) for 2 of 3 minutes |
| **Runbook** | [Elevated latency](../../RUNBOOK.md#elevated-latency) |

Degradation short of failure. The service is answering, so the error-rate alarms
stay silent, but it is answering slowly.

This catches the slow-then-broken pattern that error alarms miss entirely: a
dependency timing out, a fleet too small for its traffic, or an instance
thrashing. It is usually the first alarm to fire in a gradual incident, and it
is the one that gives enough warning to act before users are affected.

p95 rather than average, because an average hides the tail — a fleet where one
instance in ten is timing out has a barely-moved average and a p95 through the
roof. "2 of 3" rather than "3 of 3" datapoints so that a brief recovery inside a
degrading window does not reset the count.

---

## What is deliberately not alarmed

**Catalog degradation.** When the application cannot reach DynamoDB, `/health`
reports `catalog.degraded: true` but still returns 200, and no alarm fires. This
is intentional and is the most important design decision in the monitoring
setup: a health check that fails on a shared dependency takes *every* instance
out of the target group simultaneously, converting a degraded feature into a
total outage. The storefront keeps serving its last known catalog instead. The
condition is visible on the dashboard and in the logs.

**Individual instance termination.** Expected behaviour — the Auto Scaling group
replaces instances routinely, and during an instance refresh it does so on
purpose.

**Cost.** Handled separately by an AWS Budget on the same SNS topic, at 80% of
actual and 100% of forecast monthly spend. Notably, the forecast alert is the
one that catches a failed teardown on day two rather than on day twenty.

---

## Notification channel

All four alarms and both budget notifications publish to a single SNS topic,
`ce-capstone-<env>-alerts`, subscribed by email.

The subscription requires a one-time confirmation click. Terraform reports
success as soon as the subscription is created, whether or not it has been
confirmed, so a first apply silently produces alarms that fire into nothing
until that email is confirmed. `RUNBOOK.md` covers verifying this.

The address is supplied at apply time through `TF_VAR_alert_email` and is never
committed, because this repository is public.

Both `alarm_actions` and `ok_actions` are set, so recovery is notified as well as
failure. An alert channel that only ever reports bad news leaves the operator
refreshing a dashboard to find out whether their fix worked.
