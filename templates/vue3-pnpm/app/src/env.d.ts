/**
 * 声明 Vite 客户端环境变量与全局运行时配置对象 window.__APP_CONFIG__ 的 TypeScript 类型。
 *
 * @author Ateng
 * @since 2026-11-27
 */
/// <reference types="vite/client" />

export interface RuntimeAppConfig {
  APP_TITLE?: string;
  APP_VERSION?: string;
  APP_ENV?: string;
  APP_API_BASE_URL?: string;
}

declare global {
  interface ImportMetaEnv {
    readonly VITE_APP_TITLE?: string;
    readonly VITE_APP_VERSION?: string;
    readonly VITE_APP_ENV?: string;
    readonly VITE_API_BASE_URL?: string;
  }

  interface Window {
    __APP_CONFIG__?: RuntimeAppConfig;
  }
}
