# 3. Use DynamoDB rather than RDS for the product catalog

**Status:** Accepted
**Date:** 2026-08-31

## Context

The platform needs a data tier. Without one there are only two tiers, the
multi-tier architecture requirement is weakly met, and the application has no
reason to hold an IAM role — which removes the most natural place to demonstrate
least-privilege access.

The workload is a product catalog: a handful of rows, read on every page load,
written only when the catalog changes. An e-commerce theme would conventionally
suggest a relational database.

## Decision

The catalog is a DynamoDB table in on-demand billing mode, reached from the
private subnets through a VPC gateway endpoint.

## Consequences

Cost is effectively zero when nobody is using the platform. On-demand billing
charges per request, so an environment sitting idle overnight costs nothing for
its data tier. A `db.t4g.micro` RDS instance would bill about USD 12 per month
whether or not a single query was served — and would keep billing while the rest
of the environment was torn down, unless it were torn down too, which then means
restoring data on every bring-up.

The gateway endpoint is free and keeps data-tier traffic inside the VPC. It
never traverses the NAT Gateway, so it incurs no data processing charge and
never touches the public internet. An RDS instance would have needed a subnet
group, a parameter group, a security group and a failover topology, all of which
is architecture that exists to serve the database rather than the storefront.

There is no connection pool, no credential to rotate and no secret to store. The
instance role grants five read-only DynamoDB actions on one table ARN. That is
the least-privilege story the security documentation needed, and it is genuinely
least-privilege rather than a plausible-looking approximation.

What is given up is real. There are no joins, no transactions across entities
and no ad-hoc queries. A catalog that grew into orders, customers and inventory
with referential integrity between them would outgrow this quickly, and the
right response then is RDS, not a pile of single-table-design workarounds.

The application currently `Scan`s the table, which is the wrong access pattern at
any real scale and is called out as such in the code. At six rows it is honest;
at six thousand it would need a partition key and a `Query`.

### Alternatives considered

**RDS PostgreSQL, Multi-AZ.** The conventional answer, and the right one for a
relational workload. Rejected on cost and on the amount of incidental
infrastructure it drags in for a read-only list of six products.

**A JSON file baked into the AMI or user-data.** Cheapest of all, and rejected
because it collapses the data tier back into the application tier. The point of
this component is to demonstrate tier separation, an IAM-scoped data path and a
backup strategy — none of which a static file exercises.

**ElastiCache in front of a database.** Rejected as a cache with nothing worth
caching behind it. The application already holds the catalog in memory and
refreshes it on a timer, which is the same benefit for no additional service.
