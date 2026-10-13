package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"time"

	"tailscaleohos.local/go_bridge/frpcembeddedclient"
)

type frpStatus struct {
	State           string `json:"state"`
	Error           string `json:"error"`
	ProxyCount      int    `json:"proxyCount"`
	ServiceRunning  bool   `json:"serviceRunning"`
	ConnectedToFrps bool   `json:"connectedToFrps"`
}

type frpProfileStatus struct {
	ProfileID       string `json:"profileId"`
	State           string `json:"state"`
	Error           string `json:"error"`
	ProxyCount      int    `json:"proxyCount"`
	ServiceRunning  bool   `json:"serviceRunning"`
	ConnectedToFrps bool   `json:"connectedToFrps"`
}

type frpProfileStartRequest struct {
	ProfileID string `json:"profileId"`
	Config    string `json:"config"`
}

const frpStopWaitLimit = 5 * time.Second

type frpLifecycle struct {
	mu              sync.Mutex
	state           string
	lastError       string
	proxyCount      int
	serviceRunning  bool
	connectedToFrps bool
	sequence        uint64
	cancel          context.CancelFunc
	done            chan struct{}
}

var embeddedFrpc = frpLifecycle{state: "stopped"}

var embeddedFrpProfiles = struct {
	mu       sync.Mutex
	profiles map[string]*frpLifecycle
}{profiles: make(map[string]*frpLifecycle)}

const (
	frpProfileMaxCount       = 32
	frpProfileIDMaxLength    = 100
	frpProfileConfigMaxBytes = 256 * 1024
)

func (lifecycle *frpLifecycle) start(configText string) frpStatus {
	lifecycle.mu.Lock()
	defer lifecycle.mu.Unlock()
	if lifecycle.state == "starting" || lifecycle.state == "running" || lifecycle.state == "stopping" {
		return lifecycle.snapshotLocked()
	}
	lifecycle.serviceRunning = false
	lifecycle.connectedToFrps = false
	prepared, err := frpcembeddedclient.Prepare(configText)
	if err != nil {
		lifecycle.state = "failed"
		lifecycle.lastError = err.Error()
		lifecycle.proxyCount = 0
		return lifecycle.snapshotLocked()
	}
	ctx, cancel := context.WithCancel(context.Background())
	lifecycle.sequence++
	sequence := lifecycle.sequence
	lifecycle.cancel = cancel
	lifecycle.done = make(chan struct{})
	lifecycle.state = "starting"
	lifecycle.lastError = ""
	lifecycle.proxyCount = prepared.ProxyCount()
	go lifecycle.run(ctx, sequence, prepared)
	return lifecycle.snapshotLocked()
}

func (lifecycle *frpLifecycle) run(ctx context.Context, sequence uint64, prepared *frpcembeddedclient.Prepared) {
	lifecycle.mu.Lock()
	if lifecycle.sequence != sequence {
		lifecycle.mu.Unlock()
		return
	}
	if lifecycle.state != "stopping" {
		lifecycle.state = "running"
	}
	lifecycle.serviceRunning = true
	lifecycle.mu.Unlock()

	runResult := make(chan error, 1)
	go func() { runResult <- prepared.Run(ctx) }()
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	ctxDone := ctx.Done()
	for {
		select {
		case err := <-runResult:
			lifecycle.finish(sequence, ctx, err)
			return
		case <-ticker.C:
			lifecycle.mu.Lock()
			if lifecycle.sequence == sequence {
				lifecycle.connectedToFrps = prepared.ConnectedToFrps()
			}
			lifecycle.mu.Unlock()
		case <-ctxDone:
			ctxDone = nil
		}
	}
}

func (lifecycle *frpLifecycle) finish(sequence uint64, ctx context.Context, err error) {
	lifecycle.mu.Lock()
	defer lifecycle.mu.Unlock()
	if lifecycle.sequence != sequence {
		return
	}
	if err != nil && !errors.Is(ctx.Err(), context.Canceled) {
		lifecycle.state = "failed"
		lifecycle.lastError = err.Error()
	} else {
		lifecycle.state = "stopped"
		lifecycle.lastError = ""
	}
	lifecycle.serviceRunning = false
	lifecycle.connectedToFrps = false
	lifecycle.cancel = nil
	close(lifecycle.done)
}

