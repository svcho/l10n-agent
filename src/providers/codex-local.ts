import { execFile, spawn } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';

import { L10nError } from '../errors/l10n-error.js';
import { writeTextFileAtomic } from '../utils/fs.js';
import type {
  PreflightResult,
  TranslationProvider,
  TranslationRequest,
  TranslationResult,
} from './base.js';

const execFileAsync = promisify(execFile);

export interface CodexPreflightResult {
  detectedVersion: string | null;
  loginStatus: 'logged-in' | 'logged-out' | 'not-installed' | 'unknown';
  meetsMinimumVersion: boolean;
  minimumVersion: string;
}

export interface CodexExecRequest {
  cwd: string;
  model?: string;
  outputSchemaPath: string;
  prompt: string;
  request: TranslationRequest;
}

export interface CodexExecResponse {
  exitCode: number;
  stderr: string;
  stdout: string;
}

export interface CodexExecTransport {
  run(request: CodexExecRequest): Promise<CodexExecResponse>;
}

export interface RecordedCodexResponseFixture {
  request: Pick<TranslationRequest, 'sourceLocale' | 'sourceText' | 'targetLocale'>;
  response: CodexExecResponse;
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

function normalizeGlossary(
  glossary: TranslationRequest['glossary'],
  targetLocale: string,
): Array<{ source: string; target: string }> {
  return Object.entries(glossary ?? {})
    .flatMap(([source, locales]) => {
      const target = locales[targetLocale];
      return typeof target === 'string' && target.length > 0 ? [{ source, target }] : [];
    })
    .sort((left, right) => left.source.localeCompare(right.source));
}

function buildPrompt(request: TranslationRequest): string {
  const glossaryEntries = normalizeGlossary(request.glossary, request.targetLocale);
  const placeholdersText =
    request.placeholders.length > 0
      ? request.placeholders.map((placeholder) => `${placeholder.name}:${placeholder.type}`).join(', ')
      : 'none';
  const sections = [
    'Translate the source text for a mobile app localization workflow.',
    `Source locale: ${request.sourceLocale}`,
    `Target locale: ${request.targetLocale}`,
    'Return JSON only and set the "text" field to the translated string.',
    'Preserve ICU placeholders exactly as written, including repeated placeholders.',
    'Do not add or remove placeholders, punctuation-only placeholders, or commentary.',
    `Placeholders: ${placeholdersText}`,
  ];

  if (request.description) {
    sections.push(`Description: ${request.description}`);
  }

  if (glossaryEntries.length > 0) {
    sections.push(
      `Glossary:\n${glossaryEntries.map((entry) => `- ${entry.source} => ${entry.target}`).join('\n')}`,
    );
  }

  sections.push(`Source text:\n${request.sourceText}`);

  return sections.join('\n\n');
}

function classifyCodexFailure(stderr: string, stdout: string): L10nError {
  const combined = `${stderr}\n${stdout}`;
  if (/(rate limit|quota|429|too many requests|usage limit)/i.test(combined)) {
    return new L10nError({
      code: 'L10N_E0053',
      details: {},
      level: 'error',
      next: 'Wait for the rate limit to reset, then re-run `l10n-agent sync`.',
      summary: 'Codex rate limit or quota interrupted the translation run',
    });
  }

  return new L10nError({
    code: 'L10N_E0054',
    details: {},
    level: 'error',
    next: 'Re-run the command. If the crash repeats, upgrade Codex CLI and try again.',
    summary: 'Codex subprocess exited unexpectedly',
  });
}

export function parseCodexExecJsonl(stdout: string): string {
  const lines = stdout
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  let finalMessage: string | null = null;

  for (const line of lines) {
    let event: unknown;
    try {
      event = JSON.parse(line);
    } catch {
      throw new L10nError({
        code: 'L10N_E0055',
        details: {},
        level: 'error',
        next: 'Upgrade Codex CLI or re-record the provider fixture if the protocol changed.',
        summary: 'Codex returned an unrecognized JSON event stream',
      });
    }

    if (
      event &&
      typeof event === 'object' &&
      'type' in event &&
      event.type === 'item.completed' &&
      'item' in event &&
      event.item &&
      typeof event.item === 'object' &&
      'type' in event.item &&
      event.item.type === 'agent_message' &&
      'text' in event.item &&
      typeof event.item.text === 'string'
    ) {
      finalMessage = event.item.text;
    }
  }

  if (!finalMessage) {
    throw new L10nError({
      code: 'L10N_E0055',
      details: {},
      level: 'error',
      next: 'Upgrade Codex CLI or re-record the provider fixture if the protocol changed.',
      summary: 'Codex did not emit a final agent message',
    });
  }

  return finalMessage;
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
    } catch {
      return {
        detectedVersion,
        loginStatus: 'logged-out',
        meetsMinimumVersion,
        minimumVersion,
      };
    }
  } catch {
    return {
      detectedVersion: null,
      loginStatus: 'not-installed',
      meetsMinimumVersion: false,
      minimumVersion,
    };
  }
}

