# Demo script

Twelve minutes of presentation, three of which are live. This is the running
order, the exact commands, and what to say while each one runs.

**The single most important line in this document:** bring the environment up
**before** the presentation starts, not during it. A NAT Gateway takes about
four minutes to provision, and there is no version of that which is good
television.

---

## Before the session

### T-minus 30 minutes

```bash
scripts/up.sh dev
```

Takes about six minutes. It does not return until three targets are healthy and
`/health` answers over the public URL.

Then confirm everything the demo depends on:

```bash
scripts/status.sh dev
```

Expect: `UP`, 3 instances in service, 3 healthy targets, 0 alarms firing.

### Have open, in this tab order

1. The storefront (`storefront_url` from the up.sh output)
2. `/api/products` on the same host
3. The CloudWatch dashboard (`dashboard_url`)
4. GitHub → the repository, on the Actions tab
5. A terminal in the repo root
6. **`presentation/screenshots/` — the backup, in case any of this fails**

### Copy the URL somewhere you can paste from

The ALB DNS name changes on every rebuild. Do not plan to type it.

```bash
terraform -chdir=terraform/environments/dev output -raw storefront_url
```

---

## Running order

| | Section | Time |
|---|---|---|
| 1 | Introduction | 1:00 |
| 2 | Architecture | 3:00 |
| 3 | **Live demo** | 3:00 |
| 4 | Technical deep dive | 2:00 |
| 5 | Challenges and learning | 1:00 |
| 6 | Results and impact | 1:00 |
| | **Total** | **11:00** |
| 7 | Q&A | 3:00 |

Eleven minutes leaves a minute of slack in a twelve-minute limit. Use it on
questions, not on more content.

---

## 1 · Introduction — 1 minute

> I built a production-shaped AWS platform: multi-AZ, load balanced, monitored,
> secured, deployed through GitOps.
>
> But the requirement that actually shaped it was a cost one. Running this
> continuously is about **seventy-one dollars a month**, and I was not willing
> to pay that for something sitting idle overnight.
>
> So the brief became: build something genuinely production-shaped **that can be
> destroyed and rebuilt in six minutes**. That constraint drove more decisions
> than anything else, and it is the thread through the whole presentation.

Do not list technologies here. The architecture slide does that.

---

## 2 · Architecture — 3 minutes

**Slide: the architecture diagram.** Trace the request path with the cursor
while talking.

> Traffic comes through an Application Load Balancer in public subnets across
> two availability zones. It forwards to an Auto Scaling group of three Graviton
> instances in **private** subnets — those have no route from the internet at
> all.
>
> The catalog lives in DynamoDB, reached through a VPC gateway endpoint. That is
> free, and it means data-tier traffic never traverses the NAT Gateway and never
> touches the internet.

**Slide: three tiers.** This is the part worth slowing down for.

> Each tier is isolated by a different mechanism, and that is deliberate. The
> edge tier by a security group. The application tier by having no inbound route.
> The data tier by **IAM** — the instance role grants five read-only actions on
> exactly one table ARN.
>
> Two details I would point out. The security groups reference **each other**,
> not CIDR ranges — the app accepts traffic from the load balancer's security
> group, which stays correct however the ALB is re-addressed. And the load
> balancer's *egress* is restricted to the app tier, so a compromised load
> balancer cannot reach anything else in the VPC.

If asked about the single NAT Gateway, this is the moment:

> One NAT Gateway in dev, one per AZ in prod. That is a thirty-three dollar
> decision. Losing that AZ costs the other zone its *outbound* connectivity —
> package installs and telemetry — but not its ability to serve requests,
> because inbound comes through a genuinely multi-AZ load balancer and the
> catalog read goes over the gateway endpoint. Degraded operations, not an
> outage. It is written up as an ADR.

---

## 3 · Live demo — 3 minutes

### 3a · The storefront — 40 seconds

Switch to the browser tab. **Reload three or four times** and point at the card.

> This is the storefront. The card shows which instance and which availability
> zone served the request. Watch it as I reload.

The instance ID and AZ change. That is load balancing across AZs, visible
without any tooling.