func (lifecycle *frpLifecycle) stop() frpStatus {
	cancel, done := lifecycle.beginStop()
	return lifecycle.waitForStop(cancel, done)
}

func (lifecycle *frpLifecycle) beginStop() (context.CancelFunc, chan struct{}) {
	lifecycle.mu.Lock()
	defer lifecycle.mu.Unlock()
	cancel := lifecycle.cancel
	done := lifecycle.done
	if cancel != nil {
		lifecycle.state = "stopping"
		lifecycle.connectedToFrps = false
	}
	return cancel, done
}

func (lifecycle *frpLifecycle) waitForStop(cancel context.CancelFunc, done chan struct{}) frpStatus {
	if cancel != nil {
		cancel()
	}
	if done != nil {
		timer := time.NewTimer(frpStopWaitLimit)
		defer timer.Stop()
		select {
		case <-done:
		case <-timer.C:
			lifecycle.mu.Lock()
			defer lifecycle.mu.Unlock()
			if lifecycle.state == "stopping" {
				lifecycle.lastError = "frpc shutdown is still pending; restart is blocked until cleanup completes"
			}
			return lifecycle.snapshotLocked()
		}
	}
	lifecycle.mu.Lock()
	defer lifecycle.mu.Unlock()
	if lifecycle.state != "failed" && lifecycle.state != "stopping" {
		lifecycle.state = "stopped"
		lifecycle.lastError = ""
	}
	if lifecycle.cancel == nil && lifecycle.state == "failed" {
		lifecycle.state = "stopped"
		lifecycle.lastError = ""
	}
	lifecycle.cancel = nil
	return lifecycle.snapshotLocked()
}

func (lifecycle *frpLifecycle) status() frpStatus {
	lifecycle.mu.Lock()
	defer lifecycle.mu.Unlock()
	return lifecycle.snapshotLocked()
}

func (lifecycle *frpLifecycle) snapshotLocked() frpStatus {
	return frpStatus{
		State: lifecycle.state, Error: lifecycle.lastError, ProxyCount: lifecycle.proxyCount,
		ServiceRunning: lifecycle.serviceRunning, ConnectedToFrps: lifecycle.connectedToFrps,
	}
}

func validFrpProfileID(profileID string) bool {
	if profileID == "" || len(profileID) > frpProfileIDMaxLength {
		return false
	}
	for _, char := range profileID {
		if (char < 'a' || char > 'z') && (char < 'A' || char > 'Z') &&
			(char < '0' || char > '9') && char != '_' && char != '-' {
			return false
		}
	}
	return true
}

func frpProfileJSON(profile frpProfileStatus) *C.char {
	encoded, err := json.Marshal(profile)
	if err != nil {
		return C.CString(`{"profileId":"","state":"failed","error":"status encoding failed","proxyCount":0}`)
	}
	return C.CString(string(encoded))
}

func makeFrpProfileStatus(profileID string, status frpStatus) frpProfileStatus {
	return frpProfileStatus{
		ProfileID: profileID, State: status.State, Error: status.Error, ProxyCount: status.ProxyCount,
		ServiceRunning: status.ServiceRunning, ConnectedToFrps: status.ConnectedToFrps,
	}
}

func frpProfilesStatusJSON(profiles []frpProfileStatus) *C.char {
	encoded, err := json.Marshal(profiles)
	if err != nil {
		return C.CString(`[]`)
	}
	return C.CString(string(encoded))
}

func frpProfileFailure(profileID, message string) *C.char {
	return frpProfileJSON(makeFrpProfileStatus(profileID, frpStatus{State: "failed", Error: message}))
}

