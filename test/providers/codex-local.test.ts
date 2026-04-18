import { describe, expect, it } from 'vitest';

import { CodexLocalProvider, ReplayCodexExecTransport } from '../../src/providers/codex-local.js';

describe('CodexLocalProvider', () => {
  it('surfaces session permission failures with a specific diagnostic', async () => {
    const provider = new CodexLocalProvider({
      cwd: process.cwd(),
      minimumVersion: '0.30.0',
      transport: {
        run: async () => ({
          exitCode: 1,
          stderr:
            'Error: thread/start: thread/start failed: error creating thread: Fatal error: Codex cannot access session files at /Users/test/.codex/sessions (permission denied). If sessions were created using sudo, fix ownership: sudo chown -R $(whoami) /Users/test/.codex',
          stdout: '',
        }),
      },
    });

    await expect(
      provider.planKeyRenames({
        candidates: [
          {
            key: 'tmp.WelcomeTitle',
            text: 'Welcome',
            violations: ['L10N_E0020', 'L10N_E0023'],
          },
        ],
        forbiddenPrefixes: ['tmp.'],
        keyCase: 'dotted.lower',
        maxDepth: 4,
        scopes: ['onboarding'],
        sourceLocale: 'en',
      }),
    ).rejects.toMatchObject({
      diagnostic: {
        code: 'L10N_E0054',
        details: {
          path: '/Users/test/.codex/sessions',
        },
        summary: 'Codex cannot access its local session files',
      },
    });
  });

  it('fails replay transport invariant checks with structured diagnostics', async () => {
    const transport = new ReplayCodexExecTransport([]);

    await expect(
      transport.run({
        cwd: process.cwd(),
        outputSchemaPath: '/tmp/schema.json',
        prompt: 'test',
      }),
    ).rejects.toMatchObject({
      diagnostic: {
        code: 'L10N_E0081',
      },
    });
  });

  it('fails when a replay fixture is missing', async () => {
    const transport = new ReplayCodexExecTransport([]);

    await expect(
      transport.run({
        cwd: process.cwd(),
        outputSchemaPath: '/tmp/schema.json',
        prompt: 'test',
        request: {
          glossary: {},
          placeholders: [],
          sourceLocale: 'en',
          sourceText: 'Welcome',
          targetLocale: 'de',
        },
      }),
    ).rejects.toMatchObject({
      diagnostic: {
        code: 'L10N_E0081',
      },
    });
  });

  it('passes the configured model through to Codex executions', async () => {
    const seenRequests: Array<{ model?: string }> = [];
    const provider = new CodexLocalProvider({
      cwd: process.cwd(),
      minimumVersion: '0.30.0',
      model: 'gpt-5.1',
      transport: {
        run: async (request) => {
          seenRequests.push({ model: request.model });
          return {
            exitCode: 0,
            stderr: '',
            stdout: `${JSON.stringify({
              item: {
                text: JSON.stringify({ text: 'Willkommen' }),
                type: 'agent_message',
              },
              type: 'item.completed',
            })}\n`,
          };
        },
      },
    });

    const result = await provider.translate({
      glossary: {},
      placeholders: [],
      sourceLocale: 'en',
      sourceText: 'Welcome',
      targetLocale: 'de',
    });

    expect(seenRequests).toEqual([{ model: 'gpt-5.1' }]);
    expect(result).toEqual({
      modelVersion: 'gpt-5.1',
      text: 'Willkommen',
    });
  });
});
