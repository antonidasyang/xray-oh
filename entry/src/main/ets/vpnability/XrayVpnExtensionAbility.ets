import VpnExtensionAbility from '@ohos.app.ability.VpnExtensionAbility';
import { vpnExtension } from '@kit.NetworkKit';
import commonEventManager from '@ohos.commonEventManager';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@ohos.base';
import xray, { ProtectRequest } from 'libxraybridge.so';

import {
  EV_COMMAND_STOP, EV_STATE, EV_LOG, EV_HEARTBEAT, Phase, StatePayload, HeartbeatPayload,
} from '../service/CommonEvents';
import {
  buildXrayConfig, BuiltConfig, TUN_MTU, TUN_V4, TUN_V4_PREFIX, TUN_DNS_V4, TUN_V6, TUN_V6_PREFIX,
} from '../service/XrayConfig';
import { logger } from '../util/Logger';

const log = logger('XrayVpnAbility');
const ABILITY_NAME = 'XrayVpnExtensionAbility';
const HEARTBEAT_MS = 2000;

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => { setTimeout(resolve, ms); });
}

// Runs in its own process: owns the VpnConnection and the Xray instance in
// libxray.so. Started by VpnController with the config in the Want; stopped by
// EV_COMMAND_STOP. State, logs and a heartbeat go back as CommonEvents.
export default class XrayVpnExtensionAbility extends VpnExtensionAbility {
  private connection?: vpnExtension.VpnConnection;
  private subscriber?: commonEventManager.CommonEventSubscriber;
  private heartbeatTimer: number = -1;
  private bundleName: string = '';
  private phase: Phase = 'DISCONNECTED';
  private stopping: boolean = false;

  async onCreate(want: Want): Promise<void> {
    this.bundleName = want.bundleName ?? '';
    log.info('onCreate', `xray ${xray.version()}`);
    this.connection = vpnExtension.createVpnConnection(this.context);
    await this.subscribeCommands();
    this.startHeartbeat();

    const params = want.parameters ?? ({} as Record<string, Object>);
    const configText: string = (params['config'] as string) ?? '';
    if (!configText) {
      this.setPhase('ERROR', '没有收到配置');
      this.terminate();
      return;
    }
    await this.startTunnel(configText);
  }

  async onDestroy(): Promise<void> {
    log.info('onDestroy');
    this.stopHeartbeat();
    await this.shutdown();
    if (this.subscriber) {
      await commonEventManager.unsubscribe(this.subscriber);
      this.subscriber = undefined;
    }
  }

  // ---------- commands ----------

  private async subscribeCommands(): Promise<void> {
    const info: commonEventManager.CommonEventSubscribeInfo = {
      events: [EV_COMMAND_STOP],
      publisherBundleName: this.bundleName,
    };
    this.subscriber = await commonEventManager.createSubscriber(info);
    commonEventManager.subscribe(this.subscriber,
      (err: BusinessError, data: commonEventManager.CommonEventData): void => {
        if (err) {
          log.error('subscribe failed', err);
          return;
        }
        if (data.event === EV_COMMAND_STOP) {
          this.stopAndExit().catch((e: Object): void => log.error('stop failed', e));
        }
      });
  }

  // ---------- tunnel ----------

  private async startTunnel(configText: string): Promise<void> {
    this.setPhase('CONNECTING', '正在启动');
    let built: BuiltConfig;
    try {
      built = buildXrayConfig(configText);
    } catch (e) {
      this.setPhase('ERROR', (e as Error).message);
      this.terminate();
      return;
    }
    for (const w of built.warnings) {
      this.emitLog(`[警告] ${w}`);
    }

    xray.setLogListener((line: string): void => this.emitLog(line));
    // Every socket Xray opens comes here first; unprotected it would loop into the VPN.
    xray.setProtectHandler((req: ProtectRequest): void => {
      const conn = this.connection;
      if (!conn) {
        xray.completeProtect(req.id, false);
        return;
      }
      conn.protect(req.fd).then((): void => {
        xray.completeProtect(req.id, true);
      }).catch((e: BusinessError): void => {
        log.error(`protect(${req.fd}) failed`, e);
        xray.completeProtect(req.id, false);
      });
    });

    const fd = await this.createTun();
    if (fd < 0) {
      this.setPhase('ERROR', '无法建立 VPN 网卡');
      await this.shutdown();
      this.terminate();
      return;
    }

    const err = await xray.start(built.json, fd, this.context.filesDir);
    if (err) {
      this.setPhase('ERROR', err);
      await this.shutdown();
      this.terminate();
      return;
    }
    this.setPhase('CONNECTED', `Xray ${xray.version()}`);
  }

