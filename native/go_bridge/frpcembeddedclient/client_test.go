package frpcembeddedclient

import (
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strconv"
	"testing"
	"time"

	frpconfig "github.com/fatedier/frp/pkg/config"
	v1 "github.com/fatedier/frp/pkg/config/v1"
	frpserver "github.com/fatedier/frp/server"
)

const validTCPConfig = `serverAddr = "127.0.0.1"
serverPort = 7000

[auth]
method = "token"
token = "test-only"

[[proxies]]
name = "local-web"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8080
remotePort = 18080
`

const localFrpsTestToken = "local-e2e-dummy-token"
const localFrpcTestUser = "rootuser"

func TestPrepareAcceptsTCPProxy(t *testing.T) {
	prepared, err := Prepare(validTCPConfig)
	if err != nil {
		t.Fatal(err)
	}
	if got := prepared.ProxyCount(); got != 1 {
		t.Fatalf("ProxyCount() = %d, want 1", got)
	}
}

func TestPrepareRejectsUnsafeOrOutOfScopeConfig(t *testing.T) {
	tests := []struct {
		name   string
		config string
	}{
		{name: "include", config: "includes = [\"/tmp/other.toml\"]\n" + validTCPConfig},
		{name: "feature gate", config: validTCPConfig + "\n[featureGates]\nVirtualNet = true\n"},
		{name: "web server", config: validTCPConfig + "\n[webServer]\nport = 7400\n"},
		{name: "token exec", config: validTCPConfig + "\n[auth.tokenSource]\ntype = \"exec\"\n"},
		{name: "visitor", config: validTCPConfig + "\n[[visitors]]\nname = \"visitor\"\ntype = \"stcp\"\n"},
		{name: "unknown field", config: "notAField = true\n" + validTCPConfig},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := Prepare(test.config); err == nil {
				t.Fatal("Prepare() succeeded for rejected config")
			}
		})
	}
}

func TestRunStopsWhenContextIsCancelled(t *testing.T) {
	config := `serverAddr = "127.0.0.1"
serverPort = 1
loginFailExit = false

[auth]
method = "token"
token = "test-only"

[[proxies]]
name = "local-web"
type = "tcp"
localIP = "127.0.0.1"
localPort = 8080
remotePort = 18080
`
	prepared, err := Prepare(config)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- prepared.Run(ctx) }()
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Run() after cancellation: %v", err)
		}
	case <-time.After(6 * time.Second):
		t.Fatal("Run() did not stop after context cancellation")
	}
}

