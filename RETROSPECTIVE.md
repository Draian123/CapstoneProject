# Retrospective

What worked, what did not, and what I would do differently.

Written to be useful rather than flattering. The interesting parts of this
project were the things that went wrong, so those get the most space.

---

## What went well

### Making the environment disposable shaped everything else, for the better

The starting constraint was ordinary — I did not want a NAT Gateway billing
overnight. What I did not expect was how much of the architecture that one
requirement would end up improving.

Splitting the Terraform by **lifetime** rather than by service was the key move.
`bootstrap/` holds what must survive a teardown; `environments/` holds what
bills. Once that line existed, several decisions answered themselves: the alert
topic and the budget belong on the durable side, the state bucket obviously
does, and everything else is disposable.

It also forced the platform to be genuinely reproducible. When you rebuild an
environment from scratch several times a day, "it works if you apply it twice"
stops being tolerable very quickly. The catalog is seeded as code for the same
reason — a manual step to make the demo work is a step that will be forgotten on
demo day.

### Testing the failure, not just the happy path

Writing `scripts/demo-failover.sh` was the highest-value hour of the week. It
turned "the Auto Scaling group replaces failed instances" from a claim into a
measurement, and immediately proved the claim was only half right.

I would not have found the 502 window by reading the Terraform. It only appears
when you kill something and watch from outside.

### Policy as code caught things I would have argued about

The OPA policies turned out to be less about security and more about preventing
future-me from quietly lowering a standard. `availability.rego` fails the build
if `min_size` drops below three or the group spans fewer than two AZs. That is a
project requirement expressed as a test rather than as a sentence in a README
that nothing enforces.

Writing unit tests for the policies felt like overkill until one of them stopped
matching after I changed a helper. A policy that never fires is
indistinguishable from a policy that passes — and I would not have noticed
without the test.

---

## What did not go well

### I claimed zero downtime before I had measured it

The first version of this README said the platform self-heals with no user
impact. Then I actually terminated an instance and watched six requests fail.

The mechanism was obvious in hindsight: the load balancer cannot route away from
a dead target until its health checks notice, and mine were configured to take
up to 45 seconds to decide. Tuning to the ALB minimum cut that to two failed
requests and recovery from 171 to 99 seconds.

The number that stuck with me was the middle measurement. Halving the
theoretical window removed exactly **one** failed request. That is what made it
clear the window was an upper bound rather than a prediction, and it is why I
pushed to the floor the ALB allows rather than stopping at a number that looked
reasonable. If I had only measured before and after, I would have drawn the
wrong conclusion about why it improved.

Two is not zero, and no amount of tuning makes it zero. The documentation now
distinguishes zero-downtime *deployment* — which connection draining genuinely
delivers — from zero-downtime *instance failure*, which is not achievable at
this layer.

### I got the alerting architecture wrong the first time

I put the SNS topic in the monitoring module, which is where it looks like it
belongs. Then I tore the environment down, brought it back up, and found the
subscription sitting in `PendingConfirmation` again.

An email subscription only delivers after a confirmation click. Recreating the
topic on every bring-up meant a fresh confirmation email every time — and an
alert channel that has to be re-armed on every deploy is one that will
eventually be ignored, which makes it worse than no alert channel because you
believe you are covered.

The fix was to move the topic to the bootstrap layer. The budget moved with it,
for a sharper reason I had not thought of until then: the moment a cost alert
matters most is right after a teardown that did not fully succeed, and a budget
destroyed alongside the environment cannot warn about what the destroy missed.

The general lesson: **things that monitor an environment should not share that
environment's lifecycle.**

### I nearly shipped a bug that only appears on someone else's machine

I develop on Windows and deploy to Linux. Git would have checked out the shell
scripts with CRLF line endings on a fresh clone, including the instance
bootstrap script embedded in user-data. Every instance would have failed with
`bad interpreter: /usr/bin/env bash^M` — and it would not have surfaced as an
obvious error, but as an empty target group and a 503.

It worked on my machine because my working copy already had LF. `.gitattributes`
fixes it, and I only thought to add it because Git warned during a commit.

### Triaging scanner output took longer than writing the code

checkov produced 35 findings on the first run. My instinct was to fix them all;
that would have been wrong. Roughly a third traced back to a single fact — no
domain, so no HTTPS — several wanted customer-managed KMS keys costing more than
the data was worth, and two were false positives caused by checkov evaluating
modules in isolation.

One finding was actively harmful to act on. Enabling SNS encryption with the
AWS-managed key would have **silently broken alarm delivery**, because the
CloudWatch service principal cannot use an AWS-managed key. The scanner would
have gone green while the alerting path went dark. That is the clearest example
I have encountered of a control that breaks the thing it is meant to protect.

Working out which findings deserved a fix and which deserved a written
justification took longer than writing the module they were about. It was also
the part that taught me the most.

---

## Things that cost me time