export class SpawnCodexExecTransport implements CodexExecTransport {
  async run(request: CodexExecRequest): Promise<CodexExecResponse> {
    return new Promise((resolve, reject) => {
      const args = [
        'exec',
        '--json',
        '--skip-git-repo-check',
        '--ephemeral',
        '--color',
        'never',
        '--sandbox',
        'read-only',
        '-C',
        request.cwd,
        '--output-schema',
        request.outputSchemaPath,
      ];

      if (request.model) {
        args.push('--model', request.model);
      }

      args.push('-');

      const child = spawn('codex', args, {
        stdio: ['pipe', 'pipe', 'pipe'],
      });

      let stdout = '';
      let stderr = '';

      child.stdout.on('data', (chunk: Buffer | string) => {
        stdout += chunk.toString();
      });
      child.stderr.on('data', (chunk: Buffer | string) => {
        stderr += chunk.toString();
      });
      child.on('error', (error) => {
        reject(error);
      });
      child.on('close', (exitCode) => {
        resolve({
          exitCode: exitCode ?? 1,
          stderr,
          stdout,
        });
      });

      child.stdin.end(request.prompt);
    });
  }
}

export class ReplayCodexExecTransport implements CodexExecTransport {
  constructor(private readonly fixtures: RecordedCodexResponseFixture[]) {}

  static async fromFile(path: string): Promise<ReplayCodexExecTransport> {
    const rawText = await readFile(path, 'utf8');
    const parsed = JSON.parse(rawText) as {
      records: RecordedCodexResponseFixture[];
    };
    return new ReplayCodexExecTransport(parsed.records);
  }

  async run(request: CodexExecRequest): Promise<CodexExecResponse> {
    const match = this.fixtures.find(
      (fixture) =>
        fixture.request.sourceLocale === request.request.sourceLocale &&
        fixture.request.targetLocale === request.request.targetLocale &&
        fixture.request.sourceText === request.request.sourceText,
    );

    if (!match) {
      throw new Error(
        `No recorded Codex fixture for ${request.request.sourceLocale}->${request.request.targetLocale}: ${request.request.sourceText}`,
      );
    }

    return structuredClone(match.response);
  }
}

export function codexPreflightToResult(preflight: CodexPreflightResult): PreflightResult {
  if (preflight.loginStatus === 'not-installed') {
    return {
      code: 'L10N_E0050',
      message: 'Install Codex CLI - see https://github.com/openai/codex. Then run `codex login`.',
      ok: false,
      ...(preflight.detectedVersion ? { detectedVersion: preflight.detectedVersion } : {}),
    };
  }

  if (!preflight.meetsMinimumVersion) {
    return {
      code: 'L10N_E0052',
      message: `Detected Codex ${preflight.detectedVersion ?? 'unknown'}; l10n-agent v1 requires >= ${preflight.minimumVersion}. Upgrade via your package manager.`,
      ok: false,
      ...(preflight.detectedVersion ? { detectedVersion: preflight.detectedVersion } : {}),
    };
  }

  if (preflight.loginStatus !== 'logged-in') {
    return {
      code: 'L10N_E0051',
      message: 'Run `codex login` to sign in with your ChatGPT account.',
      ok: false,
      ...(preflight.detectedVersion ? { detectedVersion: preflight.detectedVersion } : {}),
    };
  }

  return {
    ok: true,
    ...(preflight.detectedVersion ? { detectedVersion: preflight.detectedVersion } : {}),
  };
}

