package frpcembeddedclient

import (
	"context"
	"os"
	"testing"
	"time"
)

func TestConfiguredServerHandshake(t *testing.T) {
	configPath := os.Getenv("MESHARC_TEST_FRPC_CONFIG")
	if configPath == "" {
		t.Skip("requires an explicitly authorized existing tunnel configuration")
	}
	configText, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal("cannot read test configuration")
	}
	prepared, err := Prepare(string(configText))
	if err != nil {
		t.Fatal("configuration validation failed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- prepared.Run(ctx) }()
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case runError := <-done:
			if runError != nil {
				t.Fatal("existing tunnel login failed:", runError)
			}
			t.Fatal("client stopped before proxy registration")
		case <-ctx.Done():
			<-done
			t.Fatal("existing tunnel registration timed out")
		case <-ticker.C:
			if prepared.ConnectedToFrps() {
				cancel()
				<-done
				t.Log("existing tunnel proxy registration confirmed; forwarding not tested")
				return
			}
		}
	}
}
