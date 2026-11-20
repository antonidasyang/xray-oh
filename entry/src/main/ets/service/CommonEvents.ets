// Events between the UI (EntryAbility) and XrayVpnExtensionAbility, which run in
// different processes. Publishers restrict delivery to this bundle and
// subscribers accept only this bundle as publisher, so neither tunnel commands
// nor log lines (which name destinations) cross to other apps.

export const EV_COMMAND_STOP = 'com.example.xrayoh.cmd.stop';

export const EV_STATE = 'com.example.xrayoh.evt.state';
export const EV_LOG = 'com.example.xrayoh.evt.log';
// Sent every 2 s while the extension lives; silence means it was killed.
export const EV_HEARTBEAT = 'com.example.xrayoh.evt.heartbeat';

export type Phase = 'DISCONNECTED' | 'CONNECTING' | 'CONNECTED' | 'STOPPING' | 'ERROR';

export interface StatePayload {
  phase: Phase;
  info: string;
}

export interface HeartbeatPayload {
  phase: Phase;
  version: string;
}
