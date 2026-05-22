//go:build !linux

// ==============================================================================
// StormDNS
// Author: nullroute1970
// Github: https://github.com/nullroute1970/StormDNS
// Year: 2026
// ==============================================================================

package netbind

import (
	"fmt"
	"runtime"
	"syscall"
)

func controlForInterface(interfaceName string) (func(string, string, syscall.RawConn) error, error) {
	interfaceName = NormalizeInterface(interfaceName)
	if interfaceName == "" {
		return nil, nil
	}
	return nil, fmt.Errorf("interface binding is unsupported on %s", runtime.GOOS)
}
