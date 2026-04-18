import { afterEach, describe, expect, it, vi } from 'vitest';

describe('fs utils', () => {
  afterEach(() => {
    vi.doUnmock('node:fs/promises');
    vi.resetModules();
  });

  it('fsyncs the temp file before rename and fsyncs the parent directory afterwards', async () => {
    const calls: string[] = [];
    const fileHandle = {
      close: async () => {
        calls.push('file.close');
      },
      sync: async () => {
        calls.push('file.sync');
      },
      writeFile: async () => {
        calls.push('file.write');
      },
    };
    const dirHandle = {
      close: async () => {
        calls.push('dir.close');
      },
      sync: async () => {
        calls.push('dir.sync');
      },
    };

    vi.doMock('node:fs/promises', () => ({
      mkdir: async () => {
        calls.push('mkdir');
      },
      open: async (_path: string, flags: string) => {
        calls.push(`open:${flags}`);
        return flags === 'r' ? dirHandle : fileHandle;
      },
      readFile: async () => '',
      rename: async () => {
        calls.push('rename');
      },
      rm: async () => {
        calls.push('rm');
      },
    }));

    const { writeTextFileAtomic } = await import('../../src/utils/fs.js');
    await writeTextFileAtomic('/tmp/example.json', 'hello');

    expect(calls).toEqual([
      'mkdir',
      'open:w',
      'file.write',
      'file.sync',
      'file.close',
      'rename',
      'open:r',
      'dir.sync',
      'dir.close',
    ]);
  });

  it('fsyncs append-only writes before syncing the parent directory', async () => {
    const calls: string[] = [];
    const appendHandle = {
      close: async () => {
        calls.push('append.close');
      },
      sync: async () => {
        calls.push('append.sync');
      },
      writeFile: async () => {
        calls.push('append.write');
      },
    };
    const dirHandle = {
      close: async () => {
        calls.push('dir.close');
      },
      sync: async () => {
        calls.push('dir.sync');
      },
    };

    vi.doMock('node:fs/promises', () => ({
      mkdir: async () => {
        calls.push('mkdir');
      },
      open: async (_path: string, flags: string) => {
        calls.push(`open:${flags}`);
        return flags === 'r' ? dirHandle : appendHandle;
      },
      readFile: async () => '',
      rename: async () => {
        calls.push('rename');
      },
      rm: async () => {
        calls.push('rm');
      },
    }));

    const { appendTextFile } = await import('../../src/utils/fs.js');
    await appendTextFile('/tmp/example.log', 'line\n');

    expect(calls).toEqual([
      'mkdir',
      'open:a',
      'append.write',
      'append.sync',
      'append.close',
      'open:r',
      'dir.sync',
      'dir.close',
    ]);
  });
});