  private async createTun(): Promise<number> {
    const v4: vpnExtension.LinkAddress = {
      address: { address: TUN_V4, family: 1 },
      prefixLength: TUN_V4_PREFIX,
    };
    const v6: vpnExtension.LinkAddress = {
      address: { address: TUN_V6, family: 2 },
      prefixLength: TUN_V6_PREFIX,
    };
    const config: vpnExtension.VpnConfig = {
      addresses: [v4, v6],
      // The interface must be named 'vpn-tun', or the routes silently do nothing.
      routes: [this.defaultRoute(false), this.defaultRoute(true)],
      dnsAddresses: [TUN_DNS_V4],
      mtu: TUN_MTU,
      isIPv4Accepted: true,
      isIPv6Accepted: true,
      isInternal: false,
      isBlocking: false,
      trustedApplications: [],
      blockedApplications: [],
    };
    // A VPN left from an earlier instance can make create() fail: reset and retry.
    for (let attempt = 1; attempt <= 3; attempt++) {
      if (attempt > 1) {
        await this.resetConnection();
      }
      const conn = this.connection;
      if (!conn) return -1;
      try {
        const fd = await conn.create(config);
        log.info('VpnConnection.create', `fd=${fd} attempt=${attempt}`);
        return fd;
      } catch (e) {
        log.error(`VpnConnection.create failed (attempt ${attempt})`, e as Object);
        await sleep(1000 * attempt);
      }
    }
    return -1;
  }

  private defaultRoute(ipv6: boolean): vpnExtension.RouteInfo {
    const route: vpnExtension.RouteInfo = {
      interface: 'vpn-tun',
      destination: {
        address: { address: ipv6 ? '::' : '0.0.0.0', family: ipv6 ? 2 : 1 },
        prefixLength: 0,
      },
      gateway: { address: ipv6 ? '::' : '0.0.0.0', family: ipv6 ? 2 : 1 },
      hasGateway: false,
      isDefaultRoute: true,
    };
    return route;
  }

  private async resetConnection(): Promise<void> {
    if (this.connection) {
      try {
        await this.connection.destroy();
      } catch (e) {
        log.warn('VpnConnection.destroy failed', e as Object);
      }
    }
    this.connection = vpnExtension.createVpnConnection(this.context);
  }

  // Stops Xray, then the VPN. Xray goes first: its sockets must be closed while
  // the protect handler can still answer.
  private async shutdown(): Promise<void> {
    if (this.stopping) return;
    this.stopping = true;
    try {
      if (xray.isRunning()) {
        const err = await xray.stop();
        if (err) log.warn('xray stop', err);
      }
      if (this.connection) {
        try {
          await this.connection.destroy();
        } catch (e) {
          log.warn('VpnConnection.destroy failed', e as Object);
        }
        this.connection = undefined;
      }
    } finally {
      this.stopping = false;
    }
  }

  private async stopAndExit(): Promise<void> {
    this.setPhase('STOPPING', '正在断开');
    await this.shutdown();
    this.setPhase('DISCONNECTED', '');
    this.terminate();
  }

  // VpnExtensionContext has no terminateSelf(); stop ourselves by Want.
  private terminate(): void {
    const want: Want = { bundleName: this.bundleName, abilityName: ABILITY_NAME };
    vpnExtension.stopVpnExtensionAbility(want).catch((e: Object): void => {
      log.warn('stopVpnExtensionAbility(self) failed', e);
    });
  }

  // ---------- events to the UI ----------

  private setPhase(phase: Phase, info: string): void {
    this.phase = phase;
    log.info('phase', phase, info);
    const payload: StatePayload = { phase, info };
    this.publish(EV_STATE, JSON.stringify(payload));
  }

  private emitLog(line: string): void {
    this.publish(EV_LOG, line);
  }

  private startHeartbeat(): void {
    this.stopHeartbeat();
    this.heartbeatTimer = setInterval((): void => {
      const payload: HeartbeatPayload = { phase: this.phase, version: xray.version() };
      this.publish(EV_HEARTBEAT, JSON.stringify(payload));
    }, HEARTBEAT_MS);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  private publish(event: string, data: string): void {
    const opts: commonEventManager.CommonEventPublishData = { data, bundleName: this.bundleName };
    commonEventManager.publish(event, opts, (_err: BusinessError): void => { /* best effort */ });
  }
}
