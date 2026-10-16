package main

import (
	"io"
	"net"
	"net/netip"
	"testing"
	"time"

	"tailscale.com/tsnet"
)

func TestParseInboundTCPPorts(t *testing.T) {
	ports, err := parseInboundTCPPorts(`[]`)
	if err != nil || len(ports) != 0 {
		t.Fatalf("empty allowlist = %v, %v", ports, err)
	}
	ports, err = parseInboundTCPPorts(`[3240,3389]`)
	if err != nil || len(ports) != 2 {
		t.Fatalf("explicit allowlist = %v, %v", ports, err)
	}
	for _, input := range []string{`null`, `"3240"`, `[0]`, `[65536]`, `[-1]`, `[1.5]`} {
		if _, err := parseInboundTCPPorts(input); err == nil {
			t.Errorf("parseInboundTCPPorts(%q) unexpectedly succeeded", input)
		}
	}
	tooMany := `[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17]`
	if _, err := parseInboundTCPPorts(tooMany); err == nil {
		t.Fatal("allowlist larger than 16 ports unexpectedly succeeded")
	}
}

func TestParseInboundTCPPolicy(t *testing.T) {
	allowAll, ports, err := parseInboundTCPPolicy(`{"allowAll":true,"ports":[]}`)
	if err != nil || !allowAll || len(ports) != 0 {
		t.Fatalf("allow-all policy = %t, %v, %v", allowAll, ports, err)
	}
	allowAll, ports, err = parseInboundTCPPolicy(`{"allowAll":true,"ports":[3240]}`)
	if err != nil || !allowAll || len(ports) != 1 {
		t.Fatalf("allow-all policy with retained selection = %t, %v, %v", allowAll, ports, err)
	}
	allowAll, ports, err = parseInboundTCPPolicy(`{"allowAll":false,"ports":[3240,3389]}`)
	if err != nil || allowAll || len(ports) != 2 {
		t.Fatalf("explicit policy = %t, %v, %v", allowAll, ports, err)
	}
	for _, input := range []string{
		`null`,
		`{"allowAll":true,"ports":null}`,
		`{"allowAll":true}`,
		`{"allowAll":false,"ports":[1055]}`,
		`{"allowAll":false,"ports":[],"extra":true}`,
		`{"allowAll":false,"ports":[]} trailing`,
	} {
		if _, _, err := parseInboundTCPPolicy(input); err == nil {
			t.Errorf("parseInboundTCPPolicy(%q) unexpectedly succeeded", input)
		}
	}
}

func TestInboundTCPAllowAllExcludesSOCKSAndNeverEnumeratesPorts(t *testing.T) {
	bridge := tcpServiceBridge{active: true, allowAll: true}
	if !bridge.allowsPortLocked(3240) || !bridge.allowsPortLocked(3389) {
		t.Fatal("allow-all policy did not admit service ports")
	}
	if bridge.allowsPortLocked(1055) {
		t.Fatal("allow-all policy admitted the local SOCKS listener")
	}
	ports, enabled, allowAll := bridge.status()
	if !enabled || !allowAll || len(ports) != 0 {
		t.Fatalf("allow-all bridge status = %v, %t, %t", ports, enabled, allowAll)
	}
	defaultBridge := tcpServiceBridge{}
	if ports, enabled, allowAll := defaultBridge.status(); enabled || allowAll || len(ports) != 0 {
		t.Fatalf("default-off bridge status = %v, %t, %t", ports, enabled, allowAll)
	}
}

func TestTCPServiceBridgeRelaysAndClosesBothDirections(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	port := listener.Addr().(*net.TCPAddr).Port
	go func() {
		service, acceptErr := listener.Accept()
		if acceptErr != nil {
			return
		}
		defer service.Close()
		_, _ = io.Copy(service, service)
	}()

	client, peer := net.Pipe()
	flow := tcpBridgeFlow{
		source:      netip.MustParseAddrPort("100.64.0.2:40000"),
		destination: netip.MustParseAddrPort("100.64.0.1:3240"),
	}
	session := &tcpBridgeSession{client: client, port: 3240, flow: flow}
	bridge := tcpServiceBridge{
		active:   true,
		allowAll: true,
		flows:    map[tcpBridgeFlow]time.Time{flow: {}},
		sessions: map[*tcpBridgeSession]struct{}{session: {}},
	}
	if !bridge.interceptTCP(flow.source, flow.destination, false) {
		t.Fatal("established session flow was not retained")
	}
	go bridge.serve(session, uint16(port))
	if _, err := peer.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	_ = peer.SetReadDeadline(time.Now().Add(2 * time.Second))
	got := make([]byte, 5)
	if _, err := io.ReadFull(peer, got); err != nil || string(got) != "hello" {
		t.Fatalf("bridge echo = %q, %v", got, err)
	}
	_ = peer.Close()
	deadline := time.Now().Add(2 * time.Second)
	for {
		bridge.mu.Lock()
		remaining := len(bridge.sessions)
		bridge.mu.Unlock()
		if remaining == 0 {
			bridge.mu.Lock()
			_, flowRemaining := bridge.flows[flow]
			bridge.mu.Unlock()
			if flowRemaining {
				t.Fatal("established flow remained tracked after its session ended")
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("bridge session remained active on port %d", port)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestTCPServiceBridgeDisableClosesTrackedConnections(t *testing.T) {
	client, clientPeer := net.Pipe()
	service, servicePeer := net.Pipe()
	session := &tcpBridgeSession{client: client, service: service}
	bridge := tcpServiceBridge{
		active:   true,
		ports:    map[uint16]struct{}{3240: {}},
		sessions: map[*tcpBridgeSession]struct{}{session: {}},
	}
	bridge.disable()
	defer clientPeer.Close()
	defer servicePeer.Close()
	buffer := make([]byte, 1)
	if _, err := clientPeer.Read(buffer); err == nil {
		t.Fatal("bridge client connection survived disable")
	}
	if _, err := servicePeer.Read(buffer); err == nil {
		t.Fatal("local service connection survived disable")
	}
	if ports, enabled, allowAll := bridge.status(); enabled || allowAll || len(ports) != 0 {
		t.Fatalf("disabled bridge status = %v, %t, %t", ports, enabled, allowAll)
	}
}

func TestInboundTCPPolicyNarrowingClosesRevokedSessions(t *testing.T) {
	client, clientPeer := net.Pipe()
	defer clientPeer.Close()
	session := &tcpBridgeSession{client: client, port: 3389}
	bridge := tcpServiceBridge{
		active:   true,
		server:   &tsnet.Server{},
		allowAll: true,
		sessions: map[*tcpBridgeSession]struct{}{session: {}},
	}
	if err := bridge.setPolicy(false, map[uint16]struct{}{3240: {}}); err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, 1)
	if _, err := clientPeer.Read(buffer); err == nil {
		t.Fatal("revoked bridge session remained open")
	}
	if _, enabled, allowAll := bridge.status(); !enabled || allowAll {
		t.Fatal("explicit-port policy was not applied")
	}
}
