/**
 * 解析并合并前端运行时注入配置与构建期回退环境变量。
 *
 * @author Ateng
 * @since 2026-11-27
 */
import type { RuntimeAppConfig } from '../env';

/** 单个配置项的值来源标识。 */
export type ConfigValueSource = 'runtime' | 'build' | 'default';

/** 整体运行期配置加载模式。 */
export type ConfigSourceMode = 'runtime' | 'fallback';

/** 解析后的标准应用配置对象。 */
export interface ResolvedAppConfig {
  title: string;
  version: string;
  env: string;
  apiBaseUrl: string;
  sourceMode: ConfigSourceMode;
  sources: {
    title: ConfigValueSource;
    version: ConfigValueSource;
    env: ConfigValueSource;
    apiBaseUrl: ConfigValueSource;
  };
}

/** 供配置解析函数使用的构建期环境变量结构。 */
export interface BuildTimeEnv {
  readonly VITE_APP_TITLE?: string;
  readonly VITE_APP_VERSION?: string;
  readonly VITE_APP_ENV?: string;
  readonly VITE_API_BASE_URL?: string;
}

/** 配置解析函数的可选覆盖参数（主要用于无副作用测试隔离）。 */
export interface ResolveAppConfigOptions {
  runtimeConfig?: RuntimeAppConfig;
  buildEnv?: BuildTimeEnv;
}

const DEFAULT_APP_CONFIG = {
  title: 'Vue 3 部署参考应用',
  version: '0.0.0-dev',
  env: 'development',
  apiBaseUrl: '/api',
} as const;

function normalizeNonEmptyString(rawValue: unknown): string {
  if (typeof rawValue !== 'string') {
    return '';
  }
  return rawValue.trim();
}

function pickConfigValue(
  runtimeValue: string | undefined,
  buildValue: string | undefined,
  defaultValue: string,
): { value: string; source: ConfigValueSource } {
  const normalizedRuntime = normalizeNonEmptyString(runtimeValue);
  if (normalizedRuntime) {
    return { value: normalizedRuntime, source: 'runtime' };
  }

  const normalizedBuild = normalizeNonEmptyString(buildValue);
  if (normalizedBuild) {
    return { value: normalizedBuild, source: 'build' };
  }

  return { value: defaultValue, source: 'default' };
}

/**
 * 解析应用配置，严格按 `window.__APP_CONFIG__` > `import.meta.env.VITE_*` > 内置默认值的优先级返回结果。
 *
 * @param options 可选配置来源覆盖项；未传时分别读取浏览器全局 `window.__APP_CONFIG__` 与 `import.meta.env`
 * @return 包含最终字段值、整体配置模式（`runtime` 或 `fallback`）及各字段来源明细的配置对象
 */
export function resolveAppConfig(options: ResolveAppConfigOptions = {}): ResolvedAppConfig {
  const runtimeSource =
    'runtimeConfig' in options
      ? options.runtimeConfig
      : typeof window !== 'undefined'
        ? window.__APP_CONFIG__
        : undefined;

  const buildSource: BuildTimeEnv = options.buildEnv ?? import.meta.env;

  const title = pickConfigValue(
    runtimeSource?.APP_TITLE,
    buildSource.VITE_APP_TITLE,
    DEFAULT_APP_CONFIG.title,
  );
  const version = pickConfigValue(
    runtimeSource?.APP_VERSION,
    buildSource.VITE_APP_VERSION,
    DEFAULT_APP_CONFIG.version,
  );
  const env = pickConfigValue(
    runtimeSource?.APP_ENV,
    buildSource.VITE_APP_ENV,
    DEFAULT_APP_CONFIG.env,
  );
  const apiBaseUrl = pickConfigValue(
    runtimeSource?.APP_API_BASE_URL,
    buildSource.VITE_API_BASE_URL,
    DEFAULT_APP_CONFIG.apiBaseUrl,
  );

  const hasAnyRuntimeValue = [title, version, env, apiBaseUrl].some(
    (entry) => entry.source === 'runtime',
  );

  return {
    title: title.value,
    version: version.value,
    env: env.value,
    apiBaseUrl: apiBaseUrl.value,
    sourceMode: hasAnyRuntimeValue ? 'runtime' : 'fallback',
    sources: {
      title: title.source,
      version: version.source,
      env: env.source,
      apiBaseUrl: apiBaseUrl.source,
    },
  };
}
