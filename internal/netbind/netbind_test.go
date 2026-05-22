// ==============================================================================
// StormDNS
// Author: nullroute1970
// Github: https://github.com/nullroute1970/StormDNS
// Year: 2026
// ==============================================================================

package netbind

import (
	"context"
	"testing"
	"time"
)

func TestListenUDPWithoutInterface(t *testing.T) {
	conn, err := ListenUDP(context.Background(), "udp", "127.0.0.1:0", " ")
	if err != nil {
		t.Fatalf("ListenUDP returned error: %v", err)
	}
	defer conn.Close()
}

func TestDialUDPWithoutInterface(t *testing.T) {
	listener, err := ListenUDP(context.Background(), "udp", "127.0.0.1:0", "")
	if err != nil {
		t.Fatalf("ListenUDP returned error: %v", err)
	}
	defer listener.Close()

	conn, err := DialUDP(context.Background(), listener.LocalAddr().String(), time.Second, "")
	if err != nil {
		t.Fatalf("DialUDP returned error: %v", err)
	}
	defer conn.Close()
}
