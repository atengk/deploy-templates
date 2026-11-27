<script setup lang="ts">
/**
 * 展示应用总览与当前运行期状态摘要视图。
 *
 * @author Ateng
 * @since 2026-11-27
 */
import type { ResolvedAppConfig } from '../config/runtimeConfig';

defineProps<{
  config: ResolvedAppConfig;
}>();
</script>

<template>
  <section class="panel" aria-label="应用概览">
    <h2 class="panel-title">运行概览</h2>
    <p class="panel-desc">
      当前页面由纯静态 SPA 构建产物提供服务，不依赖 Node.js 常驻进程。
    </p>
    <div class="grid">
      <div class="card">
        <span class="label">应用标题</span>
        <strong class="value">{{ config.title }}</strong>
      </div>
      <div class="card">
        <span class="label">注入版本号</span>
        <strong class="value">{{ config.version }}</strong>
      </div>
      <div class="card">
        <span class="label">业务环境标识</span>
        <strong class="value">{{ config.env }}</strong>
      </div>
      <div class="card">
        <span class="label">API 基础地址</span>
        <strong class="value mono">{{ config.apiBaseUrl }}</strong>
      </div>
    </div>
  </section>
</template>
