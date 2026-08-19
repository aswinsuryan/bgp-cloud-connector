package azure

import (
	"context"
	"fmt"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"

	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/network/armnetwork/v6"
)

// RouteServerTopology is the Route Server's BGP identity and the addresses
// every router node peers with.
//
// Azure models a Route Server as a Virtual Hub, and both of these are read
// from it rather than configured: there is exactly one Route Server per
// virtual network, and Azure fixes the far-side ASN with no flag to change it.
type RouteServerTopology struct {
	ASN       int64
	Addresses []string
}

// NIC is a network interface and whether it forwards packets that are not
// addressed to it.
type NIC struct {
	Name          string
	ResourceGroup string
	// VMID is the ARM resource ID of the VM this interface is attached to,
	// which is how an interface is matched to a router node.
	VMID         string
	IPForwarding bool
}

// TopologyReader reads the Route Server's addresses and ASN.
type TopologyReader interface {
	GetTopology(ctx context.Context) (*RouteServerTopology, error)
}

// NICClient reads and updates network interfaces.
type NICClient interface {
	ListNICs(ctx context.Context, resourceGroup string) ([]NIC, error)
	EnableIPForwarding(ctx context.Context, resourceGroup, name string) error
}

type topologyClient struct {
	hubs            *armnetwork.VirtualHubsClient
	resourceGroup   string
	routeServerName string
}

// NewTopologyReader builds a TopologyReader using the default Azure credential
// chain.
func NewTopologyReader(subscriptionID, resourceGroup, routeServerName string) (TopologyReader, error) {
	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		return nil, fmt.Errorf("azure credential: %w", err)
	}
	factory, err := armnetwork.NewClientFactory(subscriptionID, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("azure network client factory: %w", err)
	}
	return &topologyClient{
		hubs:            factory.NewVirtualHubsClient(),
		resourceGroup:   resourceGroup,
		routeServerName: routeServerName,
	}, nil
}

// GetTopology reads the Route Server's own addresses and ASN.
func (c *topologyClient) GetTopology(ctx context.Context) (*RouteServerTopology, error) {
	resp, err := c.hubs.Get(ctx, c.resourceGroup, c.routeServerName, nil)
	if err != nil {
		return nil, err
	}

	topology := &RouteServerTopology{}
	if resp.Properties == nil {
		return topology, nil
	}
	if resp.Properties.VirtualRouterAsn != nil {
		topology.ASN = *resp.Properties.VirtualRouterAsn
	}
	for _, ip := range resp.Properties.VirtualRouterIPs {
		if ip != nil && *ip != "" {
			topology.Addresses = append(topology.Addresses, *ip)
		}
	}
	return topology, nil
}

type nicClient struct {
	interfaces *armnetwork.InterfacesClient
}

// NewNICClient builds a NICClient.
//
// With no clientID it uses the default credential chain, as the Route Server
// clients do. With one it exchanges the operator's projected service account
// token for that managed identity instead, which is how interfaces in a
// resource group the operator's own identity cannot write to are reached. The
// token file and tenant come from the environment the workload identity
// webhook already populates.
func NewNICClient(subscriptionID, clientID string) (NICClient, error) {
	var (
		cred azcore.TokenCredential
		err  error
	)
	if clientID == "" {
		cred, err = azidentity.NewDefaultAzureCredential(nil)
	} else {
		cred, err = azidentity.NewWorkloadIdentityCredential(&azidentity.WorkloadIdentityCredentialOptions{
			ClientID: clientID,
		})
	}
	if err != nil {
		return nil, fmt.Errorf("azure credential: %w", err)
	}
	factory, err := armnetwork.NewClientFactory(subscriptionID, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("azure network client factory: %w", err)
	}
	return &nicClient{interfaces: factory.NewInterfacesClient()}, nil
}

func (c *nicClient) ListNICs(ctx context.Context, resourceGroup string) ([]NIC, error) {
	var out []NIC
	pager := c.interfaces.NewListPager(resourceGroup, nil)
	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return nil, err
		}
		for _, iface := range page.Value {
			if iface == nil || iface.Name == nil {
				continue
			}
			nic := NIC{Name: *iface.Name, ResourceGroup: resourceGroup}
			if iface.Properties != nil {
				if iface.Properties.VirtualMachine != nil && iface.Properties.VirtualMachine.ID != nil {
					nic.VMID = *iface.Properties.VirtualMachine.ID
				}
				if iface.Properties.EnableIPForwarding != nil {
					nic.IPForwarding = *iface.Properties.EnableIPForwarding
				}
			}
			out = append(out, nic)
		}
	}
	return out, nil
}

// EnableIPForwarding sets the flag that lets a NIC receive packets that are
// not addressed to it, which is what a router node does for pod traffic.
//
// Azure has no call for the single field, so the interface is read and written
// back whole.
func (c *nicClient) EnableIPForwarding(ctx context.Context, resourceGroup, name string) error {
	current, err := c.interfaces.Get(ctx, resourceGroup, name, nil)
	if err != nil {
		return err
	}
	if current.Properties == nil {
		return fmt.Errorf("network interface %q has no properties to update", name)
	}

	enabled := true
	current.Properties.EnableIPForwarding = &enabled

	poller, err := c.interfaces.BeginCreateOrUpdate(ctx, resourceGroup, name, current.Interface, nil)
	if err != nil {
		return err
	}
	_, err = poller.PollUntilDone(ctx, nil)
	return err
}
