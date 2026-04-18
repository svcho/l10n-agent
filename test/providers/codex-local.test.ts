import { describe, expect, it } from 'vitest';

import { CodexLocalProvider } from '../../src/providers/codex-local.js';

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
});
