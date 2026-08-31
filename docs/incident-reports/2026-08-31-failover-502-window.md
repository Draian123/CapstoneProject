# Failed requests during hard instance failure

**Date:** 2026-08-31
**Environment:** dev
**Severity:** Low — found by deliberate fault injection, never experienced by a user
**Status:** Resolved, with a documented residual limit

## Summary

Killing an application instance outright caused a short window in which the
load balancer kept sending traffic to the dead instance and returned 502s. The
first measured run lost 6 requests over roughly 45 seconds.

Tuning the target group health check from a 15-second interval with 3 failures
required, down to the 5-second / 2-failure floor the ALB permits, reduced this
to 2 failed requests and cut full capacity recovery from 171 seconds to 99.

The window cannot be closed entirely. That limit is explained below, because
the honest version of this result matters more than a round number.

## How it was found

Not by an alarm. By running `scripts/demo-failover.sh`, which terminates an
instance and probes `/health` once per second throughout, specifically to check
whether the self-healing claim survived contact with reality.

It did not, quite. The Auto Scaling group replaced the instance exactly as
designed — but "the group recovers" and "no user saw anything" turned out to be
two different claims, and only the first was true.

## What happened

`aws ec2 terminate-instances` kills an instance immediately. It does not go
through the Auto Scaling lifecycle, so there is no deregistration and no
connection draining. This is deliberate: it is the closest available simulation
of hardware failure or an availability zone going away, which is the failure
mode worth testing.

From the load balancer's point of view the target simply stops answering. It has
no way to know the difference between a dead instance and a slow one, so it
keeps routing traffic there until its own health checks conclude the target is
unhealthy. Every request routed to that target in the meantime fails.

The size of that window is arithmetic:

```
worst-case error window = health check interval x unhealthy_threshold
```

The original configuration was 15 seconds and 3 failures, giving up to 45
seconds. The observed failures spanned about 42 seconds of that budget.

The second-order effect is that the same detection delay gates recovery: the
Auto Scaling group only learns the instance is unhealthy when the load balancer
does, so slow detection also means a slow replacement.

## Measurements

Three runs, identical method, one instance terminated each time. The probe sends
one request per second to `/health` through the load balancer.

| Health check | Error window | Failed requests | Capacity restored |
|---|---|---|---|
| 15s interval, 3 failures | 45s | 6 | 171s |
| 10s interval, 2 failures | 20s | 5 | 195s |
| **5s interval, 2 failures** | **10s** | **2** | **99s** |

The middle row is the interesting one, and it is included precisely because it
looks like a failure. Halving the theoretical window removed one failed request.
That was the point at which it became clear the theoretical window was an upper
bound and the real variable was how much of it a given failure happened to land
in — which is why the change was pushed to the floor the ALB allows rather than
stopping at a number that looked reasonable.

The recovery time improvement was not the goal but follows directly: detection
gates replacement.

## Fix

`terraform/modules/compute/main.tf`, target group health check:

```hcl
interval            = 5   # was 15
timeout             = 3   # was 5, must stay below the interval
healthy_threshold   = 2   # unchanged
unhealthy_threshold = 2   # was 3
```

5 seconds is the minimum interval an Application Load Balancer accepts and 2 is
the minimum unhealthy threshold, so this is the floor rather than a chosen
value. The timeout has to sit below the interval, and 3 seconds is generous for
an endpoint that answers in well under a millisecond.

The cost of this change is zero. Health checks are not billed. The only real
trade-off is sensitivity: a shorter threshold makes the load balancer quicker to
pull an instance that is briefly slow. That is acceptable here because `/health`
is deliberately shallow — it does not touch DynamoDB, so it does not get slow
when a dependency does.

## What this does not fix

Two failed requests is not zero, and no amount of health check tuning will make
it zero. The load balancer cannot route away from a target before it knows the
target is gone, so some window always exists.

Worth being precise about which operations this affects:

- **Ungraceful failure** — hardware failure, AZ loss, `terminate-instances`. A
  brief error window is unavoidable. Now roughly 10 seconds.
- **Graceful operations** — deploys, instance refresh, scale-in. Already
  error-free, and unaffected by this change, because the Auto Scaling group
  deregisters the target and the load balancer drains connections over the
  30-second `deregistration_delay` before the instance goes away.

So "zero-downtime deployment" is a claim this platform can make. "Zero-downtime
instance failure" is not, and the presentation says so.

Closing the remaining window would need retry logic at a layer above the load
balancer — a CDN or a client with retries — which is a different architecture
rather than a tuning change.

## Follow-up

- [x] Health check tuned to the ALB minimum
- [x] Re-measured to confirm the improvement rather than assuming it
- [x] Reasoning recorded in the module, next to the values it explains
- [x] `scripts/demo-failover.sh` kept as a repeatable check, not a one-off
- [ ] Consider whether the p95 latency alarm should also cover failover windows;
      currently a 10-second blip is too short to trip it, which is arguably
      correct given nothing actionable would come of the page

## What this changed about how the platform is described

Before this, the README would have said the platform self-heals with no user
impact. It now says self-healing takes about 100 seconds and that an ungraceful
instance failure costs a handful of requests in a roughly 10-second window.

The second version is less impressive and is the one that is true. It is also
the version that survives an interviewer asking "how do you know?".
