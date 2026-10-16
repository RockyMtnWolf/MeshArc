package main

import (
	"encoding/json"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"tailscale.com/tsnet"
)

func enableTestTCPBridge(t *testing.T, policyPath string) (*tcpServiceBridge, *tsnet.Server) {
	t.Helper()
	server := &tsnet.Server{}
	bridge := &tcpServiceBridge{policyPath: policyPath}
	bridge.enable(server)
	t.Cleanup(bridge.disable)
	return bridge, server
}

func TestInboundTCPPolicyPersistsWithoutSOCKSAndSurvivesDisable(t *testing.T) {
	policyPath := filepath.Join(t.TempDir(), "inbound-tcp-policy.json")
	bridge, _ := enableTestTCPBridge(t, policyPath)
	if clashProxy.Active() {
		t.Fatal("test requires the coexistence SOCKS proxy to remain inactive")
	}
	if err := bridge.setPolicy(false, map[uint16]struct{}{3389: {}, 3240: {}}); err != nil {
		t.Fatalf("set inbound policy without SOCKS: %v", err)
	}

	encoded, err := os.ReadFile(policyPath)
	if err != nil {
		t.Fatalf("read persisted policy: %v", err)
	}
	var policy struct {
		AllowAll bool     `json:"allowAll"`
		Ports    []uint16 `json:"ports"`
	}
	if err := json.Unmarshal(encoded, &policy); err != nil {
		t.Fatalf("decode persisted policy: %v", err)
	}
	if policy.AllowAll || len(policy.Ports) != 2 || policy.Ports[0] != 3240 || policy.Ports[1] != 3389 {
		t.Fatalf("persisted policy = %+v", policy)
	}
	info, err := os.Stat(policyPath)
	if err != nil {
		t.Fatalf("stat persisted policy: %v", err)
	}
	if runtime.GOOS != "windows" {
		if got := info.Mode().Perm(); got != 0600 {
			t.Fatalf("persisted policy mode = %04o, want 0600", got)
		}
	}
	if _, err := os.Stat(policyPath + ".tmp"); !os.IsNotExist(err) {
		t.Fatalf("temporary policy file remains after save: %v", err)
	}

	flow := tcpBridgeFlow{
		source:      netip.MustParseAddrPort("100.64.0.2:40000"),
		destination: netip.MustParseAddrPort("100.64.0.1:3240"),
	}
	if !bridge.interceptTCP(flow.source, flow.destination, true) {
		t.Fatal("enabled policy did not capture an allowed initial SYN")
	}
	client, clientPeer := net.Pipe()
	defer clientPeer.Close()
	session := &tcpBridgeSession{client: client, port: flow.destination.Port(), flow: flow}
	bridge.mu.Lock()
	bridge.sessions[session] = struct{}{}
	bridge.mu.Unlock()
	bridge.disable()

	if _, err := os.Stat(policyPath); err != nil {
		t.Fatalf("disable removed persisted policy: %v", err)
	}
	bridge.mu.Lock()
	active, allowAll := bridge.active, bridge.allowAll
	ports, flows, sessions := len(bridge.ports), len(bridge.flows), len(bridge.sessions)
	bridge.mu.Unlock()
	if active || allowAll || ports != 0 || flows != 0 || sessions != 0 {
		t.Fatalf("disabled bridge retained memory state: active=%t allowAll=%t ports=%d flows=%d sessions=%d",
			active, allowAll, ports, flows, sessions)
	}
}

func TestInboundTCPPolicyDefaultsOffAndRestoresOnEnable(t *testing.T) {
	t.Run("missing policy defaults off", func(t *testing.T) {
		bridge, _ := enableTestTCPBridge(t, filepath.Join(t.TempDir(), "missing-policy.json"))
		if ports, enabled, allowAll := bridge.status(); enabled || allowAll || len(ports) != 0 {
			t.Fatalf("missing policy status = %v, %t, %t", ports, enabled, allowAll)
		}
	})

	t.Run("saved policy restores", func(t *testing.T) {
		policyPath := filepath.Join(t.TempDir(), "inbound-tcp-policy.json")
		if err := os.WriteFile(policyPath, []byte(`{"allowAll":true,"ports":[3240]}`), 0600); err != nil {
			t.Fatal(err)
		}
		bridge, _ := enableTestTCPBridge(t, policyPath)
		if ports, enabled, allowAll := bridge.status(); !enabled || !allowAll || len(ports) != 1 || ports[0] != 3240 {
			t.Fatalf("restored policy status = %v, %t, %t", ports, enabled, allowAll)
		}
	})

	t.Run("corrupt policy fails closed", func(t *testing.T) {
		policyPath := filepath.Join(t.TempDir(), "inbound-tcp-policy.json")
		if err := os.WriteFile(policyPath, []byte(`{"allowAll":true,"ports":[1055]}`), 0600); err != nil {
			t.Fatal(err)
		}
		bridge, _ := enableTestTCPBridge(t, policyPath)
		if ports, enabled, allowAll := bridge.status(); enabled || allowAll || len(ports) != 0 {
			t.Fatalf("corrupt policy status = %v, %t, %t", ports, enabled, allowAll)
		}
		source := netip.MustParseAddrPort("100.64.0.2:40000")
		destination := netip.MustParseAddrPort("100.64.0.1:3240")
		if bridge.interceptTCP(source, destination, true) {
			t.Fatal("corrupt policy allowed inbound capture")
		}
	})
}

