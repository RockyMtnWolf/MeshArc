import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export interface ImportedConfigDocument {
  name: string;
  text: string;
}

const MAX_IMPORT_BYTES: number = 256 * 1024;
const READ_CHUNK_BYTES: number = 8192;

export class ConfigDocumentGateway {
  static async pickText(context: common.UIAbilityContext,
    maxBytes: number): Promise<ImportedConfigDocument | undefined> {
    if (!Number.isInteger(maxBytes) || maxBytes < 1) throw new Error('文件大小限制无效');
    const limit: number = Math.min(maxBytes, MAX_IMPORT_BYTES);
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.select({ maxSelectNumber: 1 });
    if (uris.length === 0) return undefined;

    let source: fileIo.File | undefined = undefined;
    try {
      source = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      const initialStat: fileIo.Stat = fileIo.statSync(source.fd);
      if (!initialStat.isFile() || initialStat.size < 0) {
        throw new Error('选中文件必须是普通文件');
      }
      if (initialStat.size > limit) {
        throw new Error(`配置文件不得超过 ${limit} 字节（最大 256 KiB）`);
      }

      const output: Uint8Array = new Uint8Array(initialStat.size);
      const chunk: ArrayBuffer = new ArrayBuffer(Math.min(READ_CHUNK_BYTES, Math.max(1, initialStat.size)));
      let fileOffset: number = 0;
      let outputOffset: number = 0;
      while (fileOffset < initialStat.size) {
        const length: number = Math.min(chunk.byteLength, initialStat.size - fileOffset);
        const count: number = fileIo.readSync(source.fd, chunk, { offset: fileOffset, length: length });
        if (count <= 0 || count > length) throw new Error('配置文件未完整读取');
        output.set(new Uint8Array(chunk, 0, count), outputOffset);
        fileOffset += count;
        outputOffset += count;
      }
      const finalStat: fileIo.Stat = fileIo.statSync(source.fd);
      if (finalStat.size !== initialStat.size) throw new Error('配置文件在读取期间发生变化，请重新导入');

      let text: string = '';
      try {
        text = util.TextDecoder.create('utf-8', { fatal: true }).decodeWithStream(output);
      } catch (_error) {
        throw new Error('配置文件不是有效的 UTF-8 文本');
      }
      const name: string = source.name.length > 0 ? source.name : 'frpc-config.toml';
      return { name: name, text: text };
    } finally {
      if (source !== undefined) fileIo.closeSync(source);
    }
  }
}
