# High availability floor
#
# Encodes the platform's own availability requirements as policy, so they
# cannot be lowered by editing a tfvars file without the change being
# visible and rejected in review.
#
# Without this, "minimum three instances across two availability zones" is a
# sentence in a README that nothing enforces.
package main

import rego.v1

minimum_instances := 3

minimum_availability_zones := 2

deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_autoscaling_group"

	min_size := resource.change.after.min_size
	min_size < minimum_instances

	msg := sprintf(
		"%s sets min_size to %d. The platform requires at least %d instances.",
		[resource.address, min_size, minimum_instances],
	)
}

deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_autoscaling_group"

	subnets := resource.change.after.vpc_zone_identifier
	count(subnets) < minimum_availability_zones
	not is_unknown(resource, "vpc_zone_identifier")

	msg := sprintf(
		"%s spans %d subnet(s). Instances must be spread across at least %d availability zones.",
		[resource.address, count(subnets), minimum_availability_zones],
	)
}

# A target group with no health check cannot notice a wedged process, so the
# load balancer keeps sending traffic to an instance that cannot serve it.
deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_lb_target_group"

	some check in resource.change.after.health_check
	check.enabled == false

	msg := sprintf(
		"%s has health checks disabled, so failed instances stay in rotation.",
		[resource.address],
	)
}

# EC2 health only detects an instance the hypervisor considers stopped. ELB
# health also catches the far more common case: the instance is running but
# the application is not answering.
deny contains msg if {
	some resource in changed_resources
	resource.type == "aws_autoscaling_group"

	resource.change.after.health_check_type == "EC2"

	msg := sprintf(
		"%s uses EC2 health checks. Use ELB health checks so an instance whose application has failed is replaced.",
		[resource.address],
	)
}
