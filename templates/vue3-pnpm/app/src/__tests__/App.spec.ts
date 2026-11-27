/**
 * 验证 Vue 3 参考应用根组件的运行时配置展示与 SPA History 路由渲染行为。
 *
 * @author Ateng
 * @since 2026-11-27
 */
import { mount } from '@vue/test-utils';
import { afterEach, describe, expect, it } from 'vitest';
import { createMemoryHistory } from 'vue-router';
import App from '../App.vue';
import { createAppRouter } from '../router';

describe('App', () => {
  afterEach(() => {
    delete window.__APP_CONFIG__;
    document.title = '';
  });

  it('未注入运行时配置时展示默认标题、版本号与回退状态', async () => {
    const router = createAppRouter(createMemoryHistory());
    await router.push('/');
    await router.isReady();

    const wrapper = mount(App, {
      global: {
        plugins: [router],
      },
    });

    const text = wrapper.text();
    expect(text).toContain('Vue 3 部署参考应用');
    expect(text).toContain('0.0.0-dev');
    expect(text).toContain('/api');
    expect(text).toContain('回退模式');
  });

  it('注入 window.__APP_CONFIG__ 后优先渲染运行时标题、版本号、环境与 API 基地址', async () => {
    window.__APP_CONFIG__ = {
      APP_TITLE: '企业生产门户',
      APP_VERSION: '2.4.0',
      APP_ENV: 'production',
      APP_API_BASE_URL: 'https://api.example.com/prod',
    };

    const router = createAppRouter(createMemoryHistory());
    await router.push('/runtime');
    await router.isReady();

    const wrapper = mount(App, {
      global: {
        plugins: [router],
      },
    });

    const text = wrapper.text();
    expect(text).toContain('企业生产门户');
    expect(text).toContain('2.4.0');
    expect(text).toContain('production');
    expect(text).toContain('https://api.example.com/prod');
    expect(text).toContain('运行时注入');
    expect(document.title).toBe('企业生产门户');
  });

  it('访问深层 SPA 路由时正常渲染且展示当前路由路径', async () => {
    const router = createAppRouter(createMemoryHistory());
    await router.push('/orders/20261127/detail');
    await router.isReady();

    const wrapper = mount(App, {
      global: {
        plugins: [router],
      },
    });

    const text = wrapper.text();
    expect(text).toContain('/orders/20261127/detail');
    expect(text).toContain('SPA History 路由回退正常');
  });
});
