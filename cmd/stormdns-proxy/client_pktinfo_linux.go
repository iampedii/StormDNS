//go:build linux

package main

import (
	"io"
	"net"
	"syscall"
	"unsafe"
)

func enableDestinationPacketInfo(conn *net.UDPConn) error {
	raw, err := conn.SyscallConn()
	if err != nil {
		return err
	}
	var sockErr error
	if err := raw.Control(func(fd uintptr) {
		sockErr = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_IP, syscall.IP_PKTINFO, 1)
	}); err != nil {
		return err
	}
	return sockErr
}

func packetInfoOOBSize() int {
	return syscall.CmsgSpace(syscall.SizeofInet4Pktinfo)
}

func readClientPacket(conn *net.UDPConn, buf, oob []byte) (int, *net.UDPAddr, net.IP, error) {
	n, oobn, _, client, err := conn.ReadMsgUDP(buf, oob)
	if err != nil {
		return 0, nil, nil, err
	}
	return n, client, packetInfoLocalIP(oob[:oobn]), nil
}

func writeClientPacket(conn *net.UDPConn, packet []byte, client *net.UDPAddr, localIP net.IP) error {
	oob := marshalIPv4PacketInfo(localIP)
	if len(oob) == 0 {
		_, err := conn.WriteToUDP(packet, client)
		return err
	}
	n, _, err := conn.WriteMsgUDP(packet, oob, client)
	if err != nil {
		return err
	}
	if n != len(packet) {
		return io.ErrShortWrite
	}
	return nil
}

func packetInfoLocalIP(oob []byte) net.IP {
	messages, err := syscall.ParseSocketControlMessage(oob)
	if err != nil {
		return nil
	}
	for _, message := range messages {
		if message.Header.Level != syscall.IPPROTO_IP || message.Header.Type != syscall.IP_PKTINFO {
			continue
		}
		if len(message.Data) < syscall.SizeofInet4Pktinfo {
			continue
		}
		return net.IPv4(message.Data[8], message.Data[9], message.Data[10], message.Data[11]).To4()
	}
	return nil
}

func marshalIPv4PacketInfo(ip net.IP) []byte {
	ip4 := ip.To4()
	if ip4 == nil {
		return nil
	}

	oob := make([]byte, syscall.CmsgSpace(syscall.SizeofInet4Pktinfo))
	header := (*syscall.Cmsghdr)(unsafe.Pointer(&oob[0]))
	header.Level = syscall.IPPROTO_IP
	header.Type = syscall.IP_PKTINFO
	header.SetLen(syscall.CmsgLen(syscall.SizeofInet4Pktinfo))

	data := oob[syscall.CmsgLen(0):syscall.CmsgLen(syscall.SizeofInet4Pktinfo)]
	copy(data[4:8], ip4)
	copy(data[8:12], ip4)
	return oob
}