func TestEmbeddedClientMapsLocalTCPEchoThroughLocalFrps(t *testing.T) {
	controlPort := reserveTCPPort(t)
	remotePort := reserveTCPPort(t)
	secondRemotePort := reserveTCPPort(t)
	localListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer localListener.Close()
	localPort := localListener.Addr().(*net.TCPAddr).Port

	echoDone := make(chan struct{})
	go func() {
		defer close(echoDone)
		for {
			conn, acceptErr := localListener.Accept()
			if acceptErr != nil {
				return
			}
			go func() {
				defer conn.Close()
				_, _ = io.Copy(conn, conn)
			}()
		}
	}()

	frpsCtx, stopFrps := context.WithCancel(context.Background())
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	frps := exec.CommandContext(frpsCtx, executable, "-test.run=^TestLocalFrpsHelper$")
	frps.Env = append(os.Environ(),
		fmt.Sprintf("MESHARC_TEST_FRPS_PORT=%d", controlPort),
		"MESHARC_TEST_FRPS_TOKEN="+localFrpsTestToken,
	)
	if err := frps.Start(); err != nil {
		t.Fatal(err)
	}
	frpsDone := make(chan struct{})
	frpsStopped := false
	go func() {
		defer close(frpsDone)
		_ = frps.Wait()
	}()
	defer func() {
		stopFrps()
		if frpsStopped {
			return
		}
		select {
		case <-frpsDone:
		case <-time.After(5 * time.Second):
			t.Error("local frps did not stop")
			_ = frps.Process.Kill()
		}
	}()
	readyDeadline := time.Now().Add(5 * time.Second)
	for {
		probe, probeError := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", controlPort), 100*time.Millisecond)
		if probeError == nil {
			_ = probe.Close()
			break
		}
		if time.Now().After(readyDeadline) {
			t.Fatal("local frps helper did not become ready")
		}
		time.Sleep(25 * time.Millisecond)
	}

	config := fmt.Sprintf(`user = %q
serverAddr = "127.0.0.1"
serverPort = %d

[auth]
method = "token"
token = %q

[transport.tls]
enable = false
disableCustomTLSFirstByte = false

[[proxies]]
name = "loopback-echo"
type = "tcp"
localIP = "127.0.0.1"
localPort = %d
remotePort = %d
`, localFrpcTestUser, controlPort, localFrpsTestToken, localPort, remotePort)
	var parsed v1.ClientConfig
	if err := frpconfig.LoadConfigure([]byte(config), &parsed); err != nil {
		t.Fatalf("parse loopback frpc config: %v", err)
	}
	if parsed.User != localFrpcTestUser {
		t.Fatalf("parsed user = %q, want %q", parsed.User, localFrpcTestUser)
	}
	if parsed.Transport.TLS.Enable == nil || *parsed.Transport.TLS.Enable {
		t.Fatalf("parsed TLS enable = %v, want false", parsed.Transport.TLS.Enable)
	}
	if parsed.Transport.TLS.DisableCustomTLSFirstByte == nil || *parsed.Transport.TLS.DisableCustomTLSFirstByte {
		t.Fatalf("parsed disableCustomTLSFirstByte = %v, want false", parsed.Transport.TLS.DisableCustomTLSFirstByte)
	}
	prepared, err := Prepare(config)
	if err != nil {
		t.Fatalf("prepare embedded frpc: %v", err)
	}
	if got, want := prepared.proxyNames[0], localFrpcTestUser+".loopback-echo"; got != want {
		t.Fatalf("prepared proxy name = %q, want user-prefixed %q", got, want)
	}
	clientCtx, stopClient := context.WithCancel(context.Background())
	clientDone := make(chan error, 1)
	clientStopped := false
	go func() { clientDone <- prepared.Run(clientCtx) }()
	defer func() {
		stopClient()
		if clientStopped {
			return
		}
		select {
		case runErr := <-clientDone:
			if runErr != nil {
				t.Errorf("embedded frpc stopped with error: %v", runErr)
			}
		case <-time.After(5 * time.Second):
			t.Error("embedded frpc did not stop after cancellation")
		}
	}()
	secondConfig := fmt.Sprintf(`user = "seconduser"
serverAddr = "127.0.0.1"
serverPort = %d

[auth]
method = "token"
token = %q

[transport.tls]
enable = false
disableCustomTLSFirstByte = false

[[proxies]]
name = "second-loopback-echo"
type = "tcp"
localIP = "127.0.0.1"
localPort = %d
remotePort = %d
`, controlPort, localFrpsTestToken, localPort, secondRemotePort)
	secondPrepared, err := Prepare(secondConfig)
	if err != nil {
		t.Fatalf("prepare second embedded frpc: %v", err)
	}
	secondClientCtx, stopSecondClient := context.WithCancel(context.Background())
	secondClientDone := make(chan error, 1)
	secondClientStopped := false
	go func() { secondClientDone <- secondPrepared.Run(secondClientCtx) }()
	defer func() {
		stopSecondClient()
		if secondClientStopped {
			return
		}
		select {
		case runErr := <-secondClientDone:
			if runErr != nil {
				t.Errorf("second embedded frpc stopped with error: %v", runErr)
			}
		case <-time.After(5 * time.Second):
			t.Error("second embedded frpc did not stop after cancellation")
		}
	}()

	deadline := time.Now().Add(10 * time.Second)
	for !prepared.ConnectedToFrps() || !secondPrepared.ConnectedToFrps() {
		if time.Now().After(deadline) {
			t.Fatal("embedded frpc did not register its proxy with local frps")
		}
		time.Sleep(25 * time.Millisecond)
	}

	conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(remotePort)), 2*time.Second)
	if err != nil {
		t.Fatalf("dial mapped local port: %v", err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	want := []byte("frp-local-e2e\n")
	if _, err := conn.Write(want); err != nil {
		t.Fatalf("write to mapped port: %v", err)
	}
	got := make([]byte, len(want))
	if _, err := io.ReadFull(conn, got); err != nil {
		t.Fatalf("read echo through mapped port: %v", err)
	}
	if string(got) != string(want) {
		t.Fatalf("echo = %q, want %q", got, want)
	}

	secondConn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(secondRemotePort)), 2*time.Second)
	if err != nil {
		t.Fatalf("dial second mapped local port: %v", err)
	}
	_ = secondConn.SetDeadline(time.Now().Add(3 * time.Second))
	secondWant := []byte("frp-second-local-e2e\n")
	if _, err := secondConn.Write(secondWant); err != nil {
		t.Fatalf("write to second mapped port: %v", err)
	}
	secondGot := make([]byte, len(secondWant))
	if _, err := io.ReadFull(secondConn, secondGot); err != nil {
		t.Fatalf("read echo through second mapped port: %v", err)
	}
	if string(secondGot) != string(secondWant) {
		t.Fatalf("second echo = %q, want %q", secondGot, secondWant)
	}
	_ = secondConn.Close()

	_ = conn.Close()
	stopSecondClient()
	select {
	case runErr := <-secondClientDone:
		if runErr != nil {
			t.Fatalf("second embedded frpc shutdown: %v", runErr)
		}
		secondClientStopped = true
	case <-time.After(5 * time.Second):
		t.Fatal("second embedded frpc did not stop after cancellation")
	}
	stopClient()
	select {
	case runErr := <-clientDone:
		if runErr != nil {
			t.Fatalf("embedded frpc shutdown: %v", runErr)
		}
		clientStopped = true
	case <-time.After(5 * time.Second):
		t.Fatal("embedded frpc did not stop after cancellation")
	}
	stopFrps()
	select {
	case <-frpsDone:
		frpsStopped = true
	case <-time.After(5 * time.Second):
		t.Fatal("local frps did not stop after cancellation")
	}
	_ = localListener.Close()
	select {
	case <-echoDone:
	case <-time.After(2 * time.Second):
		t.Fatal("local echo listener did not stop")
	}
}

func TestLocalFrpsHelper(t *testing.T) {
	portText := os.Getenv("MESHARC_TEST_FRPS_PORT")
	if portText == "" {
		return
	}
	token := os.Getenv("MESHARC_TEST_FRPS_TOKEN")
	if token == "" {
		t.Fatal("local frps helper requires its test-only dummy token")
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		t.Fatal(err)
	}
	serverConfig := &v1.ServerConfig{BindAddr: "127.0.0.1", BindPort: port, ProxyBindAddr: "127.0.0.1",
		Auth: v1.AuthServerConfig{Method: "token", Token: token}}
	serverConfig.Complete()
	service, err := frpserver.NewService(serverConfig)
	if err != nil {
		t.Fatal(err)
	}
	service.Run(context.Background())
}

func reserveTCPPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve loopback TCP port: %v", err)
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}
