package test

import (
	"fmt"
	"strings"
	"testing"

	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestNetworkingModule builds the network foundation for real and asserts the
// properties the rest of the platform depends on.
//
// These are deliberately not assertions about the Terraform source -- `terraform
// validate` already covers that. They are assertions about what AWS actually
// created, which is the only thing that catches a module that plans cleanly and
// produces the wrong topology.
func TestNetworkingModule(t *testing.T) {
	t.Parallel()

	namePrefix := fmt.Sprintf("tt-net-%s", strings.ToLower(random.UniqueId()))

	options := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: "./fixtures/networking",
		Vars: map[string]interface{}{
			"name_prefix":        namePrefix,
			"aws_region":         awsRegion,
			"vpc_cidr":           "10.99.0.0/16",
			"single_nat_gateway": true,
		},
		NoColor: true,
	})

	defer terraform.Destroy(t, options)
	terraform.InitAndApply(t, options)

	t.Run("spans multiple availability zones", func(t *testing.T) {
		zones := terraform.OutputList(t, options, "availability_zones")

		require.Len(t, zones, 2,
			"the platform requires at least two availability zones for high availability")
		assert.NotEqual(t, zones[0], zones[1],
			"both subnets landed in the same AZ, which is not high availability")
	})

	t.Run("creates a public and a private subnet per zone", func(t *testing.T) {
		public := terraform.OutputList(t, options, "public_subnet_ids")
		private := terraform.OutputList(t, options, "private_subnet_ids")

		assert.Len(t, public, 2)
		assert.Len(t, private, 2)

		// A shared subnet would collapse the tier separation entirely.
		for _, publicID := range public {
			assert.NotContains(t, private, publicID,
				"a subnet appears in both the public and private tier")
		}
	})

	t.Run("carves subnets from the VPC CIDR without overlap", func(t *testing.T) {
		assert.Equal(t, "10.99.0.0/16", terraform.Output(t, options, "vpc_cidr_block"))

		publicCIDRs := terraform.OutputList(t, options, "public_subnet_cidrs")
		privateCIDRs := terraform.OutputList(t, options, "private_subnet_cidrs")

		seen := map[string]bool{}
		for _, cidr := range append(publicCIDRs, privateCIDRs...) {
			assert.False(t, seen[cidr], "CIDR %s was allocated twice", cidr)
			seen[cidr] = true
			assert.True(t, strings.HasPrefix(cidr, "10.99."),
				"subnet %s is outside the VPC CIDR", cidr)
		}
	})

	t.Run("shares a single NAT gateway when asked to", func(t *testing.T) {
		gateways := terraform.OutputList(t, options, "nat_gateway_ids")

		// The cost trade-off documented in ADR 0002. If this ever returns two,
		// the dev environment silently started costing ~USD 32/month more.
		assert.Len(t, gateways, 1,
			"single_nat_gateway = true must produce exactly one NAT Gateway")
	})

	t.Run("keeps DynamoDB traffic inside the VPC", func(t *testing.T) {
		endpointID := terraform.Output(t, options, "dynamodb_vpc_endpoint_id")

		assert.NotEmpty(t, endpointID)
		assert.True(t, strings.HasPrefix(endpointID, "vpce-"),
			"expected a VPC endpoint ID, got %q", endpointID)
	})

	t.Run("creates distinct load balancer and application security groups", func(t *testing.T) {
		albSG := terraform.Output(t, options, "alb_security_group_id")
		appSG := terraform.Output(t, options, "app_security_group_id")

		assert.NotEmpty(t, albSG)
		assert.NotEmpty(t, appSG)
		assert.NotEqual(t, albSG, appSG,
			"the tiers share one security group, so the chaining between them is not real")
	})

	t.Run("records flow logs", func(t *testing.T) {
		logGroup := terraform.Output(t, options, "flow_log_group_name")

		assert.Contains(t, logGroup, namePrefix)
		assert.Contains(t, logGroup, "flow-logs")
	})
}