> Every response also carries this as a header, which is what the automated
> tests assert against.

### 3b · The catalog — 20 seconds

Switch to the `/api/products` tab, reload.

> Six products, read from DynamoDB over the VPC gateway endpoint using the
> instance role. Note `degraded: false` — that field is how the application
> reports data-tier health **without** failing its health check. I will come
> back to why that matters.

### 3c · The dashboard — 40 seconds

Switch to CloudWatch.

> Top row answers *is the service healthy for users*: request rate, latency
> percentiles, target health. The rows below answer *why*: CPU, memory, scaling
> activity, and a live log widget.
>
> The dashed lines are the alarm thresholds, drawn as annotations — so you can
> see how close to the edge it is running without opening the alarm definitions.

### 3d · Kill an instance — 80 seconds

This is the centrepiece. Start it, then talk over it.

```bash
scripts/demo-failover.sh dev --yes
```

> This terminates one instance outright — not a graceful scale-in, an actual
> hard kill, the closest simulation of hardware failure — and probes the
> storefront once a second throughout.

While it runs, keep talking:

> The Auto Scaling group uses **ELB** health checks, not EC2 health checks. EC2
> health only notices an instance the hypervisor thinks is stopped. ELB health
> also catches the far more common case where the instance is running fine and
> the application is wedged.
>
> Watch the healthy target count drop to two and come back to three.

It takes about 100 seconds and ends with the count of failed requests. **Read
that number out honestly, whatever it is** — the deep dive depends on it.

> Two failed requests, and full capacity back in ninety-nine seconds. That
> number is the whole next section.

### 3e · The pipeline — 20 seconds

Switch to the GitHub Actions tab. Show a completed run.

> Every pull request runs format, lint, validate, twenty-six policy unit tests,
> checkov, and then plans both environments and gates each plan against the
> policies. If a policy fails, the merge is blocked.

**If the demo has run long, cut this and mention it in the deep dive instead.**

---

## 4 · Technical deep dive — 2 minutes

**Slide: "I claimed zero downtime. Then I measured it."**

> The first version of my README said this platform self-heals with no user
> impact. Then I wrote that failover script and watched **six requests fail**.
>
> The mechanism is simple in hindsight. A load balancer cannot route away from a
> dead target until its health checks notice. Until then it keeps sending
> traffic there. So the error window is just arithmetic: health check interval
> times unhealthy threshold. Mine was fifteen seconds times three — up to
> forty-five seconds.

**Slide: three measurements.**

> I tuned it and re-measured. Fifteen by three: six failed requests. Ten by two:
> **five**. Five by two, which is the floor the ALB allows: two.
>
> The middle measurement is the one I kept in the write-up, precisely because it
> looks like a failure. Halving the theoretical window removed exactly one
> request. That is what told me the window was an **upper bound**, not a
> prediction — and it is why I pushed all the way to the floor instead of
> stopping at a number that looked reasonable.
>
> Recovery time improved too, from 171 seconds to 99, because detection gates
> replacement.

**Slide: two is not zero.**

> Two is not zero and it cannot be. The load balancer has to *find out*.
>
> So the claim had to get more precise. Zero-downtime **deployment** is real —
> connection draining handles it, and that path was already clean. Zero-downtime
> **instance failure** is not achievable at this layer.
>
> The second version is less impressive. It is also the one that is true, and
> the one that survives someone asking *how do you know*.

---

## 5 · Challenges and learning — 1 minute

Pick **two**. These are the strongest, in order:

> **The alerting architecture was wrong the first time.** I put the SNS topic in
> the monitoring module, which is where it looks like it belongs. Then I tore
> the environment down, brought it back, and found the email subscription
> unconfirmed again. An alert channel that has to be re-armed on every deploy is
> one that gets ignored — which is worse than none, because you think you are
> covered. It moved to the bootstrap layer. The general lesson: things that
> monitor an environment should not share that environment's lifecycle.

> **One scanner finding was actively harmful to fix.** checkov wanted encryption
> on the SNS topic. Enabling it with the AWS-managed key would have **silently
> broken alarm delivery**, because the CloudWatch service principal cannot use
> that key. The scanner goes green while the alerting path goes dark. A control
> that breaks the thing it protects is not a control — so it is documented as an
> accepted risk instead.

