export interface FrpProxy {
  name: string;
  type: 'tcp' | 'udp';
  localIP: string;
  localPort: number;
  remotePort: number;
}

export interface FrpConfig {
  serverAddr: string;
  serverPort: number;
  token: string;
  proxies: FrpProxy[];
  user?: string;
  tlsEnable?: boolean;
  tlsDisableCustomTLSFirstByte?: boolean;
}

export interface FrpParseResult {
  config: FrpConfig;
  hasUnknownFields: boolean;
  warnings: string[];
  rawText?: string;
}

export function emptyFrpConfig(): FrpConfig {
  return { serverAddr: '', serverPort: 7000, token: '', proxies: [] };
}

function parseString(value: string, line: number): string {
  if (value.length < 2 || value[0] !== '"' || value[value.length - 1] !== '"') {
    throw new Error(`第 ${line} 行：文本字段必须使用双引号`);
  }
  try {
    return JSON.parse(value) as string;
  } catch (_error) {
    throw new Error(`第 ${line} 行：字符串格式错误`);
  }
}

function parseInteger(value: string, line: number): number {
  if (!/^\d+$/.test(value)) {
    throw new Error(`第 ${line} 行：端口必须是整数`);
  }
  const port: number = Number(value);
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error(`第 ${line} 行：端口须在 0–65535`);
  }
  return port;
}

function stripInlineComment(line: string): string {
  let inString: boolean = false;
  let escaped: boolean = false;
  for (let index: number = 0; index < line.length; index++) {
    const character: string = line[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (character === '\\') {
        escaped = true;
      } else if (character === '"') {
        inString = false;
      }
    } else if (character === '"') {
      inString = true;
    } else if (character === '#') {
      return line.substring(0, index).trimEnd();
    }
  }
  return line.trimEnd();
}

