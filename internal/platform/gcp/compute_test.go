package gcp

import (
	"testing"

	"google.golang.org/api/compute/v1"
)

func nodes(ips ...string) []RouterNode {
	out := make([]RouterNode, 0, len(ips))
	for i, ip := range ips {
		out = append(out, RouterNode{
			Name:      string(rune('a'+i)) + "-worker",
			IPAddress: ip,
			SelfLink:  SelfLink("proj", "us-east1-b", string(rune('a'+i))+"-worker"),
		})
	}
	return out
}

func topology() *CloudRouterTopology {
	return &CloudRouterTopology{
		CloudRouterASN: 65000,
		InterfaceNames: []string{"if0", "if1"},
		InterfaceIPs:   []string{"10.0.0.2", "10.0.0.3"},
	}
}

func namesByPeerIP(peers []*compute.RouterBgpPeer) map[string][]string {
	out := map[string][]string{}
	for _, p := range peers {
		out[p.PeerIpAddress] = append(out[p.PeerIpAddress], p.Name)
	}
	return out
}

// TestDesiredPeers_NamesSurviveNodeRemoval pins that a node leaving does not
// rename the peers of the nodes that stay.
//
// A Cloud Router patch replaces the whole peer list, so a rename is a delete
// and a create: a name that moved with the node set would tear down and
// re-establish the BGP session of every surviving node.
func TestDesiredPeers_NamesSurviveNodeRemoval(t *testing.T) {
	before := namesByPeerIP(desiredPeers("cluster", nodes("10.0.1.4", "10.0.1.5", "10.0.1.6"), topology(), 65001))
	after := namesByPeerIP(desiredPeers("cluster", nodes("10.0.1.5", "10.0.1.6"), topology(), 65001))

	for _, ip := range []string{"10.0.1.5", "10.0.1.6"} {
		if len(after[ip]) != len(before[ip]) {
			t.Fatalf("%s: got %d peers, want %d", ip, len(after[ip]), len(before[ip]))
		}
		for i := range before[ip] {
			if before[ip][i] != after[ip][i] {
				t.Errorf("%s peer %d renamed by an unrelated node leaving: %q -> %q",
					ip, i, before[ip][i], after[ip][i])
			}
		}
	}
}

// TestMergePeers_LeavesOtherClustersAlone covers a Cloud Router shared between
// clusters. Routers.Patch uses JSON merge patch, so the peer array is replaced
// wholesale and anything left out of the list is deleted.
func TestMergePeers_LeavesOtherClustersAlone(t *testing.T) {
	foreign := []*compute.RouterBgpPeer{
		{Name: "other-bgp-10-9-9-9-0", PeerIpAddress: "10.9.9.9"},
		{Name: "hand-made-peer", PeerIpAddress: "10.9.9.10"},
	}
	ours := desiredPeers("cluster", nodes("10.0.1.4"), topology(), 65001)

	merged := mergePeers(append(append([]*compute.RouterBgpPeer{}, foreign...), ours...), ours, "cluster")

	for _, want := range foreign {
		found := false
		for _, p := range merged {
			if p.Name == want.Name {
				found = true
			}
		}
		if !found {
			t.Errorf("peer %q belongs to another cluster and was dropped", want.Name)
		}
	}
	if len(merged) != len(foreign)+len(ours) {
		t.Errorf("merged %d peers, want %d", len(merged), len(foreign)+len(ours))
	}
}

// TestIsOurPeer_DoesNotClaimALongerClusterName pins the separator: without it
// "cluster" would own the peers of "cluster-two".
func TestIsOurPeer_DoesNotClaimALongerClusterName(t *testing.T) {
	name := PeerName("cluster-two", "10.0.1.4", 0)
	if isOurPeer(name, "cluster") {
		t.Errorf("%q was claimed by cluster %q", name, "cluster")
	}
	if !isOurPeer(name, "cluster-two") {
		t.Errorf("%q was not claimed by its own cluster", name)
	}
}

// TestPeerName_WithinGCELimit covers a long infrastructure name, which is
// where the 63 character limit bites.
func TestPeerName_WithinGCELimit(t *testing.T) {
	name := PeerName("a-very-long-openshift-infrastructure-name-with-suffix-abcde", "10.128.128.128", 1)
	if len(name) > maxPeerNameLength {
		t.Errorf("peer name is %d characters, over the %d limit: %q", len(name), maxPeerNameLength, name)
	}
}
