import nativeBridge from 'libtailscale_ohos.so';
import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { awaitVpnOperation } from './VpnCommandGateway';

interface ClashRepairResult {
  content: string;
  error: string;
}

export class ClashConfigRepairGateway {
  static async importAndExport(context: common.UIAbilityContext): Promise<string> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const sources: string[] = await documentPicker.select({ maxSelectNumber: 1 });
    if (sources.length === 0) return '已取消导入，原配置未修改。';
    let source: fileIo.File | undefined = undefined;
    let text: string = '';
    try {
      source = fileIo.openSync(sources[0], fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(source.fd);
      if (stat.size <= 0 || stat.size > 2 * 1024 * 1024) {
        throw new Error('配置文件须为 1 字节至 2 MiB。');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const output: Uint8Array = new Uint8Array(buffer);
      let offset: number = 0;
      while (offset < stat.size) {
        const chunk: ArrayBuffer = new ArrayBuffer(stat.size - offset);
        const count: number = fileIo.readSync(source.fd, chunk, { length: chunk.byteLength });
        if (count <= 0) throw new Error('配置文件未完整读取。');
        output.set(new Uint8Array(chunk, 0, count), offset);
        offset += count;
      }
      text = util.TextDecoder.create('utf-8', { fatal: true }).decodeWithStream(new Uint8Array(buffer));
    } finally {
      if (source !== undefined) fileIo.closeSync(source);
    }
    const result: ClashRepairResult = JSON.parse(await awaitVpnOperation(
      nativeBridge.coexistenceRepairClashConfigAsync(text), 'Clash configuration repair', 15000)) as ClashRepairResult;
    if (typeof result.content !== 'string' || typeof result.error !== 'string') {
      throw new Error('配置修补结果格式无效。');
    }
    if (result.error.length > 0) throw new Error(`无法自动修补：${result.error}`);
    const destinations: string[] = await documentPicker.save({
      newFileNames: ['MeshArc-Clash共存.yaml'], fileSuffixChoices: ['YAML|.yaml']
    });
    if (destinations.length === 0) return '已取消导出，原配置未修改。';
    if (destinations[0] === sources[0]) throw new Error('请另存为新文件，不能覆盖原配置。');
    let destination: fileIo.File | undefined = undefined;
    try {
      destination = fileIo.openSync(destinations[0],
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const bytes: Uint8Array = new util.TextEncoder().encodeInto(result.content);
      let offset: number = 0;
      while (offset < bytes.byteLength) {
        const remaining: ArrayBuffer = new ArrayBuffer(bytes.byteLength - offset);
        new Uint8Array(remaining).set(bytes.subarray(offset));
        const count: number = fileIo.writeSync(destination.fd, remaining);
        if (count <= 0) throw new Error('导出文件未完整写入。');
        offset += count;
      }
    } finally {
      if (destination !== undefined) fileIo.closeSync(destination);
    }
    return '修补副本已导出，原文件未修改。请在 ClashBox 导入并选用新文件；订阅凭据仍保留在副本中，请勿公开分享。';
  }
}
