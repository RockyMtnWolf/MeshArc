import { http } from '@kit.NetworkKit';

export const PROJECT_ENGINE_VERSION: string = '1.86.5';
export const PROJECT_GO_VERSION: string = '1.24.5';

interface GithubRelease {
  tag_name: string;
  draft: boolean;
  prerelease: boolean;
  html_url: string;
}

interface GithubObject {
  type: string;
  sha: string;
}

interface GithubReference {
  object: GithubObject;
}

export interface CoreUpdateCandidate {
  version: string;
  tag: string;
  commit: string;
  goVersion: string;
  releaseURL: string;
  sourceURL: string;
  newer: boolean;
  compatibleWithCurrentToolchain: boolean;
}

export function compareCoreVersions(first: string, second: string): number {
  if (!/^\d+\.\d+(?:\.\d+)?$/.test(first) || !/^\d+\.\d+(?:\.\d+)?$/.test(second)) {
    throw new Error('Invalid version');
  }
  const firstParts: number[] = first.split('.').map((part: string) => Number(part));
  const secondParts: number[] = second.split('.').map((part: string) => Number(part));
  for (let index: number = 0; index < 3; index++) {
    const difference: number = (firstParts[index] ?? 0) - (secondParts[index] ?? 0);
    if (difference !== 0) {
      return difference > 0 ? 1 : -1;
    }
  }
  return 0;
}

export class CoreUpdateGateway {
  async checkLatest(): Promise<CoreUpdateCandidate> {
    const release = JSON.parse(await this.request('https://api.github.com/repos/tailscale/tailscale/releases/latest')) as GithubRelease;
    if (release.draft || release.prerelease || !/^v\d+\.\d+\.\d+$/.test(release.tag_name)) {
      throw new Error('Upstream response is not a stable version');
    }
    const expectedReleaseURL: string = `https://github.com/tailscale/tailscale/releases/tag/${release.tag_name}`;
    if (release.html_url !== expectedReleaseURL) {
      throw new Error('Unexpected upstream release URL');
    }
    let reference = JSON.parse(await this.request(
      `https://api.github.com/repos/tailscale/tailscale/git/ref/tags/${release.tag_name}`)) as GithubReference;
    for (let depth: number = 0; depth < 4 && reference.object.type === 'tag'; depth++) {
      if (!/^[a-f0-9]{40}$/.test(reference.object.sha)) {
        throw new Error('Invalid upstream tag identity');
      }
      reference = JSON.parse(await this.request(
        `https://api.github.com/repos/tailscale/tailscale/git/tags/${reference.object.sha}`)) as GithubReference;
    }
    if (reference.object.type !== 'commit' || !/^[a-f0-9]{40}$/.test(reference.object.sha)) {
      throw new Error('Upstream tag did not resolve to an immutable commit');
    }
    const commit: string = reference.object.sha;
    const goMod: string = await this.request(`https://raw.githubusercontent.com/tailscale/tailscale/${commit}/go.mod`);
    const goVersionMatch: RegExpMatchArray | null = goMod.match(/^go\s+(\d+\.\d+(?:\.\d+)?)\s*$/m);
    if (goVersionMatch === null) {
      throw new Error('Upstream Go toolchain requirement is missing');
    }
    const version: string = release.tag_name.substring(1);
    return {
      version: version,
      tag: release.tag_name,
      commit: commit,
      goVersion: goVersionMatch[1],
      releaseURL: expectedReleaseURL,
      sourceURL: `https://github.com/tailscale/tailscale/archive/${commit}.tar.gz`,
      newer: compareCoreVersions(version, PROJECT_ENGINE_VERSION) > 0,
      compatibleWithCurrentToolchain: compareCoreVersions(PROJECT_GO_VERSION, goVersionMatch[1]) >= 0
    };
  }

  exportBuildRequest(candidate: CoreUpdateCandidate): string {
    if (!/^\d+\.\d+\.\d+$/.test(candidate.version) ||
      candidate.tag !== `v${candidate.version}` || !/^[a-f0-9]{40}$/.test(candidate.commit) ||
      candidate.sourceURL !== `https://github.com/tailscale/tailscale/archive/${candidate.commit}.tar.gz` ||
      !/^\d+\.\d+(?:\.\d+)?$/.test(candidate.goVersion)) {
      throw new Error('Invalid core build request');
    }
    return JSON.stringify({
      schemaVersion: 1,
      engine: 'tailscale',
      version: candidate.version,
      commit: candidate.commit,
      sourceURL: candidate.sourceURL,
      minimumGoVersion: candidate.goVersion,
      goos: 'openharmony',
      goarch: 'arm64',
      buildmode: 'c-shared',
      patches: ['ohos-go-interface-resources.patch', 'tailscale-ohos.patch'],
      workflowStatus: 'requires_on_device_builder_and_signer',
      allowProductionReplacement: false,
      installRequiresUserConfirmation: true,
      secretsIncluded: false
    }, null, 2);
  }

  private async request(url: string): Promise<string> {
    const request: http.HttpRequest = http.createHttp();
    let deadline: number = -1;
    try {
      const response = await new Promise<http.HttpResponse>((resolve, reject) => {
        deadline = setTimeout(() => reject(new Error('Update request timed out')), 15000);
        request.request(url, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.STRING,
          connectTimeout: 5000,
          readTimeout: 10000,
          header: { 'Accept': 'application/vnd.github+json', 'User-Agent': 'MeshArc-Core-Update' }
        }).then(resolve, reject);
      });
      if (response.responseCode !== 200) {
        throw new Error(`Upstream HTTP ${response.responseCode}`);
      }
      const body: string = response.result as string;
      if (typeof body !== 'string' || body.length > 262144) {
        throw new Error('Unexpected upstream response size');
      }
      return body;
    } finally {
      if (deadline >= 0) {
        clearTimeout(deadline);
      }
      request.destroy();
    }
  }
}
