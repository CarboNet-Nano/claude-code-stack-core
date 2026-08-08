import { test as base } from '@playwright/test';
import type { Locator, Page } from '@playwright/test';
import { appendFileSync, mkdirSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';

export const AUTH_EXPIRED_SENTINEL = 'USER_DOCS_AUTH_EXPIRED';

export type DocsMeta = {
  guide: string;
  role: string;
  authState: string;
  replay: 'auto' | 'reset-required' | 'manual';
  sideEffects: string[];
  reset?: string;
};

export type DocsFixtures = { docsBaseUrl: string };

export type Framing = 'locator' | 'clip' | 'full-page';

export type CaptureRecord = {
  guide: string;
  name: string;
  committed: string;
  fresh: string;
  framing: Framing;
};

export type ShotOptions = {
  locator?: Locator;
  clip?: { x: number; y: number; width: number; height: number };
};

const AUTH_PATH = /(^|\/)(login|signin|sign-in|auth|sso)(\/|$)/i;

function requireEnv(key: string): string {
  const value = process.env[key];
  if (!value) throw new Error(`${key} is not set — run docs-tests through user-docs-run, not bare playwright`);
  return value;
}

/** Guide slug is the docs-test's own filename, so a spec never has to repeat it. */
function guideSlug(): string {
  const override = process.env.USER_DOCS_GUIDE_SLUG;
  if (override) return override;
  return basename(base.info().file).replace(/\.docs\.ts$/, '');
}

function recordCapture(record: CaptureRecord): void {
  const manifest = process.env.USER_DOCS_MANIFEST;
  if (!manifest) return;
  mkdirSync(dirname(manifest), { recursive: true });
  appendFileSync(manifest, `${JSON.stringify(record)}\n`);
}

/**
 * Fails the run with a distinguishable sentinel when the FIRST navigation of a
 * docs-test lands on a login page. Without this, an expired storage state is
 * indistinguishable from a genuine UI change and gets misreported as STALE.
 */
function guardAuthRedirect(page: Page): void {
  let firstNavigationChecked = false;
  const navigate = page.goto.bind(page);
  page.goto = async (url, options) => {
    const response = await navigate(url, options);
    if (firstNavigationChecked) return response;
    firstNavigationChecked = true;
    const landed = page.url();
    const landedPath = safePath(landed);
    const requestedPath = safePath(url, landed);
    if (AUTH_PATH.test(landedPath) && !AUTH_PATH.test(requestedPath)) {
      throw new Error(`${AUTH_EXPIRED_SENTINEL}: navigation to ${url} redirected to ${landed}`);
    }
    return response;
  };
}

function safePath(url: string, base?: string): string {
  try {
    return new URL(url, base).pathname;
  } catch {
    return url;
  }
}

export const docsTest = base.extend<DocsFixtures>({
  docsBaseUrl: async ({}, use) => {
    await use(process.env.USER_DOCS_BASE_URL ?? '');
  },
  page: async ({ page }, use) => {
    guardAuthRedirect(page);
    await use(page);
  },
});

/**
 * Captures one guide image. Writes to the committed path by default; when the
 * runner sets USER_DOCS_FRESH_DIR (freshness mode) it writes to the scratch dir
 * instead, so a refresh sweep never dirties committed PNGs before comparison.
 */
export async function shot(page: Page, name: string, opts?: ShotOptions): Promise<void> {
  const repo = requireEnv('USER_DOCS_REPO');
  const slug = guideSlug();
  const committed = join(repo, 'docs', 'user', 'media', slug, `${name}.png`);
  const freshDir = process.env.USER_DOCS_FRESH_DIR;
  const target = freshDir ? join(freshDir, slug, `${name}.png`) : committed;
  const framing: Framing = opts?.locator ? 'locator' : opts?.clip ? 'clip' : 'full-page';

  mkdirSync(dirname(target), { recursive: true });
  if (opts?.locator) {
    await opts.locator.screenshot({ path: target });
  } else if (opts?.clip) {
    await page.screenshot({ path: target, clip: opts.clip });
  } else {
    await page.screenshot({ path: target, fullPage: true });
  }

  recordCapture({ guide: slug, name, committed, fresh: target, framing });
}

/**
 * Static (parse-only, never import) reader for a docs-test's `export const
 * docsMeta`. Static is load-bearing: the runner must refuse manual and
 * reset-required replays BEFORE launching a browser, so refusal cannot depend
 * on the spec being importable.
 */
export function parseDocsMeta(source: string): Partial<DocsMeta> | null {
  const declaration = /export\s+const\s+docsMeta\b[^={]*=\s*\{/.exec(source);
  if (!declaration) return null;
  const open = source.indexOf('{', declaration.index);
  const body = sliceBalanced(source, open);
  if (!body) return null;

  const meta: Partial<DocsMeta> = {};
  for (const key of ['guide', 'role', 'authState', 'replay', 'reset'] as const) {
    const value = scalarField(body, key);
    if (value !== undefined) (meta as Record<string, unknown>)[key] = value;
  }
  const sideEffects = arrayField(body, 'sideEffects');
  if (sideEffects) meta.sideEffects = sideEffects;
  return meta;
}

function sliceBalanced(source: string, open: number): string | null {
  let depth = 0;
  let quote = '';
  for (let i = open; i < source.length; i++) {
    const ch = source[i];
    if (quote) {
      if (ch === '\\') i++;
      else if (ch === quote) quote = '';
      continue;
    }
    if (ch === '"' || ch === "'" || ch === '`') quote = ch;
    else if (ch === '{') depth++;
    else if (ch === '}' && --depth === 0) return source.slice(open, i + 1);
  }
  return null;
}

function scalarField(body: string, key: string): string | undefined {
  const match = new RegExp(`["'\`]?\\b${key}\\b["'\`]?\\s*:\\s*(["'\`])((?:\\\\.|(?!\\1).)*)\\1`).exec(body);
  return match ? match[2] : undefined;
}

function arrayField(body: string, key: string): string[] | undefined {
  const match = new RegExp(`["'\`]?\\b${key}\\b["'\`]?\\s*:\\s*\\[([\\s\\S]*?)\\]`).exec(body);
  if (!match) return undefined;
  return [...match[1].matchAll(/(["'`])((?:\\.|(?!\1).)*)\1/g)].map((m) => m[2]);
}
