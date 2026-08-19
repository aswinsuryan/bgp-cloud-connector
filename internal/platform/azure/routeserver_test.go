package azure

import (
	"testing"
)

func TestPeerSetEqual(t *testing.T) {
	left := buildDesiredSet([]Peer{
		{Name: "node-a", PeerIP: "10.0.0.1", PeerASN: 65001},
	})
	right := buildPeerSet([]ObservedPeer{
		{Peer: Peer{Name: "node-a", PeerIP: "10.0.0.1", PeerASN: 65001}},
	})
	if !left.Equal(right) {
		t.Fatal("expected peer sets to be equal")
	}

	changed := buildDesiredSet([]Peer{
		{Name: "node-a", PeerIP: "10.0.0.2", PeerASN: 65001},
	})
	if left.Equal(changed) {
		t.Fatal("expected peer sets to differ when IP changes")
	}
}

func TestFindCurrent(t *testing.T) {
	current := []ObservedPeer{
		{Peer: Peer{Name: "node-a", PeerIP: "10.0.0.1", PeerASN: 65001}},
	}
	if _, ok := findCurrent(current, "node-b"); ok {
		t.Fatal("expected node-b to be missing")
	}
	got, ok := findCurrent(current, "node-a")
	if !ok || got.PeerIP != "10.0.0.1" {
		t.Fatalf("unexpected peer: %+v ok=%v", got, ok)
	}
}
