# Network exposure
#
# Constrains what may be reachable from the public internet.
#
# The rules encode the two mistakes that account for most cloud incidents
# involving a compromised host: an administrative port left open to
# 0.0.0.0/0, and a database or application port exposed directly instead of
# sitting behind a load balancer.
package main

import rego.v1

open_to_world := {"0.0.0.0/0", "::/0"}

# Ports that must never accept traffic from the internet. SSH and RDP are the
# classic ones; the rest are datastore ports that are routinely scanned for.
administrative_ports := {
	22, # SSH
	3389, # RDP
	5432, # PostgreSQL
	3306, # MySQL
	6379, # Redis
	27017, # MongoDB
	9200, # Elasticsearch
}

# Ports a public-facing load balancer is legitimately allowed to expose.
public_ingress_allowed_ports := {80, 443}

# --- Modern standalone rule resources ---------------------------------------

deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_vpc_security_group_ingress_rule"

	after := resource.change.after
	after.cidr_ipv4 in open_to_world

	some port in administrative_ports
	port >= after.from_port
	port <= after.to_port

	msg := sprintf(
		"%s exposes administrative port %d to %s. Use SSM Session Manager for operator access instead of opening a port.",
		[resource.address, port, after.cidr_ipv4],
	)
}

deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_vpc_security_group_ingress_rule"

	after := resource.change.after
	after.cidr_ipv4 in open_to_world

	not after.from_port in public_ingress_allowed_ports

	msg := sprintf(
		"%s allows the internet to reach port %d. Only %v may be exposed publicly; everything else belongs behind the load balancer.",
		[resource.address, after.from_port, sort(public_ingress_allowed_ports)],
	)
}

# --- Inline rules on aws_security_group -------------------------------------
#
# The inline form is deprecated in favour of the standalone resources above,
# but a contributor could still reach for it, so the policy covers both rather
# than leaving a gap that depends on which syntax someone happened to use.

deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_security_group"

	some rule in resource.change.after.ingress
	some cidr in rule.cidr_blocks
	cidr in open_to_world

	some port in administrative_ports
	port >= rule.from_port
	port <= rule.to_port

	msg := sprintf(
		"%s has an inline ingress rule exposing administrative port %d to %s.",
		[resource.address, port, cidr],
	)
}

# --- Public IP assignment ---------------------------------------------------

# An application instance with a public IP bypasses the load balancer and the
# NAT Gateway, which defeats the point of having a private tier at all.
deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_subnet"

	resource.change.after.map_public_ip_on_launch == true

	msg := sprintf(
		"%s auto-assigns public IPs on launch. Instances belong in private subnets behind the load balancer.",
		[resource.address],
	)
}

deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_launch_template"

	some interface in resource.change.after.network_interfaces
	interface.associate_public_ip_address == true

	msg := sprintf(
		"%s associates a public IP with its instances, placing the application tier directly on the internet.",
		[resource.address],
	)
}

# --- Load balancer ----------------------------------------------------------

# Malformed headers are the raw material for request smuggling and header
# injection. The ALB can drop them before they ever reach the application.
deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_lb"

	resource.change.after.load_balancer_type == "application"
	resource.change.after.drop_invalid_header_fields == false

	msg := sprintf(
		"%s does not drop invalid header fields, leaving the application exposed to header injection and request smuggling.",
		[resource.address],
	)
}
