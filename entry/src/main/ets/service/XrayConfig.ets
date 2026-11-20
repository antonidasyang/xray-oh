// Turns the user's Xray JSON config into one that serves the HarmonyOS VPN:
//   - a "tun" inbound (added if missing) reads the VPN's TUN descriptor;
//   - DNS sent to the VPN's resolver address (any port 53 from the TUN) is
//     handed to Xray's own DNS through a "dns" outbound (added if missing);
//   - without a "dns" section, public resolvers are used, reached the same way
//     as other traffic (normally through the proxy).

export const TUN_TAG = 'tun-in';
export const DNS_OUT_TAG = 'dns-out';
export const TUN_MTU = 1500;
export const TUN_V4 = '172.19.0.1';
export const TUN_V4_PREFIX = 30;
export const TUN_DNS_V4 = '172.19.0.2';
export const TUN_V6 = 'fdfe:dcba:9876::1';
export const TUN_V6_PREFIX = 126;

export interface BuiltConfig {
  json: string;
  warnings: string[];
}

function asArray(v: Object | undefined): Object[] {
  return Array.isArray(v) ? (v as Object[]) : [];
}

function asRecord(v: Object | undefined): Record<string, Object> {
  if (v !== undefined && v !== null && typeof v === 'object' && !Array.isArray(v)) {
    return v as Record<string, Object>;
  }
  const empty: Record<string, Object> = {};
  return empty;
}

function str(v: Object | undefined): string {
  return typeof v === 'string' ? (v as string) : '';
}

function isIpLiteral(host: string): boolean {
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(host) || host.includes(':');
}

// Server addresses of an outbound: settings.vnext[].address, settings.servers[].address
// and settings.address (flat VLESS / VMess form).
function serverAddresses(outbound: Record<string, Object>): string[] {
  const settings = asRecord(outbound['settings']);
  const out: string[] = [];
  const own = str(settings['address']);
  if (own) out.push(own);
  for (const list of [asArray(settings['vnext']), asArray(settings['servers'])]) {
    for (const s of list) {
      const a = str(asRecord(s)['address']);
      if (a) out.push(a);
    }
  }
  return out;
}

function makeTunInbound(): Record<string, Object> {
  const settings: Record<string, Object> = { 'name': 'vpn-tun', 'mtu': TUN_MTU };
  const sniffing: Record<string, Object> = {
    'enabled': true,
    'destOverride': ['http', 'tls', 'quic'],
    // Route by the sniffed domain but keep dialing the IP the app chose.
    'routeOnly': true,
  };
  const inbound: Record<string, Object> = {
    'tag': TUN_TAG,
    'protocol': 'tun',
    'settings': settings,
    'sniffing': sniffing,
  };
  return inbound;
}

export function buildXrayConfig(userJson: string): BuiltConfig {
  let parsed: Object;
  try {
    parsed = JSON.parse(userJson) as Object;
  } catch (e) {
    throw new Error(`配置不是合法的 JSON：${(e as Error).message}`);
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('配置必须是一个 JSON 对象');
  }
  const cfg = parsed as Record<string, Object>;
  const warnings: string[] = [];

  // --- TUN inbound ---
  const inbounds = asArray(cfg['inbounds']);
  let tunTag = '';
  for (const item of inbounds) {
    const ib = asRecord(item);
    if (str(ib['protocol']) === 'tun') {
      tunTag = str(ib['tag']);
      if (!tunTag) {
        ib['tag'] = TUN_TAG;
        tunTag = TUN_TAG;
      }
      break;
    }
  }
  if (!tunTag) {
    inbounds.push(makeTunInbound());
    tunTag = TUN_TAG;
  }
  cfg['inbounds'] = inbounds;

  // --- DNS outbound ---
  const outbounds = asArray(cfg['outbounds']);
  if (outbounds.length === 0) {
    throw new Error('配置里没有 outbounds');
  }
  let dnsTag = '';
  for (const item of outbounds) {
    const ob = asRecord(item);
    if (str(ob['protocol']) === 'dns') {
      dnsTag = str(ob['tag']);
      if (!dnsTag) {
        ob['tag'] = DNS_OUT_TAG;
        dnsTag = DNS_OUT_TAG;
      }
      break;
    }
  }
  if (!dnsTag) {
    const dnsOut: Record<string, Object> = { 'tag': DNS_OUT_TAG, 'protocol': 'dns' };
    outbounds.push(dnsOut);
    dnsTag = DNS_OUT_TAG;
  }
  cfg['outbounds'] = outbounds;

  // --- route the TUN's DNS into Xray ---
  const routing = asRecord(cfg['routing']);
  const rules = asArray(routing['rules']);
  const dnsRule: Record<string, Object> = {
    'type': 'field',
    'inboundTag': [tunTag],
    'port': '53',
    'outboundTag': dnsTag,
  };
  rules.unshift(dnsRule);
  routing['rules'] = rules;
  cfg['routing'] = routing;

  if (cfg['dns'] === undefined) {
    const dns: Record<string, Object> = { 'servers': ['1.1.1.1', '8.8.8.8'] };
    cfg['dns'] = dns;
    warnings.push('配置没有 dns 段，已使用 1.1.1.1 / 8.8.8.8');
  }

  // A proxy server given by name is resolved with the system resolver, whose
  // queries go into this same VPN; until that is handled, ask for an IP.
  for (const item of outbounds) {
    for (const host of serverAddresses(asRecord(item))) {
      if (!isIpLiteral(host)) {
        warnings.push(`服务器地址 ${host} 是域名；目前请改用 IP，否则解析它的查询会进入 VPN 自身`);
      }
    }
  }

  return { json: JSON.stringify(cfg), warnings };
}
