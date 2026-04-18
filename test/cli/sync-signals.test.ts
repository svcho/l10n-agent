import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { chmod, cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

import { afterEach, describe, expect, it } from 'vitest';

import { stableStringify } from '../../src/utils/json.js';

const repoRoot = resolve('.');
const tsxPath = resolve('node_modules/.bin/tsx');

async function createTempProject(name: string): Promise<string> {
  const targetDir = await mkdtemp(join(tmpdir(), `l10n-agent-cli-${name}-`));
  await cp(resolve('fixtures/projects/happy-path'), targetDir, { recursive: true });

  const sourcePath = join(targetDir, 'l10n/source.en.json');
  const source = JSON.parse(await readFile(sourcePath, 'utf8')) as {
    keys: Record<string, unknown>;
    version: number;
  };
  source.keys['settings.notifications.title'] = {
    description: 'Settings screen notification row title.',
    placeholders: {},
    text: 'Notifications',
  };
  await writeFile(sourcePath, stableStringify(source), 'utf8');

  return targetDir;
}

async function createFakeCodexBin(): Promise<string> {
  const binDir = await mkdtemp(join(tmpdir(), 'l10n-agent-fake-codex-'));
  const codexPath = join(binDir, 'codex');
  await writeFile(
    codexPath,
    `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === '--version') {
  process.stdout.write('codex 0.121.0\\n');
  process.exit(0);
}
if (args[0] === 'login' && args[1] === 'status') {
  process.stdout.write('logged in\\n');
  process.exit(0);
}
if (args[0] === 'exec') {
  let prompt = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    prompt += chunk;
  });
  process.stdin.on('end', async () => {
    const delayMs = Number(process.env.FAKE_CODEX_DELAY_MS ?? '0');
    if (delayMs > 0) {
      await new Promise((resolveDelay) => setTimeout(resolveDelay, delayMs));
    }
    const locale = prompt.includes('Target locale: de') ? 'de' : 'es';
    const payload = JSON.stringify({ text: \`translated-\${locale}\` });
    process.stdout.write(JSON.stringify({
      type: 'item.completed',
      item: {
        type: 'agent_message',
        text: payload,
      },
    }) + '\\n');
  });
  return;
}
process.stderr.write('unsupported fake codex invocation\\n');
process.exit(1);
`,
    'utf8',
  );
  await chmod(codexPath, 0o755);
  return binDir;
}

function runCliSync(
  projectDir: string,
  fakeCodexDir: string,
  extraArgs: string[] = [],
): ChildProcessWithoutNullStreams {
  return spawn(tsxPath, ['src/cli/index.ts', '--cwd', projectDir, 'sync', ...extraArgs], {
    cwd: repoRoot,
    env: {
      ...process.env,
      FAKE_CODEX_DELAY_MS: '2000',
      PATH: `${fakeCodexDir}:${process.env.PATH}`,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

async function waitFor(condition: () => Promise<boolean>, timeoutMs = 5000): Promise<void> {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (await condition()) {
      return;
    }
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 50));
  }

  throw new Error(`Timed out after ${timeoutMs}ms`);
}

async function processResult(child: ChildProcessWithoutNullStreams): Promise<{
  code: number | null;
  signal: NodeJS.Signals | null;
  stderr: string;
  stdout: string;
}> {
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => {
    stdout += chunk.toString();
  });
  child.stderr.on('data', (chunk) => {
    stderr += chunk.toString();
  });

  return new Promise((resolveResult, reject) => {
    child.on('error', reject);
    child.on('close', (code, signal) => {
      resolveResult({ code, signal, stderr, stdout });
    });
  });
}

describe('cli sync signals and locking', () => {
  const cleanupPaths: string[] = [];

  afterEach(async () => {
    await Promise.all(cleanupPaths.splice(0).map((path) => rm(path, { force: true, recursive: true })));
  });

  it('releases the lock and writes interrupted state when sync is interrupted by SIGINT', async () => {
    const projectDir = await createTempProject('sigint');
    const fakeCodexDir = await createFakeCodexBin();
    cleanupPaths.push(projectDir, fakeCodexDir);

    const child = runCliSync(projectDir, fakeCodexDir);
    const resultPromise = processResult(child);
    const statePath = join(projectDir, 'l10n/.state.json');
    const lockPath = join(projectDir, 'l10n/.lock');

    await waitFor(async () => {
      try {
        const state = JSON.parse(await readFile(statePath, 'utf8')) as { status?: string };
        return state.status === 'running';
      } catch {
        return false;
      }
    });

    child.kill('SIGINT');
    const result = await resultPromise;

    expect(result.code).toBe(130);
    const interruptedState = JSON.parse(await readFile(statePath, 'utf8')) as { status: string };
    expect(interruptedState.status).toBe('interrupted');
    await expect(readFile(lockPath, 'utf8')).rejects.toMatchObject({ code: 'ENOENT' });
  }, 15000);

  it('rejects a concurrent sync with a lock diagnostic and exit code 6', async () => {
    const projectDir = await createTempProject('lock');
    const fakeCodexDir = await createFakeCodexBin();
    cleanupPaths.push(projectDir, fakeCodexDir);

    const first = runCliSync(projectDir, fakeCodexDir);
    const firstResultPromise = processResult(first);
    const lockPath = join(projectDir, 'l10n/.lock');

    await waitFor(async () => {
      try {
        await readFile(lockPath, 'utf8');
        return true;
      } catch {
        return false;
      }
    });

    const second = runCliSync(projectDir, fakeCodexDir, ['--json']);
    const secondResult = await processResult(second);

    expect(secondResult.code).toBe(6);
    expect(JSON.parse(secondResult.stderr)).toMatchObject({
      code: 'L10N_E0079',
    });

    first.kill('SIGINT');
    const firstResult = await firstResultPromise;
    expect(firstResult.code).toBe(130);
  }, 15000);
});
