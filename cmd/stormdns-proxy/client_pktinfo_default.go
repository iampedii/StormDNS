//go:build !linux

package main

import "net"

func enableDestinationPacketInfo(conn *net.UDPConn) error {
	return nil
}

func packetInfoOOBSize() int {
	return 0
}

func readClientPacket(conn *net.UDPConn, buf, _ []byte) (int, *net.UDPAddr, net.IP, error) {
	n, client, err := conn.ReadFromUDP(buf)
	return n, client, nil, err
}

func writeClientPacket(conn *net.UDPConn, packet []byte, client *net.UDPAddr, _ net.IP) error {
	_, err := conn.WriteToUDP(packet, client)
	return err
}
