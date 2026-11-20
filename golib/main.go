// Package main is the C ABI of libxray.so, the Xray-core build loaded by the
// HarmonyOS VPN extension through the NAPI shim in entry/src/main/cpp.
//
// Build it with scripts/build_libxray.sh (GOOS=openharmony, -buildmode=c-shared).
package main

/*
#include <stdlib.h>

// protect(fd) asks the VPN extension to exempt fd from the VPN; returns 1 on success.
typedef int (*xray_protect_fn)(int fd);
// log(line) hands one log line to the host.
typedef void (*xray_log_fn)(const char* line);

static int xray_call_protect(xray_protect_fn f, int fd) { return f ? f(fd) : 1; }
static void xray_call_log(xray_log_fn f, const char* line) { if (f) f(line); }
*/
import "C"

import (
	"bytes"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"unsafe"

	"github.com/xtls/xray-core/app/log"
	"github.com/xtls/xray-core/common"
	"github.com/xtls/xray-core/common/errors"
	commlog "github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/common/platform"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf/serial"
	"github.com/xtls/xray-core/transport/internet"

	_ "github.com/xtls/xray-core/main/distro/all"
)

var (
	mu       sync.Mutex
	instance *core.Instance

	cbMu      sync.RWMutex
	protectCb C.xray_protect_fn
	logCb     C.xray_log_fn
)

func init() {
	// Every socket Xray dials itself (proxy servers, direct traffic, DNS) must
	// be protected, or it is routed back into the VPN it serves.
	common.Must(internet.RegisterDialerController(func(network, address string, c syscall.RawConn) error {
		cbMu.RLock()
		f := protectCb
		cbMu.RUnlock()
		if f == nil {
			return nil
		}
		var protectErr error
		if err := c.Control(func(fd uintptr) {
			if C.xray_call_protect(f, C.int(fd)) == 0 {
				protectErr = errors.New("VPN protect failed for fd ", fd, " (", network, " ", address, ")")
			}
		}); err != nil {
			return err
		}
		return protectErr
	}))

	// "console" logs go to the host instead of stdout, which nobody reads on HarmonyOS.
	common.Must(log.RegisterHandlerCreator(log.LogType_Console, func(log.LogType, log.HandlerCreatorOptions) (commlog.Handler, error) {
		return commlog.NewLogger(func() commlog.Writer { return hostLogWriter{} }), nil
	}))
}

type hostLogWriter struct{}

func (hostLogWriter) Write(s string) error {
	emitLog(strings.TrimRight(s, "\r\n"))
	return nil
}

func (hostLogWriter) Close() error { return nil }

func emitLog(s string) {
	cbMu.RLock()
	f := logCb
	cbMu.RUnlock()
	if f == nil {
		return
	}
	cs := C.CString(s)
	C.xray_call_log(f, cs)
	C.free(unsafe.Pointer(cs))
}

func cError(err error) *C.char {
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

// XraySetCallbacks installs the protect and log callbacks. Either may be NULL.
// The callbacks are called from Go-owned threads, possibly concurrently.
//
//export XraySetCallbacks
func XraySetCallbacks(protect C.xray_protect_fn, logFn C.xray_log_fn) {
	cbMu.Lock()
	protectCb = protect
	logCb = logFn
	cbMu.Unlock()
}

// XrayStart starts Xray with a JSON config. tunFd is the descriptor from
// VpnConnection.create(), or -1 for no TUN. assetDir holds geoip.dat and
// geosite.dat, or is NULL/empty. Returns NULL on success, otherwise an error
// message that must be released with XrayFree.
//
//export XrayStart
func XrayStart(configJSON *C.char, tunFd C.int, assetDir *C.char) *C.char {
	mu.Lock()
	defer mu.Unlock()
	if instance != nil {
		return cError(errors.New("Xray is already running"))
	}
	// Go copies the environment at start-up and reads it from that copy, so
	// these reach the platform flags read by Xray below.
	if tunFd >= 0 {
		if err := os.Setenv(platform.TunFdKey, strconv.Itoa(int(tunFd))); err != nil {
			return cError(err)
		}
	} else {
		_ = os.Unsetenv(platform.TunFdKey)
	}
	if assetDir != nil {
		if dir := C.GoString(assetDir); dir != "" {
			if err := os.Setenv(platform.AssetLocation, dir); err != nil {
				return cError(err)
			}
		}
	}

	config, err := serial.LoadJSONConfig(bytes.NewReader([]byte(C.GoString(configJSON))))
	if err != nil {
		return cError(errors.New("invalid config").Base(err))
	}
	server, err := core.New(config)
	if err != nil {
		return cError(errors.New("failed to create Xray").Base(err))
	}
	if err := server.Start(); err != nil {
		_ = server.Close()
		return cError(errors.New("failed to start Xray").Base(err))
	}
	instance = server
	emitLog("Xray " + core.Version() + " started")
	return nil
}

// XrayStop stops the running instance, if any. Returns NULL on success,
// otherwise an error message that must be released with XrayFree.
//
//export XrayStop
func XrayStop() *C.char {
	mu.Lock()
	defer mu.Unlock()
	if instance == nil {
		return nil
	}
	err := instance.Close()
	instance = nil
	emitLog("Xray stopped")
	return cError(err)
}

// XrayIsRunning returns 1 while an instance is running.
//
//export XrayIsRunning
func XrayIsRunning() C.int {
	mu.Lock()
	defer mu.Unlock()
	if instance != nil && instance.IsRunning() {
		return 1
	}
	return 0
}

// XrayVersion returns the Xray-core version string; release it with XrayFree.
//
//export XrayVersion
func XrayVersion() *C.char {
	return C.CString(core.Version())
}

// XrayFree releases a string returned by this library.
//
//export XrayFree
func XrayFree(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func main() {}
