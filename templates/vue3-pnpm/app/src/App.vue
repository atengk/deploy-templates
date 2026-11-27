<script setup lang="ts">
/**
 * 参考应用根组件，负责加载运行时配置、同步文档标题并提供视图导航外壳。
 *
 * @author Ateng
 * @since 2026-11-27
 */
import { computed, onMounted } from 'vue';
import { RouterLink, RouterView, useRoute } from 'vue-router';
import { resolveAppConfig } from './config/runtimeConfig';

const appConfig = resolveAppConfig();
const route = useRoute();

const configStatusText = computed(() =>
  appConfig.sourceMode === 'runtime'
    ? '运行时注入（window.__APP_CONFIG__）'
    : '回退模式（import.meta.env / 默认值）',
);

const statusBadgeClass = computed(() =>
  appConfig.sourceMode === 'runtime' ? 'badge badge-runtime' : 'badge badge-fallback',
);

if (typeof document !== 'undefined') {
  document.title = appConfig.title;
}

onMounted(() => {
  document.title = appConfig.title;
});
</script>

<template>
  <div class="app-shell">
    <header class="hero">
      <div class="hero-top">
        <span class="stack-tag">Vue 3 + pnpm + Vite</span>
        <span :class="statusBadgeClass">{{ configStatusText }}</span>
      </div>
      <h1 class="hero-title">{{ appConfig.title }}</h1>
      <p class="hero-meta">
        版本号：<strong class="mono">{{ appConfig.version }}</strong>
        <span class="divider">|</span>
        环境：<strong class="mono">{{ appConfig.env }}</strong>
        <span class="divider">|</span>
        API 基地址：<strong class="mono">{{ appConfig.apiBaseUrl }}</strong>
      </p>
      <nav class="nav" aria-label="主导航">
        <RouterLink class="nav-link" to="/">概览</RouterLink>
        <RouterLink class="nav-link" to="/runtime">运行时配置</RouterLink>
        <RouterLink class="nav-link" to="/orders/20261127/detail">深层路由演示</RouterLink>
      </nav>
    </header>

    <main class="content">
      <RouterView :config="appConfig" />
    </main>

    <footer class="footer">
      <span>当前路径：<code class="mono">{{ route.fullPath }}</code></span>
      <span>单应用交付边界：纯静态 SPA，无有状态中间件绑定</span>
    </footer>
  </div>
</template>
