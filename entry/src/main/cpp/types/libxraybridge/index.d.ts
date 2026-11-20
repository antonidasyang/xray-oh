// ArkTS declarations for libxraybridge.so (entry/src/main/cpp/napi_init.cpp).

export interface ProtectRequest {
  id: number;
  fd: number;
}

// Starts Xray with a full JSON config. tunFd comes from VpnConnection.create();
// assetDir holds geoip.dat / geosite.dat. Resolves with '' on success, else the error.
export const start: (configJson: string, tunFd: number, assetDir: string) => Promise<string>;
// Stops Xray. Resolves with '' on success, else the error.
export const stop: () => Promise<string>;
export const version: () => string;
export const isRunning: () => boolean;
export const setLogListener: (listener: (line: string) => void) => void;
// The handler must eventually call completeProtect(req.id, ok) for every request.
export const setProtectHandler: (handler: (req: ProtectRequest) => void) => void;
export const completeProtect: (id: number, ok: boolean) => void;
