# 4. Ship the application in instance user-data rather than as a container image

**Status:** Accepted
**Date:** 2026-08-31

## Context

The application has to reach the instances somehow. The usual options are a
container image in ECR pulled by ECS or by a Docker-enabled EC2 instance, an
artifact in S3 downloaded at boot, or a configuration management tool.

Each of those introduces something that must exist and be reachable before an
instance can become healthy. An instance that cannot fetch its application does
not fail loudly; it fails its health check, gets replaced by the Auto Scaling
group, and the replacement fails the same way. The symptom is an empty target
group and a 503, several minutes after the deploy that caused it.

## Decision

The application source is embedded directly into the launch template user-data
as a gzip and base64 encoded blob, written to disk at boot and run under a
systemd unit as an unprivileged user.

Changing `app/src/server.js` produces a new launch template version, which the
Auto Scaling group rolls out as an instance refresh holding 66% of capacity
healthy throughout.

## Consequences

The boot path has no artifact store, no registry, no credentials to distribute
and no network dependency beyond the operating system package repository. There
is correspondingly less that can be broken by something outside this repository.

The application and the infrastructure that runs it are versioned together, in
one commit. A rollback is `git revert` followed by an apply — there is no
possibility of the infrastructure and the application being at different
versions, because there is only one version.

Deployment is a rolling instance replacement, which is slower than restarting a
process but is also a genuine zero-downtime demonstration, and it exercises the
instance refresh mechanism on every application change.

The constraint this imposes is a hard one: EC2 user-data is limited to 16 KB.
The application is about 16 KB of source, which compresses to roughly 7.5 KB
encoded, leaving comfortable room for the bootstrap script. That headroom is not
unlimited, and this decision does not survive the application growing into
several modules with dependencies. At that point the right move is ECR and a
container, and this ADR should be superseded rather than stretched.

It also forces the application to have no npm dependencies, since there is no
`npm install` step. That constraint turned out to be a feature — it is why
instances become healthy in well under a minute — but it is a constraint, and it
is the reason DynamoDB is read through the AWS CLI rather than through the SDK.

### Alternatives considered

**ECR plus ECS Fargate.** The modern default, and a stronger answer for a real
service. Rejected as scope: it replaces the entire compute module, and the
Advanced requirements were already met without it.

**S3 artifact downloaded at boot.** Removes the size limit and keeps the
instances simple. Rejected because it needs a bucket, a bucket policy, an
instance role grant and a CI step to upload — and because a failed download at
boot produces exactly the silent unhealthy-instance failure this decision was
trying to avoid.

**A pre-baked AMI built by Packer.** The fastest boot of any option, and the
most operationally sound at scale. Rejected because an image build pipeline is a
project of its own, and because a five-day capstone that rebuilds an AMI on
every application tweak would spend most of its time waiting.
