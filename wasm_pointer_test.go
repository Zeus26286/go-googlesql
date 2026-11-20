package googlesql

import (
	"os"
	"strings"
	"testing"

	wasm2go "github.com/goccy/googlesqlwasm2go"
)

// TestWasmPointersAbove2GiB checks that the bridge handles wasm
// addresses at or above 2 GiB. wasm32 addresses are unsigned, but
// wasm2go hands them to Go as int32, so an address past 2 GiB is
// negative. Slicing the wasm memory with it directly panicked with
// "slice bounds out of range [-2147...:]".
//
// It grows the wasm heap past 2 GiB, so it needs several GiB of RAM
// and only runs with GOOGLESQL_LARGE_MEMORY_TEST=1.
func TestWasmPointersAbove2GiB(t *testing.T) {
	if os.Getenv("GOOGLESQL_LARGE_MEMORY_TEST") == "" {
		t.Skip("set GOOGLESQL_LARGE_MEMORY_TEST=1 to run (needs several GiB of RAM)")
	}
	if err := Init(); err != nil {
		t.Fatal(err)
	}
	m := module()

	const (
		chunk    = 256 << 20 // filler allocation size
		reqBytes = 16 << 20  // size of the parse request below
	)
	above2GiB := func(p int32) bool { return uint32(p) >= 1<<31 }

	// Hold filler allocations until a fresh allocation of the request's
	// size lands above 2 GiB. malloc is best-fit, so once that happens
	// no free chunk below 2 GiB can hold the request either.
	var fillers []int32
	defer func() {
		m.mu.Lock()
		for _, p := range fillers {
			wasm2go.WasmFree(m.g, p)
		}
		m.mu.Unlock()
	}()
	for {
		m.mu.Lock()
		probe := wasm2go.WasmAlloc(m.g, reqBytes)
		if probe == 0 {
			m.mu.Unlock()
			t.Fatal("wasm heap exhausted before reaching 2 GiB")
		}
		wasm2go.WasmFree(m.g, probe)
		if above2GiB(probe) {
			m.mu.Unlock()
			break
		}
		p := wasm2go.WasmAlloc(m.g, chunk)
		m.mu.Unlock()
		if p == 0 {
			t.Fatal("wasm heap exhausted before reaching 2 GiB")
		}
		fillers = append(fillers, p)
	}

	// The request buffer for this call is allocated above 2 GiB, and so
	// is the response.
	literal := strings.Repeat("a", reqBytes)
	opts, err := NewParserOptions()
	if err != nil {
		t.Fatal(err)
	}
	out, err := ParseStatement("SELECT '"+literal+"'", opts)
	if err != nil {
		t.Fatalf("ParseStatement: %v", err)
	}
	stmt, err := out.Statement()
	if err != nil {
		t.Fatalf("Statement: %v", err)
	}
	if stmt == nil {
		t.Fatal("Statement returned nil")
	}
}
