# 1. Record architecture decisions

**Status:** Accepted
**Date:** 2026-08-31

## Context

This platform makes a number of choices that look wrong without their reasoning
attached. A single shared NAT Gateway looks like a high-availability mistake. A
NoSQL table under an e-commerce catalog looks like the wrong data model. Reading
DynamoDB by shelling out to the AWS CLI looks like a hack.

Each of those is defensible, but only with the context that produced it. Code
comments capture the local "what"; they are the wrong place for a decision that
spans several files and weighs an option that was ultimately rejected.

## Decision

Significant architectural decisions are recorded as short numbered documents in
`docs/decisions/`, following the Nygard ADR format: context, decision,
consequences. Records are immutable — a decision that is later reversed gets a
new ADR that supersedes the old one, rather than an edit that erases the history.

"Significant" means a decision that is expensive to reverse, that a reviewer
would reasonably question, or that trades one desirable property against another.

## Consequences

The reasoning survives the person who made it, which is the point: this is a
portfolio project whose whole purpose is to be read and questioned by someone
who was not there.

Reversing a decision costs a new document. That is intentional friction — cheap
enough not to obstruct, expensive enough to prompt a moment of thought.

The rejected alternatives are the most useful part of each record and are stated
explicitly, because "why not the obvious thing" is the question an interviewer
actually asks.
