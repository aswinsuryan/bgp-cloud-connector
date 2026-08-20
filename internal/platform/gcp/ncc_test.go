package gcp

import (
	"testing"

	"google.golang.org/api/networkconnectivity/v1"
)

func spokeWith(siteToSite bool, instances ...*networkconnectivity.RouterApplianceInstance) *networkconnectivity.Spoke {
	return &networkconnectivity.Spoke{
		LinkedRouterApplianceInstances: &networkconnectivity.LinkedRouterApplianceInstances{
			SiteToSiteDataTransfer: siteToSite,
			Instances:              instances,
		},
	}
}

func appliance(name, ip string) *networkconnectivity.RouterApplianceInstance {
	return &networkconnectivity.RouterApplianceInstance{
		VirtualMachine: SelfLink("proj", "us-east1-b", name),
		IpAddress:      ip,
	}
}

func routerNode(name, ip string) RouterNode {
	return RouterNode{
		Name:      name,
		SelfLink:  SelfLink("proj", "us-east1-b", name),
		Zone:      "us-east1-b",
		IPAddress: ip,
	}
}

// TestSpokeMatches covers the three things a spoke carries. Comparing only the
// instance self links leaves the other two unchecked, so a node keeping its
// instance while changing address, or siteToSiteDataTransfer being flipped in
// the spec, reads as nothing to do and no patch is ever sent.
func TestSpokeMatches(t *testing.T) {
	for _, tc := range []struct {
		name       string
		spoke      *networkconnectivity.Spoke
		nodes      []RouterNode
		siteToSite bool
		want       bool
	}{
		{
			name:  "identical",
			spoke: spokeWith(false, appliance("worker-a", "10.0.1.4")),
			nodes: []RouterNode{routerNode("worker-a", "10.0.1.4")},
			want:  true,
		},
		{
			name:  "a node joins",
			spoke: spokeWith(false, appliance("worker-a", "10.0.1.4")),
			nodes: []RouterNode{routerNode("worker-a", "10.0.1.4"), routerNode("worker-b", "10.0.1.5")},
			want:  false,
		},
		{
			name:  "a node leaves",
			spoke: spokeWith(false, appliance("worker-a", "10.0.1.4"), appliance("worker-b", "10.0.1.5")),
			nodes: []RouterNode{routerNode("worker-a", "10.0.1.4")},
			want:  false,
		},
		{
			name:  "a node keeps its instance and changes address",
			spoke: spokeWith(false, appliance("worker-a", "10.0.1.4")),
			nodes: []RouterNode{routerNode("worker-a", "10.0.1.9")},
			want:  false,
		},
		{
			name:       "site-to-site is turned on in the spec",
			spoke:      spokeWith(false, appliance("worker-a", "10.0.1.4")),
			nodes:      []RouterNode{routerNode("worker-a", "10.0.1.4")},
			siteToSite: true,
			want:       false,
		},
		{
			name:       "site-to-site is turned off in the spec",
			spoke:      spokeWith(true, appliance("worker-a", "10.0.1.4")),
			nodes:      []RouterNode{routerNode("worker-a", "10.0.1.4")},
			siteToSite: false,
			want:       false,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := spokeMatches(tc.spoke, tc.nodes, tc.siteToSite); got != tc.want {
				t.Errorf("spokeMatches = %v, want %v", got, tc.want)
			}
		})
	}
}
