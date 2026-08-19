package azure

import (
	"context"
	"fmt"
	"sort"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore/to"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/network/armnetwork/v6"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
)

// RouteServerBackend manages Azure Route Server BGP peerings.
type RouteServerBackend struct {
	ResourceGroup   string
	RouteServerName string
	ListClient      *armnetwork.VirtualHubBgpConnectionsClient
	MutateClient    *armnetwork.VirtualHubBgpConnectionClient
}

type peerKey struct {
	name    string
	peerIP  string
	peerASN int64
}

type peerSet map[peerKey]struct{}

// NewRouteServerBackend builds a backend for a Route Server.
func NewRouteServerBackend(subscriptionID, resourceGroup, routeServerName string) (*RouteServerBackend, error) {
	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		return nil, fmt.Errorf("azure credential: %w", err)
	}
	factory, err := armnetwork.NewClientFactory(subscriptionID, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("azure network client factory: %w", err)
	}
	return &RouteServerBackend{
		ResourceGroup:   resourceGroup,
		RouteServerName: routeServerName,
		ListClient:      factory.NewVirtualHubBgpConnectionsClient(),
		MutateClient:    factory.NewVirtualHubBgpConnectionClient(),
	}, nil
}

// ListPeers returns current BGP connections on the Route Server.
func (b *RouteServerBackend) ListPeers(ctx context.Context) ([]ObservedPeer, error) {
	var out []ObservedPeer
	pager := b.ListClient.NewListPager(b.ResourceGroup, b.RouteServerName, nil)
	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("list route server peerings: %w", err)
		}
		for _, conn := range page.Value {
			if conn == nil || conn.Name == nil {
				continue
			}
			peer := ObservedPeer{
				Peer: Peer{
					Name: *conn.Name,
				},
			}
			if conn.Properties != nil {
				if conn.Properties.PeerIP != nil {
					peer.PeerIP = *conn.Properties.PeerIP
				}
				if conn.Properties.PeerAsn != nil {
					peer.PeerASN = *conn.Properties.PeerAsn
				}
				if conn.Properties.ProvisioningState != nil {
					peer.ProvisioningState = string(*conn.Properties.ProvisioningState)
				}
				if conn.Properties.ConnectionState != nil {
					peer.PeerBGPState = string(*conn.Properties.ConnectionState)
				}
			}
			out = append(out, peer)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// ReconcilePeers creates, updates, or deletes peerings to match desired.
func (b *RouteServerBackend) ReconcilePeers(ctx context.Context, desired []Peer) (bool, error) {
	log := logf.FromContext(ctx)

	current, err := b.ListPeers(ctx)
	if err != nil {
		return false, err
	}

	desiredSorted := append([]Peer(nil), desired...)
	sort.Slice(desiredSorted, func(i, j int) bool { return desiredSorted[i].Name < desiredSorted[j].Name })

	if buildPeerSet(current).Equal(buildDesiredSet(desiredSorted)) {
		return false, nil
	}

	log.Info("reconciling Azure Route Server BGP peerings",
		"resourceGroup", b.ResourceGroup,
		"routeServer", b.RouteServerName,
		"currentPeerCount", len(current),
		"desiredPeerCount", len(desiredSorted),
	)

	desiredByName := make(map[string]Peer, len(desiredSorted))
	for _, p := range desiredSorted {
		desiredByName[p.Name] = p
	}

	changed := false
	for name, want := range desiredByName {
		cur, ok := findCurrent(current, name)
		if !ok || cur.PeerIP != want.PeerIP || cur.PeerASN != want.PeerASN {
			if err := b.createOrUpdate(ctx, want); err != nil {
				return changed, err
			}
			changed = true
		}
	}

	for _, cur := range current {
		if _, keep := desiredByName[cur.Name]; keep {
			continue
		}
		if err := b.delete(ctx, cur.Name); err != nil {
			return changed, err
		}
		changed = true
	}

	return changed, nil
}

// DeleteAllPeers removes all BGP connections on the Route Server.
func (b *RouteServerBackend) DeleteAllPeers(ctx context.Context) error {
	log := logf.FromContext(ctx)

	current, err := b.ListPeers(ctx)
	if err != nil {
		return err
	}
	if len(current) == 0 {
		return nil
	}
	log.Info("deleting all Azure Route Server BGP peerings",
		"resourceGroup", b.ResourceGroup,
		"routeServer", b.RouteServerName,
		"peerCount", len(current),
	)
	for _, p := range current {
		if err := b.delete(ctx, p.Name); err != nil {
			return err
		}
	}
	return nil
}

func (b *RouteServerBackend) createOrUpdate(ctx context.Context, peer Peer) error {
	log := logf.FromContext(ctx)
	log.Info("calling Azure API to create or update Route Server BGP peering",
		"resourceGroup", b.ResourceGroup,
		"routeServer", b.RouteServerName,
		"peeringName", peer.Name,
		"peerIP", peer.PeerIP,
		"peerASN", peer.PeerASN,
	)
	params := armnetwork.BgpConnection{
		Properties: &armnetwork.BgpConnectionProperties{
			PeerAsn: to.Ptr(peer.PeerASN),
			PeerIP:  to.Ptr(peer.PeerIP),
		},
	}
	poller, err := b.MutateClient.BeginCreateOrUpdate(ctx, b.ResourceGroup, b.RouteServerName, peer.Name, params, nil)
	if err != nil {
		return fmt.Errorf("create/update peering %q: %w", peer.Name, err)
	}
	if _, err := poller.PollUntilDone(ctx, nil); err != nil {
		return fmt.Errorf("wait for peering %q: %w", peer.Name, err)
	}
	log.Info("Azure Route Server BGP peering create or update completed",
		"resourceGroup", b.ResourceGroup,
		"routeServer", b.RouteServerName,
		"peeringName", peer.Name,
		"peerIP", peer.PeerIP,
		"peerASN", peer.PeerASN,
	)
	return nil
}

func (b *RouteServerBackend) delete(ctx context.Context, name string) error {
	log := logf.FromContext(ctx)
	log.Info("calling Azure API to delete Route Server BGP peering",
		"resourceGroup", b.ResourceGroup,
		"routeServer", b.RouteServerName,
		"peeringName", name,
	)
	poller, err := b.MutateClient.BeginDelete(ctx, b.ResourceGroup, b.RouteServerName, name, nil)
	if err != nil {
		return fmt.Errorf("delete peering %q: %w", name, err)
	}
	if _, err := poller.PollUntilDone(ctx, nil); err != nil {
		return fmt.Errorf("wait for delete peering %q: %w", name, err)
	}
	log.Info("Azure Route Server BGP peering delete completed",
		"resourceGroup", b.ResourceGroup,
		"routeServer", b.RouteServerName,
		"peeringName", name,
	)
	return nil
}

func findCurrent(current []ObservedPeer, name string) (ObservedPeer, bool) {
	for _, p := range current {
		if p.Name == name {
			return p, true
		}
	}
	return ObservedPeer{}, false
}

func buildDesiredSet(peers []Peer) peerSet {
	s := make(peerSet, len(peers))
	for _, p := range peers {
		s[peerKey{p.Name, p.PeerIP, p.PeerASN}] = struct{}{}
	}
	return s
}

func buildPeerSet(peers []ObservedPeer) peerSet {
	s := make(peerSet, len(peers))
	for _, p := range peers {
		s[peerKey{p.Name, p.PeerIP, p.PeerASN}] = struct{}{}
	}
	return s
}

func (s peerSet) Equal(other peerSet) bool {
	if len(s) != len(other) {
		return false
	}
	for k := range s {
		if _, ok := other[k]; !ok {
			return false
		}
	}
	return true
}
