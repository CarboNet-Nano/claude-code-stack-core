import { defineConfig } from '@playwright/test';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseDocsMeta } from './src/index.ts';

const RUNNER_DIR = dirname(fileURLToPath(import.meta.url));

const REPO = process.env.USER_DOCS_REPO ?? process.cwd();
const CAPTURES = join(REPO, 'docs', 'user', 'captures');

function docsTestFiles(): string[] {
  if (!existsSync(CAPTURES)) return [];
  return readdirSync(CAPTURES)
    .filter((f) => f.endsWith('.docs.ts'))
    .sort();
}

// One project per docs-test so `use.storageState` is resolved per-file from
// that file's docsMeta.authState (a single global storageState cannot express
// per-role captures).
const projects = docsTestFiles().map((file) => {
  const meta = parseDocsMeta(readFileSync(join(CAPTURES, file), 'utf8')) ?? {};
  const authState = meta.authState ? resolve(REPO, meta.authState) : undefined;
  return {
    name: file.replace(/\.docs\.ts$/, ''),
    testMatch: file,
    use: { storageState: authState && existsSync(authState) ? authState : undefined },
  };
});

export default defineConfig({
  testDir: CAPTURES,
  // The `@stack/user-docs` alias every consumer docs-test imports through is
  // declared in this runner's tsconfig `paths`. Playwright otherwise looks up a
  // tsconfig per imported file, walking up from the repo under test — which has
  // none — so the alias would fail to resolve and NO specs would be collected.
  tsconfig: join(RUNNER_DIR, 'tsconfig.json'),
  // Playwright's default glob does not match `*.docs.ts`; without this the
  // runner silently reports zero tests.
  testMatch: '**/*.docs.ts',
  fullyParallel: false,
  forbidOnly: true,
  retries: 0,
  reporter: [['json', { outputFile: process.env.USER_DOCS_REPORT ?? join(RUNNER_DIR, '.run', 'report.json') }]],
  use: {
    baseURL: process.env.USER_DOCS_BASE_URL,
    video: 'off',
    trace: 'off',
    screenshot: 'off',
  },
  ...(projects.length > 0 ? { projects } : {}),
});
