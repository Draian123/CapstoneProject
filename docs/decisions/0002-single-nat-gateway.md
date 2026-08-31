# 2. Share one NAT Gateway across availability zones in dev

**Status:** Accepted
**Date:** 2026-08-31

## Context

Instances in the private subnets need outbound internet access to install
packages at boot and to ship CloudWatch agent telemetry. A NAT Gateway provides
that.

A NAT Gateway is a zonal resource. The textbook design puts one in each
availability zone, so that losing a zone does not take outbound connectivity
away from the surviving zone.

It is also the single most expensive component in this architecture. At roughly
USD 0.045 per hour plus data processing, one gateway is about USD 32 per month;
two are about USD 64. Against a dev environment that costs roughly USD 67 per
month running continuously, a second gateway is nearly half the bill.

This is a demonstration environment for a bootcamp capstone, funded personally,
and torn down between working sessions.

## Decision

The dev environment uses one NAT Gateway, shared by both private subnets, via
`single_nat_gateway = true`.

The prod environment sets `single_nat_gateway = false` and gets one per zone.

The networking module keeps a separate route table per availability zone in both
cases, even when they all point at the same gateway. That way the difference
between the two postures is a single boolean, with no resource restructuring and
no route table replacement.

## Consequences

Dev saves about USD 32 per month, which is the difference between an environment
that is comfortable to run and one that is not.

Dev accepts a real failure mode: if `us-east-1a` fails, instances in
`us-east-1b` lose outbound internet access. What they do *not* lose is the
ability to serve requests. Inbound traffic reaches them through the load
balancer, which is genuinely multi-AZ, and the catalog is read through a
DynamoDB gateway endpoint that does not traverse the NAT at all. The blast
radius is limited to package installation on newly launched instances and to
CloudWatch telemetry — degraded operations, not a user-visible outage.

Prod does not accept that failure mode, and its configuration says so.

### Alternatives considered

**One NAT Gateway per AZ everywhere.** Correct, and rejected on cost alone for
an environment that exists to be demonstrated.

**NAT instances instead of NAT Gateways.** A `t4g.nano` NAT instance is roughly
USD 3 per month against USD 32. Rejected because it reintroduces a host to
patch, monitor and replace, and because a self-managed NAT is exactly the kind
of undifferentiated work that managed services exist to remove. The saving is
real but it is bought with operational burden.

**VPC endpoints for everything, no NAT at all.** Interface endpoints for SSM,
CloudWatch Logs and the package repositories would remove the NAT dependency
entirely. Rejected because interface endpoints cost about USD 7 per month each
per AZ, so the four or five needed would cost more than the gateway they
replaced. The one place this argument does win is DynamoDB, whose *gateway*
endpoint is free — and that one is used.
