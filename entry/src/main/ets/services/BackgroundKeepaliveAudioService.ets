import { audio } from '@kit.AudioKit';

export interface BackgroundKeepaliveAudioState {
  active: boolean;
  error: string;
}

const SAMPLE_RATE: number = 22050;
const NOTES_HZ: number[] = [261.63, 329.63, 392.00, 329.63, 293.66, 349.23, 440.00, 349.23];

export class BackgroundKeepaliveAudioService {
  private renderer?: audio.AudioRenderer;
  private sampleCursor: number = 0;
  private error: string = '';
  private readonly writeCallback = (buffer: ArrayBuffer): audio.AudioDataCallbackResult => {
    const samples: Int16Array = new Int16Array(buffer);
    const noteLength: number = SAMPLE_RATE * 0.45;
    for (let index: number = 0; index < samples.length; index++) {
      const noteIndex: number = Math.floor(this.sampleCursor / noteLength) % NOTES_HZ.length;
      const notePosition: number = (this.sampleCursor % noteLength) / noteLength;
      const edge: number = Math.min(1, notePosition * 16, (1 - notePosition) * 16);
      const phase: number = 2 * Math.PI * NOTES_HZ[noteIndex] * this.sampleCursor / SAMPLE_RATE;
      samples[index] = Math.round(Math.sin(phase) * edge * 7000);
      this.sampleCursor++;
    }
    return audio.AudioDataCallbackResult.VALID;
  };

  async start(): Promise<BackgroundKeepaliveAudioState> {
    if (this.getState().active) {
      return this.getState();
    }
    try {
      const renderer: audio.AudioRenderer = await audio.createAudioRenderer({
        streamInfo: {
          samplingRate: SAMPLE_RATE,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_MUSIC, rendererFlags: 0 }
      });
      this.renderer = renderer;
      this.sampleCursor = 0;
      renderer.on('writeData', this.writeCallback);
      await renderer.setVolume(0.12);
      await renderer.start();
      if (renderer.state !== audio.AudioState.STATE_RUNNING) {
        throw new Error('AudioRenderer 未进入 running 状态。');
      }
      this.error = '';
      return this.getState();
    } catch (error) {
      const failure = error as Error;
      const originalMessage: string = failure.message ?? 'AudioRenderer 启动失败。';
      try {
        await this.releaseRenderer();
        this.error = originalMessage;
      } catch (cleanupError) {
        this.error = `${originalMessage}；清理失败：${this.errorMessage(cleanupError)}`;
      }
      return this.getState();
    }
  }

  async stop(): Promise<BackgroundKeepaliveAudioState> {
    try {
      await this.releaseRenderer();
      this.error = '';
    } catch (error) {
      const failure = error as Error;
      this.error = failure.message ?? 'AudioRenderer 释放失败。';
    }
    return this.getState();
  }

  getState(): BackgroundKeepaliveAudioState {
    return { active: this.renderer?.state === audio.AudioState.STATE_RUNNING, error: this.error };
  }

  private async releaseRenderer(): Promise<void> {
    const renderer: audio.AudioRenderer | undefined = this.renderer;
    this.renderer = undefined;
    if (renderer === undefined) {
      return;
    }
    let cleanupError: string = '';
    try {
      renderer.off('writeData', this.writeCallback);
    } catch (error) {
      cleanupError = this.errorMessage(error);
    }
    try {
      if (renderer.state === audio.AudioState.STATE_RUNNING || renderer.state === audio.AudioState.STATE_PAUSED) {
        await renderer.stop();
      }
    } catch (error) {
      if (cleanupError.length === 0) {
        cleanupError = this.errorMessage(error);
      }
    }
    try {
      await renderer.release();
    } catch (error) {
      if (cleanupError.length === 0) {
        cleanupError = this.errorMessage(error);
      }
    }
    if (cleanupError.length > 0) {
      throw new Error(cleanupError);
    }
  }

  private errorMessage(error: Object): string {
    return (error as Error).message ?? '未知音频资源错误';
  }
}