func startFrpProfile(rawRequest string) *C.char {
	if len(rawRequest) > 1024*1024 {
		return frpProfileFailure("", "FRP profile request exceeds 1 MiB")
	}
	var request frpProfileStartRequest
	if err := json.Unmarshal([]byte(rawRequest), &request); err != nil {
		return frpProfileFailure("", "invalid FRP profile request JSON")
	}
	if !validFrpProfileID(request.ProfileID) {
		return frpProfileFailure("", "profileId must contain 1-100 ASCII letters, digits, underscores, or hyphens")
	}
	if len(request.Config) > frpProfileConfigMaxBytes {
		return frpProfileFailure(request.ProfileID, "FRP configuration exceeds 256 KiB")
	}

	embeddedFrpProfiles.mu.Lock()
	defer embeddedFrpProfiles.mu.Unlock()
	lifecycle, exists := embeddedFrpProfiles.profiles[request.ProfileID]
	if exists {
		status := lifecycle.status()
		if status.State == "starting" || status.State == "running" || status.State == "stopping" {
			return frpProfileJSON(makeFrpProfileStatus(request.ProfileID, status))
		}
	} else if len(embeddedFrpProfiles.profiles) >= frpProfileMaxCount {
		for id, candidate := range embeddedFrpProfiles.profiles {
			state := candidate.status().State
			if state == "stopped" || state == "failed" {
				delete(embeddedFrpProfiles.profiles, id)
				if len(embeddedFrpProfiles.profiles) < frpProfileMaxCount {
					break
				}
			}
		}
		if len(embeddedFrpProfiles.profiles) >= frpProfileMaxCount {
			return frpProfileFailure(request.ProfileID, "maximum of 32 active FRP profiles reached")
		}
	}
	if lifecycle == nil || (exists && lifecycle.status().State != "starting" &&
		lifecycle.status().State != "running" && lifecycle.status().State != "stopping") {
		lifecycle = &frpLifecycle{state: "stopped"}
		embeddedFrpProfiles.profiles[request.ProfileID] = lifecycle
	}
	status := lifecycle.start(request.Config)
	return frpProfileJSON(makeFrpProfileStatus(request.ProfileID, status))
}

func stopFrpProfile(profileID string) *C.char {
	if !validFrpProfileID(profileID) {
		return frpProfileFailure("", "invalid profileId")
	}
	embeddedFrpProfiles.mu.Lock()
	lifecycle := embeddedFrpProfiles.profiles[profileID]
	var cancel context.CancelFunc
	var done chan struct{}
	if lifecycle != nil {
		cancel, done = lifecycle.beginStop()
	}
	embeddedFrpProfiles.mu.Unlock()
	if lifecycle == nil {
		return frpProfileFailure(profileID, "FRP profile not found")
	}
	status := lifecycle.waitForStop(cancel, done)
	return frpProfileJSON(makeFrpProfileStatus(profileID, status))
}

func frpProfilesStatus() *C.char {
	embeddedFrpProfiles.mu.Lock()
	defer embeddedFrpProfiles.mu.Unlock()
	profiles := make([]frpProfileStatus, 0, len(embeddedFrpProfiles.profiles))
	for profileID, lifecycle := range embeddedFrpProfiles.profiles {
		profiles = append(profiles, makeFrpProfileStatus(profileID, lifecycle.status()))
	}
	return frpProfilesStatusJSON(profiles)
}

func frpStatusJSON(status frpStatus) *C.char {
	encoded, err := json.Marshal(status)
	if err != nil {
		return C.CString(`{"state":"failed","error":"status encoding failed","proxyCount":0}`)
	}
	return C.CString(string(encoded))
}

//export TSFrpStart
func TSFrpStart(configText *C.char) *C.char {
	if configText == nil {
		return frpStatusJSON(frpStatus{State: "failed", Error: "missing frpc TOML", ProxyCount: 0})
	}
	return frpStatusJSON(embeddedFrpc.start(C.GoString(configText)))
}

//export TSFrpStop
func TSFrpStop() *C.char {
	return frpStatusJSON(embeddedFrpc.stop())
}

//export TSFrpStatus
func TSFrpStatus() *C.char {
	return frpStatusJSON(embeddedFrpc.status())
}

//export TSFrpProfileStart
func TSFrpProfileStart(requestJSON *C.char) *C.char {
	if requestJSON == nil {
		return frpProfileFailure("", "missing FRP profile request")
	}
	return startFrpProfile(C.GoString(requestJSON))
}

//export TSFrpProfileStop
func TSFrpProfileStop(profileID *C.char) *C.char {
	if profileID == nil {
		return frpProfileFailure("", "missing profileId")
	}
	return stopFrpProfile(C.GoString(profileID))
}

//export TSFrpProfilesStatus
func TSFrpProfilesStatus() *C.char {
	return frpProfilesStatus()
}
