package test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/aws"
	http_helper "github.com/gruntwork-io/terratest/modules/http-helper"
	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/retry"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const awsRegion = "us-east-1"

// healthResponse mirrors the payload the application serves at /health.
type healthResponse struct {
	Status           string `json:"status"`
	InstanceID       string `json:"instanceId"`
	AvailabilityZone string `json:"availabilityZone"`
	Environment      string `json:"environment"`
	Catalog          struct {
		ProductCount int  `json:"productCount"`
		Degraded     bool `json:"degraded"`
	} `json:"catalog"`
}

type productsResponse struct {
	Count            int    `json:"count"`
	ServedBy         string `json:"servedBy"`
	AvailabilityZone string `json:"availabilityZone"`
	Degraded         bool   `json:"degraded"`
	Products         []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	} `json:"products"`
}

// TestPlatformEndToEnd stands up the whole stack and verifies the properties
// that matter to a user of the storefront, from outside the VPC.
//
// It is the slowest test in the suite -- roughly fifteen minutes including
// teardown -- and it is the only one that proves the three modules actually
// work together. Everything else could pass while the load balancer quietly
// sends traffic to an empty target group.
func TestPlatformEndToEnd(t *testing.T) {
	t.Parallel()

	namePrefix := fmt.Sprintf("tt-plat-%s", strings.ToLower(random.UniqueId()))

	options := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: "./fixtures/platform",
		Vars: map[string]interface{}{
			"name_prefix": namePrefix,
			"aws_region":  awsRegion,
			"vpc_cidr":    "10.98.0.0/16",
		},
		NoColor: true,
	})

	defer terraform.Destroy(t, options)
	terraform.InitAndApply(t, options)

	storefrontURL := terraform.Output(t, options, "storefront_url")
	require.NotEmpty(t, storefrontURL)

	t.Run("serves health checks through the load balancer", func(t *testing.T) {
		body := getWithRetry(t, storefrontURL+"/health")

		var health healthResponse
		require.NoError(t, json.Unmarshal([]byte(body), &health))

		assert.Equal(t, "healthy", health.Status)
		assert.Equal(t, "test", health.Environment)
		assert.True(t, strings.HasPrefix(health.InstanceID, "i-"),
			"expected a real EC2 instance ID, got %q -- the app may not be reading IMDS",
			health.InstanceID)
	})

	t.Run("runs the required three instances", func(t *testing.T) {
		asgName := terraform.Output(t, options, "autoscaling_group_name")
		instanceIDs := aws.GetInstanceIdsForAsg(t, asgName, awsRegion)

		assert.GreaterOrEqual(t, len(instanceIDs), 3,
			"the project requires a minimum of three application instances")
	})

	// The core high-availability claim. Requests are sampled until both zones
	// have answered, which proves traffic genuinely crosses AZs rather than the
	// fleet merely being configured to span them.
	t.Run("distributes requests across availability zones", func(t *testing.T) {
		zones := map[string]bool{}
		instances := map[string]bool{}

		for attempt := 0; attempt < 30; attempt++ {
			body := getWithRetry(t, storefrontURL+"/health")

			var health healthResponse
			if err := json.Unmarshal([]byte(body), &health); err != nil {
				continue
			}

			zones[health.AvailabilityZone] = true
			instances[health.InstanceID] = true

			if len(zones) >= 2 && len(instances) >= 2 {
				break
			}
			time.Sleep(1 * time.Second)
		}

		assert.GreaterOrEqual(t, len(zones), 2,
			"every request was served from one AZ (%v); the load balancer is not spreading traffic across zones", zones)
		assert.GreaterOrEqual(t, len(instances), 2,
			"only %d distinct instance(s) answered; requests are not being balanced", len(instances))
	})

	// Proves the application tier can reach DynamoDB over the gateway endpoint
	// using its instance role -- the whole data path, with no credentials
	// anywhere in the application.
	t.Run("reads the catalog from DynamoDB", func(t *testing.T) {
		body := getWithRetry(t, storefrontURL+"/api/products")

		var products productsResponse
		require.NoError(t, json.Unmarshal([]byte(body), &products))

		assert.False(t, products.Degraded,
			"the catalog is degraded, so the application could not reach DynamoDB")
		assert.Equal(t, 6, products.Count, "expected the six seeded catalog rows")
		require.NotEmpty(t, products.Products)
		assert.NotEmpty(t, products.Products[0].Name)
	})

	t.Run("sends security headers", func(t *testing.T) {
		response, err := http.Get(storefrontURL)
		require.NoError(t, err)
		defer response.Body.Close()

		assert.Equal(t, 200, response.StatusCode)
		assert.Equal(t, "nosniff", response.Header.Get("X-Content-Type-Options"))
		assert.Equal(t, "DENY", response.Header.Get("X-Frame-Options"))
		assert.NotEmpty(t, response.Header.Get("Content-Security-Policy"))

		// These headers are what makes load balancing visible during the demo,
		// so they are part of the contract rather than incidental.
		assert.NotEmpty(t, response.Header.Get("X-Instance-Id"))
		assert.NotEmpty(t, response.Header.Get("X-Availability-Zone"))
	})

	// The tier separation claim, verified against AWS rather than against the
	// Terraform source. An instance with a public IP would be reachable without
	// passing the load balancer, which would make the private tier decorative.
	t.Run("keeps application instances off the public internet", func(t *testing.T) {
		asgName := terraform.Output(t, options, "autoscaling_group_name")
		instanceIDs := aws.GetInstanceIdsForAsg(t, asgName, awsRegion)
		require.NotEmpty(t, instanceIDs)

		publicIPs := aws.GetPublicIpsOfEc2Instances(t, instanceIDs, awsRegion)

		for instanceID, publicIP := range publicIPs {
			assert.Empty(t, publicIP,
				"instance %s has public IP %q and is therefore reachable without the load balancer",
				instanceID, publicIP)
		}
	})

	t.Run("returns 404 for unknown paths", func(t *testing.T) {
		statusCode, _ := http_helper.HttpGet(t, storefrontURL+"/does-not-exist", nil)
		assert.Equal(t, 404, statusCode)
	})
}

// getWithRetry polls an endpoint until it answers 200.
//
// Instances take a couple of minutes to bootstrap and pass two consecutive
// health checks, and the ALB DNS name needs a moment to resolve, so a bare GET
// immediately after apply is genuinely flaky rather than genuinely failing.
func getWithRetry(t *testing.T, url string) string {
	return retry.DoWithRetry(t, fmt.Sprintf("GET %s", url), 30, 10*time.Second,
		func() (string, error) {
			statusCode, body, err := http_helper.HttpGetE(t, url, nil)
			if err != nil {
				return "", err
			}
			if statusCode != 200 {
				return "", fmt.Errorf("got status %d from %s", statusCode, url)
			}
			return body, nil
		})
}
