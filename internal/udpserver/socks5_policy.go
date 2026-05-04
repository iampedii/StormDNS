// ==============================================================================
// StormDNS
// Author: nullroute1970
// Github: https://github.com/nullroute1970/StormDNS
// Year: 2026
// ==============================================================================

package udpserver

import (
	"net"
	"strconv"
	"strings"

	"stormdns-go/internal/config"
)

type socksTargetPolicy struct {
	allowPorts map[uint16]struct{}
	blockPorts map[uint16]struct{}
	blockHosts map[string]struct{}
	blockCIDRs []*net.IPNet
}

func newSOCKSTargetPolicy(cfg config.ServerConfig) socksTargetPolicy {
	p := socksTargetPolicy{
		allowPorts: make(map[uint16]struct{}, len(cfg.SOCKSAllowPorts)),
		blockPorts: make(map[uint16]struct{}, len(cfg.SOCKSBlockPorts)),
		blockHosts: make(map[string]struct{}, len(cfg.SOCKSBlockHosts)),
		blockCIDRs: make([]*net.IPNet, 0, len(cfg.SOCKSBlockCIDRs)),
	}

	for _, port := range cfg.SOCKSAllowPorts {
		if port >= 1 && port <= 65535 {
			p.allowPorts[uint16(port)] = struct{}{}
		}
	}

	for _, port := range cfg.SOCKSBlockPorts {
		if port >= 1 && port <= 65535 {
			p.blockPorts[uint16(port)] = struct{}{}
		}
	}

	for _, host := range cfg.SOCKSBlockHosts {
		normalized := strings.ToLower(strings.TrimSpace(host))
		if normalized != "" {
			p.blockHosts[normalized] = struct{}{}
		}
	}

	for _, cidr := range cfg.SOCKSBlockCIDRs {
		_, network, err := net.ParseCIDR(strings.TrimSpace(cidr))
		if err == nil && network != nil {
			p.blockCIDRs = append(p.blockCIDRs, network)
		}
	}

	return p
}

func (p socksTargetPolicy) Validate(host string, port uint16) error {
	if err := validateSOCKSTargetHost(host); err != nil {
		return err
	}

	hostPort := net.JoinHostPort(host, strconv.Itoa(int(port)))

	if _, blocked := p.blockPorts[port]; blocked {
		return &blockedSOCKSTargetError{host: hostPort}
	}

	if len(p.allowPorts) > 0 {
		if _, allowed := p.allowPorts[port]; !allowed {
			return &blockedSOCKSTargetError{host: hostPort}
		}
	}

	normalizedHost := strings.ToLower(strings.TrimSpace(host))
	if normalizedHost != "" {
		if _, blocked := p.blockHosts[normalizedHost]; blocked {
			return &blockedSOCKSTargetError{host: hostPort}
		}
	}

	ip := net.ParseIP(strings.TrimSpace(host))
	if ip != nil {
		for _, network := range p.blockCIDRs {
			if network.Contains(ip) {
				return &blockedSOCKSTargetError{host: hostPort}
			}
		}
	}

	return nil
}
