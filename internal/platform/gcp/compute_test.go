package gcp

import (
	"regexp"
	"strings"
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
//
// Fitting the limit is only half of it. Whatever the name gives up to fit, it
// has to stay recognisable to isOurPeer, or the cluster stops recognising its
// own peers: mergePeers holds on to them as another cluster's and Cleanup
// leaves them on the router.
func TestPeerName_WithinGCELimit(t *testing.T) {
	const cluster = "a-very-long-openshift-infrastructure-name-with-suffix-abcde"

	name := PeerName(cluster, "10.128.128.128", 1)
	if len(name) > maxPeerNameLength {
		t.Errorf("peer name is %d characters, over the %d limit: %q", len(name), maxPeerNameLength, name)
	}
	if !isOurPeer(name, cluster) {
		t.Errorf("%q is not recognised as belonging to the cluster that built it", name)
	}
}

// TestPeerName_AbbreviatedPrefixesDoNotCollide covers two clusters whose names
// are too long to carry whole and share everything but their ending.
//
// Abbreviating by cutting would give both the same prefix, and the prefix is
// the only ownership marker a Cloud Router peer can carry, so each cluster
// would treat the other's peers as its own and delete them.
func TestPeerName_AbbreviatedPrefixesDoNotCollide(t *testing.T) {
	shared := strings.Repeat("x", 50)
	alpha, beta := shared+"-alpha", shared+"-beta"

	name := PeerName(alpha, "10.0.1.4", 0)
	if !isOurPeer(name, alpha) {
		t.Errorf("%q is not recognised by the cluster that built it", name)
	}
	if isOurPeer(name, beta) {
		t.Errorf("%q built for %q was claimed by %q", name, alpha, beta)
	}
}

// TestBuildPeerSet_SeesInterfaceDrift covers a Cloud Router interface being
// rebuilt under a peer that keeps its name.
//
// The name is keyed on the node address and the interface index, so renaming
// or re-addressing an interface leaves every name unchanged. If the comparison
// key does not carry what the interface contributes, the desired set equals the
// current one, no patch is sent, and the peer keeps pointing at an interface
// that is gone.
func TestBuildPeerSet_SeesInterfaceDrift(t *testing.T) {
	n := nodes("10.0.1.4")

	before := desiredPeers("cluster", n, topology(), 65001)
	rebuilt := &CloudRouterTopology{
		CloudRouterASN: 65000,
		InterfaceNames: []string{"if0-rebuilt", "if1-rebuilt"},
		InterfaceIPs:   []string{"10.0.0.8", "10.0.0.9"},
	}
	after := desiredPeers("cluster", n, rebuilt, 65001)

	if before[0].Name != after[0].Name {
		t.Fatalf("peer names differ (%q vs %q); this test is meaningless unless they match",
			before[0].Name, after[0].Name)
	}
	if buildPeerSet(before).Equal(buildPeerSet(after)) {
		t.Errorf("peer sets compare equal across an interface rebuild, so no patch would be sent:\n"+
			" before: interface %q at %q\n after:  interface %q at %q",
			before[0].InterfaceName, before[0].IpAddress, after[0].InterfaceName, after[0].IpAddress)
	}
}

// TestBuildPeerSet_SeesApplianceDrift covers a node keeping its address while
// its instance is replaced, which reissues the self link the peer names.
func TestBuildPeerSet_SeesApplianceDrift(t *testing.T) {
	before := desiredPeers("cluster", nodes("10.0.1.4"), topology(), 65001)

	replaced := []RouterNode{{
		Name:      "a-worker",
		IPAddress: "10.0.1.4",
		SelfLink:  SelfLink("proj", "us-east1-b", "a-worker-rebuilt"),
	}}
	after := desiredPeers("cluster", replaced, topology(), 65001)

	if buildPeerSet(before).Equal(buildPeerSet(after)) {
		t.Errorf("peer sets compare equal across an instance replacement, so no patch would be sent:\n"+
			" before: %q\n after:  %q", before[0].RouterApplianceInstance, after[0].RouterApplianceInstance)
	}
}

// TestPeerName_IsAValidGCEName covers a dual-stack node, whose first internal
// address the controller reports may be IPv6.
//
// A GCE resource name accepts lowercase letters, digits and dashes, and must
// start with a letter. An address carries separators that are none of those,
// so a name built by substituting only the IPv4 dot is rejected by the API and
// no peer is created at all.
func TestPeerName_IsAValidGCEName(t *testing.T) {
	valid := regexp.MustCompile(`^[a-z]([-a-z0-9]*[a-z0-9])?$`)

	for _, address := range []string{
		"10.0.128.2",
		"2a00:8a00:4000:780::4",
		"fd01:0:0:1::4",
		"2001:DB8:85A3:8D3:1319:8A2E:370:7348",
	} {
		name := PeerName("cluster-abcde", address, 0)
		if !valid.MatchString(name) {
			t.Errorf("peer name for %q is not a valid GCE name: %q", address, name)
		}
		if len(name) > maxPeerNameLength {
			t.Errorf("peer name for %q is %d characters, over the %d limit: %q",
				address, len(name), maxPeerNameLength, name)
		}
	}
}

// TestPeerName_DistinguishesAddresses guards the substitution from mapping two
// different node addresses onto one name, which would leave the second node
// without a peer of its own.
func TestPeerName_DistinguishesAddresses(t *testing.T) {
	seen := map[string]string{}
	for _, address := range []string{
		"10.0.128.2", "10.0.128.3",
		"fd01:0:0:1::4", "fd01:0:0:1::5", "fd01:0:0:2::4",
	} {
		name := PeerName("cluster-abcde", address, 0)
		if other, dup := seen[name]; dup {
			t.Errorf("%q and %q both produce peer name %q", other, address, name)
		}
		seen[name] = address
	}
}
