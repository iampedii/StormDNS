// ==============================================================================
// StormDNS
// Author: nullroute1970
// Github: https://github.com/nullroute1970/StormDNS
// Year: 2026
// ==============================================================================

package netbind

import (
	"context"
	"fmt"
	"net"
	"strings"
	"time"
)

// NormalizeInterface trims an optional interface name from config/flags.
func NormalizeInterface(name string) string {
	return strings.TrimSpace(name)
}

// ListenUDP opens a UDP listener, optionally pinned to a network interface.
func ListenUDP(ctx context.Context, network string, address string, interfaceName string) (*net.UDPConn, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	lc, err := listenConfig(interfaceName)
	if err != nil {
		return nil, err
	}
	packetConn, err := lc.ListenPacket(ctx, network, address)
	if err != nil {
		return nil, err
	}
	conn, ok := packetConn.(*net.UDPConn)
	if !ok {
		_ = packetConn.Close()
		return nil, fmt.Errorf("listener for %s returned %T, not *net.UDPConn", network, packetConn)
	}
	return conn, nil
}

// DialContext opens an outbound connection, optionally pinned to a network
// interface. The interface binding is applied to the socket itself.
func DialContext(ctx context.Context, network string, address string, timeout time.Duration, interfaceName string) (net.Conn, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	dialer, err := dialer(timeout, interfaceName)
	if err != nil {
		return nil, err
	}
	return dialer.DialContext(ctx, network, address)
}

// DialUDP opens a connected UDP socket, optionally pinned to a network interface.
func DialUDP(ctx context.Context, address string, timeout time.Duration, interfaceName string) (*net.UDPConn, error) {
	conn, err := DialContext(ctx, "udp", address, timeout, interfaceName)
	if err != nil {
		return nil, err
	}
	udpConn, ok := conn.(*net.UDPConn)
	if !ok {
		_ = conn.Close()
		return nil, fmt.Errorf("dial udp returned %T, not *net.UDPConn", conn)
	}
	return udpConn, nil
}

func listenConfig(interfaceName string) (net.ListenConfig, error) {
	control, err := controlForInterface(interfaceName)
	if err != nil {
		return net.ListenConfig{}, err
	}
	return net.ListenConfig{Control: control}, nil
}

func dialer(timeout time.Duration, interfaceName string) (net.Dialer, error) {
	control, err := controlForInterface(interfaceName)
	if err != nil {
		return net.Dialer{}, err
	}
	return net.Dialer{Timeout: timeout, Control: control}, nil
}
