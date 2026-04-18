import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export interface CodexPreflightResult {
  detectedVersion: string | null;
  loginStatus: 'logged-in' | 'logged-out' | 'not-installed' | 'unknown';
  meetsMinimumVersion: boolean;
  minimumVersion: string;
}

function parseCodexVersion(output: string): string | null {
  const match = output.match(/(\d+\.\d+\.\d+)/);
  return match?.[1] ?? null;
}

function compareVersions(left: string, right: string): number {
  const leftParts = left.split('.').map((part) => Number(part));
  const rightParts = right.split('.').map((part) => Number(part));
  const length = Math.max(leftParts.length, rightParts.length);

  for (let index = 0; index < length; index += 1) {
    const leftValue = leftParts[index] ?? 0;
    const rightValue = rightParts[index] ?? 0;
    if (leftValue !== rightValue) {
      return leftValue - rightValue;
    }
  }

  return 0;
}

export async function codexPreflight(minimumVersion: string): Promise<CodexPreflightResult> {
  try {
    const versionResult = await execFileAsync('codex', ['--version']);
    const versionOutput = `${versionResult.stdout}${versionResult.stderr}`;
    const detectedVersion = parseCodexVersion(versionOutput);
    const meetsMinimumVersion =
      detectedVersion !== null ? compareVersions(detectedVersion, minimumVersion) >= 0 : false;

    try {
      const loginResult = await execFileAsync('codex', ['login', 'status']);
      const loginOutput = `${loginResult.stdout}${loginResult.stderr}`;
      const loginStatus = /logged in/i.test(loginOutput) ? 'logged-in' : 'unknown';

      return {
        detectedVersion,
        loginStatus,
        meetsMinimumVersion,
        minimumVersion,
      };
    } catch (error) {
      return {
        detectedVersion,
        loginStatus: 'logged-out',
        meetsMinimumVersion,
        minimumVersion,
      };
    }
  } catch (error) {
    return {
      detectedVersion: null,
      loginStatus: 'not-installed',
      meetsMinimumVersion: false,
      minimumVersion,
    };
  }
}
