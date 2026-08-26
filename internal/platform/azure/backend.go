package azure

import "context"

// Peer describes one external BGP peering connection managed by the operator.
type Peer struct {
	Name    string
	PeerIP  string
	PeerASN int64
}

// ObservedPeer extends Peer with remote state returned by the backend.
type ObservedPeer struct {
	Peer
	ProvisioningState string
	PeerBGPState      string
}

// Backend reconciles external BGP peers against a desired set.
type Backend interface {
	ListPeers(ctx context.Context) ([]ObservedPeer, error)
	ReconcilePeers(ctx context.Context, desired []Peer) (changed bool, err error)
	DeleteAllPeers(ctx context.Context) error
}
