import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { FrpParseResult, parseFrpToml, validateFrpConfig } from './FrpConfig';
import { FrpGateway } from './FrpGateway';

export interface FrpProfile {
  id: string;
  name: string;
  toml: string;
  updatedAt: number;
}

const MAX_PROFILES: number = 32;
const MAX_PROFILE_TOML_BYTES: number = 256 * 1024;

export class FrpProfileStore {
  private static readonly FILE_NAME: string = 'frp-profiles.json';
  private static temporarySequence: number = 0;

  static load(context: common.UIAbilityContext): FrpProfile[] {
    const path: string = FrpProfileStore.path(context);
    if (FrpProfileStore.exists(path)) {
      const stored: FrpProfile[] = JSON.parse(fileIo.readTextSync(path)) as FrpProfile[];
      return FrpProfileStore.validate(stored);
    }

    const legacyToml: string = FrpGateway.load(context.filesDir);
    if (legacyToml.trim().length === 0) return [];
    let parsed: FrpParseResult;
    try {
      parsed = parseFrpToml(legacyToml);
    } catch (_error) {
      return [];
    }
    if (validateFrpConfig(parsed.config).length > 0) return [];
    const updatedAt: number = Date.now();
    const profile: FrpProfile = {
      id: `legacy-${updatedAt.toString(36)}`,
      name: '旧版配置',
      toml: legacyToml,
      updatedAt: updatedAt
    };
    FrpProfileStore.save(context, [profile]);
    return [profile];
  }

  static save(context: common.UIAbilityContext, profiles: FrpProfile[]): void {
    const validated: FrpProfile[] = FrpProfileStore.validate(profiles);
    const path: string = FrpProfileStore.path(context);
    const sequence: number = ++FrpProfileStore.temporarySequence;
    const temporaryPath: string = `${path}.${Date.now()}.${sequence}.tmp`;
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(temporaryPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const bytes: Uint8Array = new util.TextEncoder().encodeInto(JSON.stringify(validated));
      let fileOffset: number = 0;
      while (fileOffset < bytes.byteLength) {
        const chunkLength: number = Math.min(8192, bytes.byteLength - fileOffset);
        const chunk: ArrayBuffer = new ArrayBuffer(chunkLength);
        new Uint8Array(chunk).set(bytes.subarray(fileOffset, fileOffset + chunkLength));
        const written: number = fileIo.writeSync(file.fd, chunk);
        if (written <= 0) throw new Error('FRP 配置列表未完整写入');
        fileOffset += written;
      }
      fileIo.closeSync(file);
      file = undefined;
      fileIo.renameSync(temporaryPath, path);
    } catch (error) {
      if (file !== undefined) {
        try { fileIo.closeSync(file); } catch (_closeError) {}
      }
      try {
        if (fileIo.accessSync(temporaryPath)) fileIo.unlinkSync(temporaryPath);
      } catch (_cleanupError) {}
      throw new Error((error as Error).message || 'FRP 配置列表保存失败');
    }
  }

  private static validate(value: FrpProfile[]): FrpProfile[] {
    if (!Array.isArray(value) || value.length > MAX_PROFILES) {
      throw new Error(`FRP 配置数量必须在 0–${MAX_PROFILES} 之间`);
    }
    const ids: Set<string> = new Set<string>();
    const profiles: FrpProfile[] = [];
    for (const item of value) {
      if (typeof item !== 'object' || item === null) throw new Error('FRP 配置列表格式无效');
      const candidate: FrpProfile = item;
      if (typeof candidate.id !== 'string' || candidate.id.trim().length === 0 || ids.has(candidate.id) ||
        typeof candidate.name !== 'string' || candidate.name.trim().length === 0 ||
        typeof candidate.toml !== 'string' || typeof candidate.updatedAt !== 'number' ||
        !Number.isFinite(candidate.updatedAt) || candidate.updatedAt < 0) {
        throw new Error('FRP 配置项字段无效');
      }
      if (new util.TextEncoder().encodeInto(candidate.toml).byteLength > MAX_PROFILE_TOML_BYTES) {
        throw new Error('单个 FRP 配置不得超过 256 KiB');
      }
      ids.add(candidate.id);
      profiles.push({
        id: candidate.id,
        name: candidate.name,
        toml: candidate.toml,
        updatedAt: candidate.updatedAt
      });
    }
    return profiles;
  }

  private static exists(path: string): boolean {
    try {
      return fileIo.accessSync(path);
    } catch (_error) {
      return false;
    }
  }

  private static path(context: common.UIAbilityContext): string {
    return `${context.filesDir}/${FrpProfileStore.FILE_NAME}`;
  }
}
