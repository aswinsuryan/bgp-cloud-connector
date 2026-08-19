package azure

import (
	"context"
	"testing"

	"github.com/openshift/bgp-cloud-connector/internal/platform"
)

const testProviderID = "azure:///subscriptions/53b8f551-f0fc-4bea-8cba-6d1fefd54c8a/resourceGroups/amcdermo-rg/providers/Microsoft.Compute/virtualMachines/worker-centralus1-xjf5l"

func TestParseProviderID(t *testing.T) {
	vm, err := ParseProviderID(testProviderID)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if vm.ResourceGroup != "amcdermo-rg" {
		t.Errorf("resource group = %q", vm.ResourceGroup)
	}
	if vm.Name != "worker-centralus1-xjf5l" {
		t.Errorf("name = %q", vm.Name)
	}
	// The ARM ID is what a network interface records, so it must come back
	// without the azure:// scheme the provider ID carries.
	want := "/subscriptions/53b8f551-f0fc-4bea-8cba-6d1fefd54c8a/resourceGroups/amcdermo-rg/providers/Microsoft.Compute/virtualMachines/worker-centralus1-xjf5l"
	if vm.ID != want {
		t.Errorf("ID = %q, want %q", vm.ID, want)
	}

	for _, bad := range []string{
		"gce://openshift-qe/us-east1-b/worker",
		"aws:///us-east-2a/i-0123",
		"azure:///subscriptions/sub/resourceGroups/rg/providers/Microsoft.Compute/disks/d1",
		"",
	} {
		if _, err := ParseProviderID(bad); err == nil {
			t.Errorf("%q was accepted as an Azure VM provider ID", bad)
		}
	}
}

func TestPeeringName_KeyedOnAddressAndWithinLimit(t *testing.T) {
	// Two nodes, and the name follows the address rather than any ordering.
	a := peeringName("cluster", "10.0.128.4")
	b := peeringName("cluster", "10.0.128.5")
	if a == b {
		t.Fatal("two addresses produced the same peering name")
	}
	if a != peeringName("cluster", "10.0.128.4") {
		t.Error("peering name is not stable for the same address")
	}

	long := peeringName("a-very-long-openshift-infrastructure-name-with-a-suffix-abcdefghijkl", "10.128.128.128")
	if len(long) > maxPeeringNameLength {
		t.Errorf("peering name is %d characters, over the %d limit: %q", len(long), maxPeeringNameLength, long)
	}
}

// --- fakes ---

type fakeRS struct {
	current []ObservedPeer
	desired []Peer
}

func (f *fakeRS) ListPeers(_ context.Context) ([]ObservedPeer, error) { return f.current, nil }
func (f *fakeRS) ReconcilePeers(_ context.Context, desired []Peer) (bool, error) {
	f.desired = desired
	return true, nil
}
func (f *fakeRS) DeleteAllPeers(_ context.Context) error { return nil }

var _ Backend = (*fakeRS)(nil)

type fakeNICs struct {
	nics    []NIC
	enabled []string
}

func (f *fakeNICs) ListNICs(_ context.Context, rg string) ([]NIC, error) {
	var out []NIC
	for _, n := range f.nics {
		if n.ResourceGroup == rg {
			out = append(out, n)
		}
	}
	return out, nil
}

func (f *fakeNICs) EnableIPForwarding(_ context.Context, _, name string) error {
	f.enabled = append(f.enabled, name)
	return nil
}

type fakeTopo struct{ t *RouteServerTopology }

func (f *fakeTopo) GetTopology(_ context.Context) (*RouteServerTopology, error) { return f.t, nil }

// TestEnsureNodesCanForward_MatchesOnVMID pins that the interface is found by
// the VM's ARM ID rather than by a name convention, and that an interface
// already forwarding is left alone.
func TestEnsureNodesCanForward_MatchesOnVMID(t *testing.T) {
	vm, err := ParseProviderID(testProviderID)
	if err != nil {
		t.Fatal(err)
	}

	nics := &fakeNICs{nics: []NIC{
		// Named nothing like the node, since the match is on the VM's ARM
		// resource ID and not on any naming convention.
		{Name: "some-other-nic-name", ResourceGroup: "amcdermo-rg", VMID: vm.ID},
		{Name: "already-on", ResourceGroup: "amcdermo-rg", VMID: "/subscriptions/x/other", IPForwarding: true},
	}}
	p := &Platform{cfg: Config{}, nics: nics}

	if err := p.ensureNodesCanForward(context.Background(), []VirtualMachine{vm}); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(nics.enabled) != 1 || nics.enabled[0] != "some-other-nic-name" {
		t.Errorf("enabled %v, want the interface attached to the VM", nics.enabled)
	}
}

// TestEnsureNodesCanForward_NoInterface refuses rather than silently doing
// nothing, since a router node whose interface drops forwarded packets looks
// entirely healthy from the cluster.
func TestEnsureNodesCanForward_NoInterface(t *testing.T) {
	vm, _ := ParseProviderID(testProviderID)
	p := &Platform{cfg: Config{}, nics: &fakeNICs{}}
	if err := p.ensureNodesCanForward(context.Background(), []VirtualMachine{vm}); err == nil {
		t.Error("expected an error when no interface is attached to the VM")
	}
}

// TestDiscoverEndpoints_SingleGroupWithMultihop covers the shape Azure emits:
// one group for the whole vnet, no node selector, and multihop on every
// neighbour because the Route Server is off the node's link.
func TestDiscoverEndpoints_SingleGroupWithMultihop(t *testing.T) {
	p := &Platform{
		cfg:  Config{RouteServerName: "rs"},
		topo: &fakeTopo{t: &RouteServerTopology{ASN: 65515, Addresses: []string{"10.0.1.4", "10.0.1.5"}}},
	}

	result, err := p.DiscoverEndpoints(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(result.PeerGroups) != 1 {
		t.Fatalf("got %d peer groups, want 1", len(result.PeerGroups))
	}
	g := result.PeerGroups[0]
	if g.Key != "rs" {
		t.Errorf("key = %q, want the Route Server name", g.Key)
	}
	if len(g.NodeSelector) != 0 {
		t.Errorf("nodeSelector = %v, want empty so every router node is covered", g.NodeSelector)
	}
	if len(g.Neighbors) != 2 {
		t.Fatalf("got %d neighbours, want 2", len(g.Neighbors))
	}
	for _, n := range g.Neighbors {
		if n.ASN != 65515 {
			t.Errorf("neighbour %s ASN = %d, want 65515", n.Address, n.ASN)
		}
		if !n.EBGPMultiHop {
			t.Errorf("neighbour %s does not ask for multihop", n.Address)
		}
	}
}

// TestDiscoverEndpoints_Refusals covers a Route Server that cannot be peered
// with, rather than emitting a group with nothing in it.
func TestDiscoverEndpoints_Refusals(t *testing.T) {
	for name, topo := range map[string]*RouteServerTopology{
		"no addresses": {ASN: 65515},
		"no ASN":       {Addresses: []string{"10.0.1.4"}},
	} {
		p := &Platform{cfg: Config{RouteServerName: "rs"}, topo: &fakeTopo{t: topo}}
		if _, err := p.DiscoverEndpoints(context.Background()); err == nil {
			t.Errorf("%s: expected a refusal", name)
		}
	}
}

var _ platform.CloudPlatform = (*Platform)(nil)