export function parseFrpToml(text: string): FrpParseResult {
  const config: FrpConfig = emptyFrpConfig();
  const warnings: string[] = [];
  const seen: Set<string> = new Set<string>();
  let section: 'root' | 'proxy' | 'auth' | 'transportTls' | 'unknown' = 'root';
  let proxy: FrpProxy | undefined = undefined;
  let proxyIndex: number = -1;
  let unknown: boolean = false;
  const lines: string[] = text.split(/\r?\n/);
  for (let index: number = 0; index < lines.length; index++) {
    const raw: string = stripInlineComment(lines[index]).trim();
    if (raw.length === 0 || raw.startsWith('#')) {
      continue;
    }
    if (raw === '[[proxies]]') {
      section = 'proxy';
      proxyIndex++;
      proxy = { name: '', type: 'tcp', localIP: '127.0.0.1', localPort: 0, remotePort: 0 };
      config.proxies.push(proxy);
      continue;
    }
    if (raw === '[auth]') {
      section = 'auth';
      proxy = undefined;
      continue;
    }
    if (raw === '[transport.tls]') {
      section = 'transportTls';
      proxy = undefined;
      continue;
    }
    if (raw.startsWith('[') && raw.endsWith(']')) {
      section = 'unknown';
      proxy = undefined;
      unknown = true;
      warnings.push(`第 ${index + 1} 行包含高级表 ${raw}`);
      continue;
    }
    const match: RegExpMatchArray | null = raw.match(/^([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(.*?)\s*$/);
    if (match === null) {
      throw new Error(`第 ${index + 1} 行：TOML 字段格式无效`);
    }
    const key: string = match[1];
    const value: string = match[2];
    if (section === 'unknown') continue;
    let path: string = section === 'root' ? key : `proxies.${proxyIndex}.${key}`;
    if (section === 'auth') path = `auth.${key}`;
    if (section === 'transportTls') path = `transport.tls.${key}`;
    if (section === 'root' && key === 'token') path = 'auth.token';
    if (section === 'root' && key.startsWith('auth.')) path = key;
    if (section === 'root' && key.startsWith('transport.tls.')) path = key;
    if (seen.has(path)) {
      throw new Error(`第 ${index + 1} 行：字段重复 ${path}`);
    }
    seen.add(path);
    if (section === 'root') {
      if (key === 'serverAddr') {
        config.serverAddr = parseString(value, index + 1);
      } else if (key === 'token') {
        config.token = parseString(value, index + 1);
      } else if (key === 'serverPort') {
        config.serverPort = parseInteger(value, index + 1);
      } else if (key === 'user') {
        config.user = parseString(value, index + 1);
      } else if (key === 'auth.token') {
        config.token = parseString(value, index + 1);
      } else if (key === 'transport.tls.enable') {
        config.tlsEnable = parseBoolean(value, index + 1);
      } else if (key === 'transport.tls.disableCustomTLSFirstByte') {
        config.tlsDisableCustomTLSFirstByte = parseBoolean(value, index + 1);
      } else {
        unknown = true;
        warnings.push(`第 ${index + 1} 行包含高级字段 ${key}`);
      }
    } else if (section === 'auth') {
      if (key === 'token') {
        config.token = parseString(value, index + 1);
      } else {
        unknown = true;
        warnings.push(`第 ${index + 1} 行包含高级字段 auth.${key}`);
      }
    } else if (section === 'transportTls') {
      if (key === 'enable') {
        config.tlsEnable = parseBoolean(value, index + 1);
      } else if (key === 'disableCustomTLSFirstByte') {
        config.tlsDisableCustomTLSFirstByte = parseBoolean(value, index + 1);
      } else {
        unknown = true;
        warnings.push(`第 ${index + 1} 行包含高级字段 transport.tls.${key}`);
      }
    } else if (proxy !== undefined) {
      if (key === 'name' || key === 'type' || key === 'localIP') {
        const parsed: string = parseString(value, index + 1);
        if (key === 'name') proxy.name = parsed;
        else if (key === 'localIP') proxy.localIP = parsed;
        else if (parsed === 'tcp' || parsed === 'udp') proxy.type = parsed;
        else throw new Error(`第 ${index + 1} 行：代理类型只支持 tcp 或 udp`);
      } else if (key === 'localPort') {
        proxy.localPort = parseInteger(value, index + 1);
      } else if (key === 'remotePort') {
        proxy.remotePort = parseInteger(value, index + 1);
      } else {
        unknown = true;
        warnings.push(`第 ${index + 1} 行包含高级代理字段 ${key}`);
      }
    }
  }
  return {
    config: config,
    hasUnknownFields: unknown,
    warnings: warnings,
    rawText: unknown ? text : undefined
  };
}

function parseBoolean(value: string, line: number): boolean {
  if (value === 'true') return true;
  if (value === 'false') return false;
  throw new Error(`第 ${line} 行：布尔字段必须是 true 或 false`);
}

function quote(value: string): string {
  return JSON.stringify(value);
}

export function serializeFrpToml(config: FrpConfig): string {
  const lines: string[] = [`serverAddr = ${quote(config.serverAddr)}`, `serverPort = ${config.serverPort}`];
  if (config.user !== undefined) lines.push(`user = ${quote(config.user)}`);
  lines.push('', '[auth]', `token = ${quote(config.token)}`);
  if (config.tlsEnable !== undefined || config.tlsDisableCustomTLSFirstByte !== undefined) {
    lines.push('', '[transport.tls]');
    if (config.tlsEnable !== undefined) lines.push(`enable = ${config.tlsEnable}`);
    if (config.tlsDisableCustomTLSFirstByte !== undefined) {
      lines.push(`disableCustomTLSFirstByte = ${config.tlsDisableCustomTLSFirstByte}`);
    }
  }
  for (const proxy of config.proxies) {
    lines.push('', '[[proxies]]', `name = ${quote(proxy.name)}`, `type = ${quote(proxy.type)}`,
      `localIP = ${quote(proxy.localIP)}`, `localPort = ${proxy.localPort}`, `remotePort = ${proxy.remotePort}`);
  }
  return `${lines.join('\n')}\n`;
}

export function validateFrpConfig(config: FrpConfig): string[] {
  const errors: string[] = [];
  if (config.serverAddr.trim().length === 0) errors.push('请填写服务器地址');
  if (!Number.isInteger(config.serverPort) || config.serverPort < 1 || config.serverPort > 65535) {
    errors.push('服务器端口须在 1–65535');
  }
  const names: Set<string> = new Set<string>();
  for (const proxy of config.proxies) {
    if (proxy.name.trim().length === 0 || names.has(proxy.name)) errors.push('代理名称不能为空且不能重复');
    names.add(proxy.name);
    if (proxy.localIP.trim().length === 0) errors.push(`${proxy.name || '代理'}：本机地址不能为空`);
    if (!Number.isInteger(proxy.localPort) || proxy.localPort < 1 || proxy.localPort > 65535 ||
      !Number.isInteger(proxy.remotePort) || proxy.remotePort < 1 || proxy.remotePort > 65535) {
      errors.push(`${proxy.name || '代理'}：本机端口和公网端口须在 1–65535`);
    }
  }
  if (config.proxies.length === 0) errors.push('至少添加一条代理映射');
  return errors;
}
