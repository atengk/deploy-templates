<script setup lang="ts">
/**
 * 展示深层 SPA History 路由回退命中状态，用于验证 Nginx 静态托管路由转发。
 *
 * @author Ateng
 * @since 2026-11-27
 */
import { useRoute } from 'vue-router';
import type { ResolvedAppConfig } from '../config/runtimeConfig';

defineProps<{
  config: ResolvedAppConfig;
}>();

const route = useRoute();
</script>

<template>
  <section class="panel" aria-label="SPA History 路由回退">
    <h2 class="panel-title">SPA History 路由回退正常</h2>
    <p class="panel-desc">
      当前深层路径已由前端路由接管并成功渲染，说明静态服务器已正确将未知页面路径回退至入口页。
    </p>
    <div class="card">
      <span class="label">当前请求路径</span>
      <strong class="value mono">{{ route.fullPath }}</strong>
    </div>
    <p class="hint">
      当前应用：{{ config.title }}（版本 {{ config.version }}）
    </p>
  </section>
</template>