Small, specific, and worth writing down.

**CloudWatch Logs Insights uses `#` for comments, not `--`.** I wrote six
queries with SQL-style comments, named them `.sql`, and every one was rejected
with `unexpected symbol`. They are not SQL, and calling them `.sql` was the
mistake that led to the other one.

**Git Bash rewrites arguments starting with `/`.** Passing a log group name like
`/aws/ec2/...` to the AWS CLI produced an `AccessDenied` naming a path under
Program Files. The fix is `MSYS_NO_PATHCONV=1` on that one command — and
crucially *not* exported globally, because Terraform is a Windows binary that
needs the conversion for `-chdir`. I broke my own scripts learning that.

**Rego `# METADATA` blocks are package annotations.** Six files each carrying
one meant six redeclarations of the same package annotation, and the whole suite
refused to load.

**SSM parameter values are sensitive by default.** Terraform refused to output
the AMI ID until I wrapped it in `nonsensitive()`. The default is right — most
SSM parameters hold secrets — but a public AWS-published AMI ID is not one.

---

## What I learned

**Cost intuition is not transferable from compute to networking.** I assumed the
instances would dominate the bill. They are $18/month against $49 for the NAT
Gateway and load balancer — the plumbing costs nearly three times the thing
doing the work. That inversion is the most useful pricing lesson from the week,
and it is why the single-NAT decision was worth an ADR.

**A health check should be shallow, and that is counter-intuitive.** My first
instinct was to have `/health` verify DynamoDB, because a "thorough" check
sounds better. It is exactly wrong: a health check that fails on a shared
dependency fails on *every instance at once*, empties the target group, and
converts a degraded feature into a total outage. The blast radius of a deep
health check is the entire fleet.

**Evaluate policy against the plan, not the source.** Policies that read HCL can
be defeated by moving a value into a variable. `terraform show -json` has
variables resolved, modules expanded and `default_tags` merged — it is what will
actually happen rather than what was written.

**"It applied successfully" is not "it works."** `terraform apply` returns when
AWS accepts the API calls, which can be minutes before the storefront serves a
request. Making `up.sh` poll until targets are healthy *and* the public URL
answers removed a whole category of false confidence.

**Automation has to be told what "normal" is.** Both CI guards in this project
exist because the automation's default assumption was wrong for an ephemeral
platform: apply would have resurrected a torn-down environment, and drift
detection would have filed a false issue every night.

---

## What I would do differently

**Measure before documenting.** I wrote the resilience claim before testing it
and had to correct it. Fault injection should have been the first thing built
after the ASG, not something added on day three.

**Set up the scanners on day one.** Retrofitting 33 justified suppressions
across seven files was tedious. Running checkov against the first module would
have spread that work across the week and, more importantly, would have
influenced the design instead of being reconciled with it.

**Reach for the AWS pricing calculator earlier.** I chose `t4g.micro` over
`t3.micro` and gp3 over gp2 for good reasons, but I did not know the actual
numbers until I wrote COSTS.md. Knowing that the NAT Gateway dwarfed everything
would have made the single-NAT decision an obvious first move rather than a
later optimisation.

**Write the ADRs while deciding, not after.** I reconstructed the reasoning for
the single NAT Gateway from memory. It was still accurate, but the alternatives
I had rejected — NAT instances, interface endpoints — were fuzzier than they
would have been at the time.

---

## What I would build next

In the order I would actually do them.

1. **HTTPS.** A domain, an ACM certificate, a 443 listener, and an 80 → 443
   redirect. About $12/year and twenty lines of Terraform, and it closes five
   scanner findings and the largest gap in the security posture. `alb_zone_id`
   is already exported for the Route 53 alias record.
2. **ALB access logs.** The one observability gap I consciously skipped.
3. **GuardDuty and AWS Config.** Both cost real money per account, and both are
   the first things I would add to an account I did not fully control.
4. **A synthetic canary.** Everything currently monitored is measured from
   inside AWS. A CloudWatch Synthetics canary hitting the storefront from
   outside would catch a DNS or listener failure that internal metrics show as
   perfectly healthy.
5. **Container the application, once it needs dependencies.** The user-data
   approach is right at 16 KB and wrong at 160 KB. ADR 0004 records the
   threshold so the decision gets revisited rather than stretched.
6. **Multi-region, properly or not at all.** A second idle stack that doubles
   the bill and provides false confidence is worse than an honest single-region
   design with a documented RTO. Doing it properly means solving data
   replication and DNS failover, which is a project rather than a feature.

---

## Closing thought

The parts of this project I am most pleased with are not the ones that
demonstrate a service. They are the two guards in the CI pipeline that stop
automation from doing something reasonable-looking and expensive, the health
check that is deliberately less thorough than it could be, and an incident
report about a problem nobody would have noticed.

Those all came from the same habit: asking what happens when this fails, rather
than checking that it works.