func TestInboundTCPPolicyNarrowingRevokesTrackedFlows(t *testing.T) {
	bridge, _ := enableTestTCPBridge(t, "")
	if err := bridge.setPolicy(true, nil); err != nil {
		t.Fatalf("set allow-all policy: %v", err)
	}
	source := netip.MustParseAddrPort("100.64.0.2:40000")
	destination := netip.MustParseAddrPort("100.64.0.1:3240")
	if !bridge.interceptTCP(source, destination, true) {
		t.Fatal("allow-all policy did not capture initial SYN")
	}
	if err := bridge.setPolicy(false, map[uint16]struct{}{3389: {}}); err != nil {
		t.Fatalf("narrow inbound policy: %v", err)
	}
	if bridge.interceptTCP(source, destination, false) {
		t.Fatal("narrowed policy retained a revoked flow")
	}
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if len(bridge.flows) != 0 {
		t.Fatalf("revoked flow remained in tracking map: %d", len(bridge.flows))
	}
}

func TestInboundTCPFlowCaptureRequiresInitialSYNAndExactTuple(t *testing.T) {
	bridge := tcpServiceBridge{active: true, allowAll: true}
	source := netip.MustParseAddrPort("100.64.0.2:40000")
	destination := netip.MustParseAddrPort("100.64.0.1:3240")
	if bridge.interceptTCP(source, destination, false) {
		t.Fatal("untracked SYNACK/ACK was captured")
	}
	if !bridge.interceptTCP(source, destination, true) {
		t.Fatal("initial SYN was not captured")
	}
	if !bridge.interceptTCP(source, destination, false) {
		t.Fatal("tracked flow continuation was not captured")
	}
	if bridge.interceptTCP(netip.MustParseAddrPort("100.64.0.2:40001"), destination, false) {
		t.Fatal("flow with a different source port was captured")
	}
	if bridge.interceptTCP(source, netip.MustParseAddrPort("100.64.0.1:3389"), false) {
		t.Fatal("flow with a different destination port was captured")
	}
	bridge.active = false
	if bridge.interceptTCP(source, destination, false) {
		t.Fatal("inactive bridge captured a tracked flow")
	}
}

func TestInboundTCPFlowInitialSYNExpiresAfterThirtySeconds(t *testing.T) {
	bridge := tcpServiceBridge{active: true, ports: map[uint16]struct{}{3240: {}}}
	source := netip.MustParseAddrPort("100.64.0.2:40000")
	destination := netip.MustParseAddrPort("100.64.0.1:3240")
	if !bridge.interceptTCP(source, destination, true) {
		t.Fatal("initial SYN was not captured")
	}
	flow := tcpBridgeFlow{source, destination}
	bridge.mu.Lock()
	expires := bridge.flows[flow]
	bridge.flows[flow] = time.Now().Add(-time.Second)
	bridge.mu.Unlock()
	remaining := time.Until(expires)
	if remaining < 29*time.Second || remaining > 31*time.Second {
		t.Fatalf("initial flow lifetime = %v, want about 30s", remaining)
	}
	if bridge.interceptTCP(source, destination, false) {
		t.Fatal("expired flow continuation was captured")
	}
	bridge.mu.Lock()
	_, tracked := bridge.flows[flow]
	bridge.mu.Unlock()
	if tracked {
		t.Fatal("expired flow remained in tracking map")
	}
	if !bridge.interceptTCP(source, destination, true) {
		t.Fatal("new initial SYN did not replace the expired flow")
	}
}

func TestInboundTCPFlowTrackingIsBounded(t *testing.T) {
	bridge := tcpServiceBridge{active: true, allowAll: true}
	destination := netip.MustParseAddrPort("100.64.0.1:3240")
	for index := 0; index < 512; index++ {
		source := netip.AddrPortFrom(netip.MustParseAddr("100.64.0.2"), uint16(10000+index))
		if !bridge.interceptTCP(source, destination, true) {
			t.Fatalf("initial SYN %d was rejected before reaching the 512-flow limit", index+1)
		}
	}
	overflow := netip.AddrPortFrom(netip.MustParseAddr("100.64.0.2"), 10512)
	if bridge.interceptTCP(overflow, destination, true) {
		t.Fatal("flow beyond the 512-entry limit was captured")
	}
	bridge.mu.Lock()
	count := len(bridge.flows)
	bridge.mu.Unlock()
	if count != 512 {
		t.Fatalf("tracked flow count = %d, want 512", count)
	}
}

func TestInboundTCPFlowRejectsStaleServerCallback(t *testing.T) {
	currentServer := &tsnet.Server{}
	oldServer := &tsnet.Server{}
	bridge := tcpServiceBridge{
		server:   currentServer,
		active:   true,
		allowAll: true,
	}
	source := netip.MustParseAddrPort("100.64.0.2:40000")
	destination := netip.MustParseAddrPort("100.64.0.1:3240")
	if bridge.interceptServerTCP(oldServer, source, destination, true) {
		t.Fatal("stale server callback captured a flow")
	}
	if len(bridge.flows) != 0 {
		t.Fatal("stale server callback inserted a flow")
	}
	if !bridge.interceptServerTCP(currentServer, source, destination, true) {
		t.Fatal("current server callback did not capture the flow")
	}
}
