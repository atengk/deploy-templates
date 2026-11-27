/**
 * 验证运行时配置解析模块的优先级与回退契约。
 *
 * @author Ateng
 * @since 2026-11-27
 */
import { afterEach, describe, expect, it } from 'vitest';
import { resolveAppConfig } from '../config/runtimeConfig';

describe('resolveAppConfig', () => {
  afterEach(() => {
    delete window.__APP_CONFIG__;
  });

  it('未注入运行时配置时回退至构建期环境变量并标记为 fallback', () => {
    const resolved = resolveAppConfig({
      runtimeConfig: undefined,
      buildEnv: {
        VITE_APP_TITLE: '构建期标题',
        VITE_APP_VERSION: '1.2.0',
        VITE_APP_ENV: 'staging',
        VITE_API_BASE_URL: 'https://build-api.example.com',
      },
    });

    expect(resolved.title).toBe('构建期标题');
    expect(resolved.version).toBe('1.2.0');
    expect(resolved.env).toBe('staging');
    expect(resolved.apiBaseUrl).toBe('https://build-api.example.com');
    expect(resolved.sourceMode).toBe('fallback');
    expect(resolved.sources).toEqual({
      title: 'build',
      version: 'build',
      env: 'build',
      apiBaseUrl: 'build',
    });
  });

  it('构建期环境变量缺失时使用内置安全默认值', () => {
    const resolved = resolveAppConfig({
      runtimeConfig: undefined,
      buildEnv: {},
    });

    expect(resolved.title).toBe('Vue 3 部署参考应用');
    expect(resolved.version).toBe('0.0.0-dev');
    expect(resolved.env).toBe('development');
    expect(resolved.apiBaseUrl).toBe('/api');
    expect(resolved.sourceMode).toBe('fallback');
    expect(resolved.sources).toEqual({
      title: 'default',
      version: 'default',
      env: 'default',
      apiBaseUrl: 'default',
    });
  });

  it('window.__APP_CONFIG__ 优先覆盖构建期环境变量并标记为 runtime', () => {
    window.__APP_CONFIG__ = {
      APP_TITLE: '生产运行时站点',
      APP_VERSION: '2.0.1',
      APP_ENV: 'production',
      APP_API_BASE_URL: 'https://api.example.com/v2',
    };

    const resolved = resolveAppConfig({
      buildEnv: {
        VITE_APP_TITLE: '构建期标题',
        VITE_APP_VERSION: '1.0.0',
        VITE_APP_ENV: 'development',
        VITE_API_BASE_URL: '/api',
      },
    });

    expect(resolved.title).toBe('生产运行时站点');
    expect(resolved.version).toBe('2.0.1');
    expect(resolved.env).toBe('production');
    expect(resolved.apiBaseUrl).toBe('https://api.example.com/v2');
    expect(resolved.sourceMode).toBe('runtime');
    expect(resolved.sources).toEqual({
      title: 'runtime',
      version: 'runtime',
      env: 'runtime',
      apiBaseUrl: 'runtime',
    });
  });

  it('运行时仅部分注入或存在空白字符串时对其余字段平滑回退', () => {
    const resolved = resolveAppConfig({
      runtimeConfig: {
        APP_TITLE: '   ',
        APP_API_BASE_URL: 'https://runtime.example.com',
      },
      buildEnv: {
        VITE_APP_TITLE: '构建期标题',
        VITE_APP_VERSION: '1.5.0',
        VITE_API_BASE_URL: '/api',
      },
    });

    expect(resolved.title).toBe('构建期标题');
    expect(resolved.version).toBe('1.5.0');
    expect(resolved.env).toBe('development');
    expect(resolved.apiBaseUrl).toBe('https://runtime.example.com');
    expect(resolved.sourceMode).toBe('runtime');
    expect(resolved.sources).toEqual({
      title: 'build',
      version: 'build',
      env: 'default',
      apiBaseUrl: 'runtime',
    });
  });
});
