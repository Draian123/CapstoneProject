# CloudWatch Logs Insights queries

Saved queries for investigating an incident. Each `.txt` file in this directory
is a ready-to-paste Logs Insights query; this file explains when to reach for
which one.

They all rely on the application emitting one JSON object per line, which Logs
Insights parses into queryable fields automatically. That is why the application
logs structured JSON rather than human-readable text — the log line is written
once and read by a machine many times.

Run them against `/aws/ec2/ce-capstone-<env>/app`, or from the CLI:

```bash
scripts/status.sh dev          # confirm the environment is up first

aws logs start-query \
  --log-group-name /aws/ec2/ce-capstone-dev/app \
  --start-time "$(date -u -d '1 hour ago' +%s)" \
  --end-time "$(date -u +%s)" \
  --query-string "$(cat monitoring/queries/errors.txt)"
```

| Query | Reach for it when |
|---|---|
| [`errors.txt`](errors.txt) | Anything is wrong. This is the first query to run. |
| [`slow-requests.txt`](slow-requests.txt) | The p95 latency alarm fired. |
| [`requests-by-instance.txt`](requests-by-instance.txt) | Traffic looks unevenly distributed, or one instance is suspect. |
| [`catalog-health.txt`](catalog-health.txt) | The storefront shows an empty catalog. |
| [`bootstrap-failures.txt`](bootstrap-failures.txt) | Instances are launching but never becoming healthy. |
| [`traffic-profile.txt`](traffic-profile.txt) | Establishing whether load is the cause, or the symptom. |

## Fields the application emits

Every line carries `ts`, `level`, `message`, `instanceId` and `az`. Request lines
add `method`, `path`, `status` and `durationMs`. Errors add `error`.

Health check requests are deliberately **not** logged. The load balancer polls
`/health` every 15 seconds per instance, so at three instances that is 17,000
lines a day of pure noise that would both bury real events and dominate the
CloudWatch ingestion bill.

The consequence worth knowing during an incident: absence of log lines does not
mean absence of traffic. Use the ALB `RequestCount` metric for that.
