//go:build linux

// ==============================================================================
// StormDNS
// Author: nullroute1970
// Github: https://github.com/nullroute1970/StormDNS
// Year: 2026
// ==============================================================================

package netbind

import "syscall"

func controlForInterface(interfaceName string) (func(string, string, syscall.RawConn) error, error) {
	interfaceName = NormalizeInterface(interfaceName)
	if interfaceName == "" {
		return nil, nil
	}

	return func(_, _ string, raw syscall.RawConn) error {
		var controlErr error
		if err := raw.Control(func(fd uintptr) {
			controlErr = syscall.SetsockoptString(int(fd), syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, interfaceName)
		}); err != nil {
			return err
		}
		return controlErr
	}, nil
}
