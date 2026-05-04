// ==============================================================================
// StormDNS
// Author: nullroute1970
// Github: https://github.com/nullroute1970/StormDNS
// Year: 2026
// ==============================================================================

package udpserver

import (
	"context"
	"errors"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"stormdns-go/internal/config"
	Enums "stormdns-go/internal/enums"
)

func TestSOCKSTargetPolicyBlocksTCP53(t *testing.T) {
	cfg := config.ServerConfig{
		SOCKSBlockPorts: []int{53},
	}

	policy := newSOCKSTargetPolicy(cfg)

	if err := policy.Validate("8.8.8.8", 53); err == nil {
		t.Fatal("expected TCP/53 to be blocked")
	}

	if err := policy.Validate("8.8.8.8", 443); err != nil {
		t.Fatalf("expected TCP/443 to be allowed, got %v", err)
	}
}

func TestSOCKSTargetPolicyAllowPorts(t *testing.T) {
	cfg := config.ServerConfig{
		SOCKSAllowPorts: []int{80, 443},
	}

	policy := newSOCKSTargetPolicy(cfg)

	if err := policy.Validate("1.1.1.1", 443); err != nil {
		t.Fatalf("expected 443 allowed, got %v", err)
	}

	if err := policy.Validate("1.1.1.1", 5222); err == nil {
		t.Fatal("expected 5222 blocked by allowlist")
	}
}

func TestSOCKSTargetPolicyCIDRBlock(t *testing.T) {
	cfg := config.ServerConfig{
		SOCKSBlockCIDRs: []string{"203.0.113.0/24"},
	}

	policy := newSOCKSTargetPolicy(cfg)

	if err := policy.Validate("203.0.113.10", 443); err == nil {
		t.Fatal("expected CIDR target to be blocked")
	}
}

func TestSOCKSBlockedTargetsDoNotDial(t *testing.T) {
	srv := New(config.ServerConfig{
		SOCKSBlockPorts:         []int{53},
		SOCKSConnectConcurrency: 1,
	}, nil, nil)

	var dials atomic.Int32
	srv.dialStreamUpstreamFn = func(network string, address string, timeout time.Duration) (net.Conn, error) {
		dials.Add(1)
		return nil, errors.New("should not dial")
	}

	targets := []string{
		"8.8.8.8",
		"1.1.1.1",
		"2001:4860:4860::8888",
	}

	for _, target := range targets {
		_, err := srv.dialSOCKSStreamTargetContext(context.Background(), target, 53, nil)
		if err == nil {
			t.Fatalf("expected %s:53 to be blocked", target)
		}
		if got := srv.mapSOCKSConnectError(err); got != Enums.PACKET_SOCKS5_RULESET_DENIED {
			t.Fatalf("unexpected packet type for %s: got=%d want=%d", target, got, Enums.PACKET_SOCKS5_RULESET_DENIED)
		}
	}

	if dials.Load() != 0 {
		t.Fatalf("expected no dial, got %d", dials.Load())
	}
}

func TestSOCKSConnectConcurrencyLimitDoesNotDial(t *testing.T) {
	cfg := config.ServerConfig{
		SOCKSConnectConcurrency: 1,
	}

	srv := New(cfg, nil, nil)

	release, ok := srv.tryAcquireSOCKSConnectSlot()
	if !ok {
		t.Fatal("failed to acquire initial slot")
	}
	defer release()

	var dials atomic.Int32
	srv.dialStreamUpstreamFn = func(network string, address string, timeout time.Duration) (net.Conn, error) {
		dials.Add(1)
		return nil, errors.New("should not dial")
	}

	_, err := srv.dialSOCKSStreamTargetContext(context.Background(), "1.1.1.1", 443, nil)
	if err == nil {
		t.Fatal("expected concurrency limit error")
	}

	if got := srv.mapSOCKSConnectError(err); got != Enums.PACKET_SOCKS5_UPSTREAM_UNAVAILABLE {
		t.Fatalf("unexpected packet type: got=%d want=%d", got, Enums.PACKET_SOCKS5_UPSTREAM_UNAVAILABLE)
	}

	if dials.Load() != 0 {
		t.Fatalf("expected no dial, got %d", dials.Load())
	}

	if srv.socksConnectLimited.Load() == 0 {
		t.Fatal("expected socksConnectLimited counter to increment")
	}
}
