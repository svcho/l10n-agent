import { resolve } from 'node:path';

import YAML from 'yaml';

import { L10nError } from '../errors/l10n-error.js';
import { readTextFile } from '../utils/fs.js';
import { ConfigSchema, type Config } from './schema.js';

export const DEFAULT_CONFIG_PATH = 'l10n/config.yaml';

export interface LoadedConfig {
  config: Config;
  path: string;
}

export async function loadConfig(rootDir: string, explicitConfigPath?: string): Promise<LoadedConfig> {
  const configPath = resolve(rootDir, explicitConfigPath ?? DEFAULT_CONFIG_PATH);

  let rawText: string;
  try {
    rawText = await readTextFile(configPath);
  } catch (error) {
    throw new L10nError({
      code: 'L10N_E0001',
      details: { path: configPath },
      level: 'error',
      next: 'Create l10n/config.yaml or pass --config with an existing path.',
      summary: 'Config file could not be read',
    });
  }

  let rawConfig: unknown;
  try {
    rawConfig = YAML.parse(rawText);
  } catch (error) {
    throw new L10nError({
      code: 'L10N_E0002',
      details: { path: configPath },
      level: 'error',
      next: 'Fix the YAML syntax in the config file.',
      summary: 'Config file is not valid YAML',
    });
  }

  const parsedConfig = ConfigSchema.safeParse(rawConfig);
  if (!parsedConfig.success) {
    const issue = parsedConfig.error.issues[0];
    throw new L10nError({
      code: 'L10N_E0003',
      details: {
        issue: issue?.message ?? 'unknown schema violation',
        path: configPath,
      },
      level: 'error',
      next: 'Update the config to satisfy the declared schema.',
      summary: 'Config file failed schema validation',
    });
  }

  return {
    config: parsedConfig.data,
    path: configPath,
  };
}