export class CodexLocalProvider implements TranslationProvider {
  readonly id = 'codex-local';

  private latestPreflight: CodexPreflightResult | null = null;

  constructor(
    private readonly options: {
      cwd: string;
      minimumVersion: string;
      model?: string;
      preflightCheck?: () => Promise<CodexPreflightResult>;
      transport?: CodexExecTransport;
    },
  ) {}

  async estimateRequests(
    inputs: TranslationRequest[],
  ): Promise<{ notes?: string; requests: number }> {
    return {
      notes: 'One Codex exec invocation per uncached translation.',
      requests: inputs.length,
    };
  }

  async preflight(): Promise<PreflightResult> {
    const result = await (this.options.preflightCheck ?? (() => codexPreflight(this.options.minimumVersion)))();
    this.latestPreflight = result;
    return codexPreflightToResult(result);
  }

  async translate(input: TranslationRequest): Promise<TranslationResult> {
    const schemaDir = await mkdtemp(join(tmpdir(), 'l10n-agent-codex-'));
    const schemaPath = join(schemaDir, 'translation-output.schema.json');

    try {
      await writeTextFileAtomic(
        schemaPath,
        `${JSON.stringify(
          {
            additionalProperties: false,
            properties: {
              text: { type: 'string' },
            },
            required: ['text'],
            type: 'object',
          },
          null,
          2,
        )}\n`,
      );

      const response = await (this.options.transport ?? new SpawnCodexExecTransport()).run({
        cwd: this.options.cwd,
        outputSchemaPath: schemaPath,
        prompt: buildPrompt(input),
        request: input,
        ...(this.options.model ? { model: this.options.model } : {}),
      });

      if (response.exitCode !== 0) {
        throw classifyCodexFailure(response.stderr, response.stdout);
      }

      const finalMessage = parseCodexExecJsonl(response.stdout);
      let parsed: unknown;

      try {
        parsed = JSON.parse(finalMessage);
      } catch {
        throw new L10nError({
          code: 'L10N_E0055',
          details: {},
          level: 'error',
          next: 'Upgrade Codex CLI or re-record the provider fixture if the protocol changed.',
          summary: 'Codex returned malformed structured output',
        });
      }

      if (
        !parsed ||
        typeof parsed !== 'object' ||
        Array.isArray(parsed) ||
        !('text' in parsed) ||
        typeof parsed.text !== 'string'
      ) {
        throw new L10nError({
          code: 'L10N_E0055',
          details: {},
          level: 'error',
          next: 'Upgrade Codex CLI or re-record the provider fixture if the protocol changed.',
          summary: 'Codex returned an unexpected translation payload',
        });
      }

      return {
        modelVersion:
          this.options.model ??
          (this.latestPreflight?.detectedVersion
            ? `codex-cli-${this.latestPreflight.detectedVersion}`
            : 'codex-cli'),
        text: parsed.text,
      };
    } catch (error) {
      if (error instanceof L10nError) {
        throw error;
      }

      throw new L10nError({
        code: 'L10N_E0054',
        details: {},
        level: 'error',
        next: 'Re-run the command. If the crash repeats, upgrade Codex CLI and try again.',
        summary: 'Codex subprocess exited unexpectedly',
      });
    } finally {
      await rm(schemaDir, { force: true, recursive: true });
    }
  }
}
