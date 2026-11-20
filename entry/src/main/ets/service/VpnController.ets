import { vpnExtension } from '@kit.NetworkKit';
import commonEventManager from '@ohos.commonEventManager';
import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@ohos.base';

import {
  EV_COMMAND_STOP, EV_STATE, EV_LOG, EV_HEARTBEAT, Phase, StatePayload, HeartbeatPayload,
} from './CommonEvents';
import { logger } from '../util/Logger';

const log = logger('VpnController');
const ABILITY_NAME = 'XrayVpnExtensionAbility';
const MAX_LOG_LINES = 500;
// The extension beats every 2 s; this long without one means it is gone.
const HEARTBEAT_TIMEOUT_MS = 10000;

// Observable state the page binds to through AppStorage.
export const KEY_PHASE = 'vpnPhase';
export const KEY_INFO = 'vpnInfo';
export const KEY_LOGS = 'vpnLogs';
export const KEY_VERSION = 'xrayVersion';

// Runs in the UI process: starts / stops XrayVpnExtensionAbility and mirrors its
// CommonEvents into AppStorage.
class VpnControllerImpl {
  private context?: common.UIAbilityContext;
  private subscriber?: commonEventManager.CommonEventSubscriber;
  private bundleName: string = '';
  private lastHeartbeatAt: number = 0;
  private watchdog: number = -1;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    this.bundleName = context.abilityInfo.bundleName;
    AppStorage.setOrCreate<Phase>(KEY_PHASE, 'DISCONNECTED');
    AppStorage.setOrCreate<string>(KEY_INFO, '');
    AppStorage.setOrCreate<string[]>(KEY_LOGS, []);
    AppStorage.setOrCreate<string>(KEY_VERSION, '');
    if (this.subscriber) return;

    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [EV_STATE, EV_LOG, EV_HEARTBEAT],
      publisherBundleName: this.bundleName,
    };
    this.subscriber = await commonEventManager.createSubscriber(info);
    commonEventManager.subscribe(this.subscriber,
      (err: BusinessError, data: commonEventManager.CommonEventData): void => {
        if (err) {
          log.error('subscribe failed', err);
          return;
        }
        this.onEvent(data);
      });

    this.watchdog = setInterval((): void => this.checkHeartbeat(), 3000);
  }

  async dispose(): Promise<void> {
    if (this.watchdog !== -1) {
      clearInterval(this.watchdog);
      this.watchdog = -1;
    }
    if (this.subscriber) {
      await commonEventManager.unsubscribe(this.subscriber);
      this.subscriber = undefined;
    }
  }

  async connect(config: string): Promise<void> {
    if (!this.context) throw new Error('VpnController not initialised');
    const phase = AppStorage.get<Phase>(KEY_PHASE);
    if (phase === 'CONNECTED' || phase === 'CONNECTING') {
      await this.disconnect();
      await new Promise<void>((r: () => void): void => { setTimeout(r, 800); });
    }
    this.setState('CONNECTING', '正在启动 VPN 扩展');
    this.lastHeartbeatAt = Date.now();
    // The extension is another process and preferences are not shared across
    // processes, so the config travels in the Want.
    const params: Record<string, Object> = { 'config': config };
    const want: Want = { bundleName: this.bundleName, abilityName: ABILITY_NAME, parameters: params };
    try {
      await vpnExtension.startVpnExtensionAbility(want);
    } catch (e) {
      const err = e as BusinessError;
      log.error('startVpnExtensionAbility failed', err);
      this.setState('ERROR', `无法启动 VPN：${err.message ?? String(err)}`);
    }
  }

  async disconnect(): Promise<void> {
    this.setState('STOPPING', '正在断开');
    const opts: commonEventManager.CommonEventPublishData = { bundleName: this.bundleName };
    try {
      await new Promise<void>((resolve: () => void, reject: (e: BusinessError) => void): void => {
        commonEventManager.publish(EV_COMMAND_STOP, opts, (err: BusinessError): void => {
          if (err) reject(err); else resolve();
        });
      });
    } catch (e) {
      log.warn('publish stop failed', e as Object);
    }
    // If the extension is wedged it never answers the command: give it a moment, then stop it.
    setTimeout((): void => {
      if (AppStorage.get<Phase>(KEY_PHASE) !== 'STOPPING') return;
      const want: Want = { bundleName: this.bundleName, abilityName: ABILITY_NAME };
      vpnExtension.stopVpnExtensionAbility(want).catch((e: Object): void => log.warn('stop ability failed', e));
      this.setState('DISCONNECTED', '');
    }, 5000);
  }

  clearLogs(): void {
    AppStorage.set<string[]>(KEY_LOGS, []);
  }

  private onEvent(data: commonEventManager.CommonEventData): void {
    this.lastHeartbeatAt = Date.now();
    if (data.event === EV_LOG) {
      this.appendLog(data.data ?? '');
      return;
    }
    try {
      if (data.event === EV_STATE) {
        const p = JSON.parse(data.data ?? '{}') as StatePayload;
        this.setState(p.phase, p.info);
        if (p.phase === 'ERROR' && p.info) this.appendLog(`[错误] ${p.info}`);
      } else if (data.event === EV_HEARTBEAT) {
        const p = JSON.parse(data.data ?? '{}') as HeartbeatPayload;
        AppStorage.set<string>(KEY_VERSION, p.version);
        const shown = AppStorage.get<Phase>(KEY_PHASE);
        // Resync after the UI was restarted while the tunnel kept running.
        if (shown !== p.phase && shown !== 'STOPPING') this.setState(p.phase, AppStorage.get<string>(KEY_INFO) ?? '');
      }
    } catch (e) {
      log.warn('bad event payload', e as Object);
    }
  }

  private checkHeartbeat(): void {
    const phase = AppStorage.get<Phase>(KEY_PHASE);
    if (phase !== 'CONNECTED' && phase !== 'CONNECTING') return;
    if (Date.now() - this.lastHeartbeatAt > HEARTBEAT_TIMEOUT_MS) {
      this.setState('ERROR', 'VPN 扩展已退出（可能被系统结束）');
    }
  }

  private setState(phase: Phase, info: string): void {
    AppStorage.set<Phase>(KEY_PHASE, phase);
    AppStorage.set<string>(KEY_INFO, info);
  }

  private appendLog(line: string): void {
    const logs = AppStorage.get<string[]>(KEY_LOGS) ?? [];
    const next = logs.length >= MAX_LOG_LINES ? logs.slice(logs.length - MAX_LOG_LINES + 1) : logs.slice();
    next.push(line);
    AppStorage.set<string[]>(KEY_LOGS, next);
  }
}

export const VpnController = new VpnControllerImpl();
