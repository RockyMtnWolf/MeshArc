package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"

	"tailscaleohos.local/go_bridge/clashconfigrepair"
)

//export TSClashRepairConfig
func TSClashRepairConfig(input *C.char) *C.char {
	content, err := clashconfigrepair.Repair(C.GoString(input))
	failure := ""
	if err != nil {
		failure = err.Error()
	}
	encoded, _ := json.Marshal(struct {
		Content string `json:"content"`
		Error   string `json:"error"`
	}{content, failure})
	return C.CString(string(encoded))
}