---

## 6 · Results and impact — 1 minute

**Slide: cost.**

> Built the obvious way and left running, this architecture is about a hundred
> and twenty-seven dollars a month. As designed, seventy-one. As actually used,
> **thirteen**.
>
> The biggest lever is simply not running it when nobody is using it. The second
> is the shared NAT Gateway.
>
> The thing that genuinely surprised me: NAT plus load balancer is
> **forty-nine dollars**. The three instances doing the actual work are
> **eighteen**. The plumbing costs nearly three times the workload. I would not
> have guessed that.

**Slide: verification.**

> And none of these are claims about what the code should do. Twenty-six policy
> tests, zero checkov failures, eleven application tests, and a failover
> measured three times.

---

## Q&A — likely questions

**"Why not ECS or EKS?"**
> Scope. The Advanced requirements were met without replacing the entire compute
> module, and EC2 with an ASG demonstrates the same networking, scaling and
> health-checking concepts. ADR 0004 records the point at which I would switch:
> when the application outgrows the 16 KB user-data limit.

**"Why DynamoDB for an e-commerce catalog? That is a relational workload."**
> Agreed for a real catalog with orders and inventory. This one is six read-only
> rows, and the constraint was cost while idle — RDS bills twelve dollars a month
> whether or not anything queries it, which for an environment that spends most
> of its life torn down is pure waste. ADR 0003 states plainly what is given up:
> no joins, no transactions, and the app currently `Scan`s, which is wrong at
> any real scale.

**"Is a single NAT Gateway not a single point of failure?"**
> Yes, for outbound traffic in dev. It costs the other AZ its package installs
> and telemetry, not its ability to serve requests — inbound is multi-AZ and the
> catalog read uses a gateway endpoint. Prod sets one per AZ. It is a documented
> trade, not an oversight.

**"Why no HTTPS?"**
> No domain, so no ACM certificate. It is the single largest gap in the posture
> and the root cause of five scanner findings. SECURITY.md documents it, and the
> ALB zone ID is already exported for the Route 53 alias record — it is about
> twelve dollars a year and twenty lines of Terraform.

**"How do you know the instances have no public IP?"**
> A Terratest assertion against the AWS API, not against the Terraform source.
> If someone later attaches one, the test fails.

**"What happens if the region goes down?"**
> Nothing survives it. Single-region by choice. Multi-region done properly means
> solving data replication and DNS failover; done improperly it is a second idle
> stack that doubles the bill and provides false confidence. ARCHITECTURE.md
> states the RTO honestly.

**"Why does the health check not verify DynamoDB?"**
> Because a health check that fails on a shared dependency fails on **every
> instance at once** — it empties the target group and turns a degraded feature
> into a total outage. The blast radius of a deep health check is the whole
> fleet. Catalog health is surfaced as a field and shown on the dashboard
> instead.

**"How is the pipeline authenticated?"**
> OIDC federation. There are no AWS keys in GitHub. Two roles: plan is
> read-only and trusts pull-request tokens; apply trusts only tokens whose
> subject is `refs/heads/main`, so a pull request — including from a fork —
> cannot assume it. The boundary is enforced by STS, not by workflow logic an
> attacker could also edit.

---

## If something goes wrong

**The storefront does not load.** Do not debug on stage. Switch to
`presentation/screenshots/`, say "I have this captured", and carry on. Come back
to it in Q&A if there is time.

**The failover demo hangs.** It has a bounded loop and will exit. Talk over it —
the three measurements are on the slide regardless, and they are the point.

**The dashboard shows no data.** Metrics need a few minutes and some traffic.
Reload the storefront a few times during section 3a; that is partly why it comes
first.

**You are running long at the deep dive.** Cut section 5 to one item. Never cut
the demo — it is worth seven of the twenty-five presentation points.

---

## Afterwards

```bash
scripts/down.sh dev --yes
scripts/status.sh
```

Confirm it reports nothing running. The environment costs about ten cents an
hour, and demo day is exactly the kind of day it gets left on.
