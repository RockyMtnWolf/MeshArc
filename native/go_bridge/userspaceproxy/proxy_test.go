package userspaceproxy

import (
	"context"
	"io"
	"net"
	"testing"
	"time"
)

type testDialConnection struct {
	net.Conn
}

func (connection testDialConnection) LocalAddr() net.Addr {
	return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 12345}
}

func TestLoopbackProxyAndStop(t *testing.T) {
	var service Proxy
	requests := make(chan string, 1)
	err := service.Start("127.0.0.1:0", func(ctx context.Context, network, address string) (net.Conn, error) {
		requests <- network + " " + address
		client, target := net.Pipe()
		go func() {
			defer target.Close()
			buffer := make([]byte, 4)
			if _, failure := io.ReadFull(target, buffer); failure == nil {
				target.Write(buffer)
			}
		}()
		return testDialConnection{client}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer service.Stop()
	if !service.Active() {
		t.Fatal("listener not active")
	}
	client, err := net.DialTimeout("tcp", service.listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	client.SetDeadline(time.Now().Add(3 * time.Second))
	client.Write([]byte{5, 1, 0})
	selection := make([]byte, 2)
	if _, err := io.ReadFull(client, selection); err != nil || selection[1] != 0 {
		t.Fatalf("handshake: %v %v", selection, err)
	}
	client.Write([]byte{5, 1, 0, 1, 100, 96, 96, 103, 0, 80})
	reply := make([]byte, 10)
	if _, err := io.ReadFull(client, reply); err != nil || reply[1] != 0 {
		t.Fatalf("connect: %v %v", reply, err)
	}
	client.Write([]byte("test"))
	echo := make([]byte, 4)
	if _, err := io.ReadFull(client, echo); err != nil || string(echo) != "test" {
		t.Fatalf("relay: %s %v", echo, err)
	}
	if request := <-requests; request != "tcp 100.96.96.103:80" {
		t.Fatal(request)
	}
	service.Stop()
	if service.Active() {
		t.Fatal("still active after stop")
	}
	service.Stop()
}

func TestStopClosesPendingClients(t *testing.T) {
	var service Proxy
	if err := service.Start("127.0.0.1:0", func(context.Context, string, string) (net.Conn, error) { return nil, net.ErrClosed }); err != nil {
		t.Fatal(err)
	}
	defer service.Stop()
	client, err := net.DialTimeout("tcp", service.listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	client.SetDeadline(time.Now().Add(time.Second))
	client.Write([]byte{5, 1, 0})
	selection := make([]byte, 2)
	if _, err := io.ReadFull(client, selection); err != nil {
		t.Fatal(err)
	}
	service.Stop()
	if _, err := client.Read(selection); err == nil {
		t.Fatal("client survived stop")
	}
}
