<script setup lang="ts">
/**
 * 展示运行时配置字段来源明细与注入优先级诊断视图。
 *
 * @author Ateng
 * @since 2026-11-27
 */
import type { ConfigValueSource, ResolvedAppConfig } from '../config/runtimeConfig';

defineProps<{
  config: ResolvedAppConfig;
}>();

function formatSourceLabel(source: ConfigValueSource): string {
  switch (source) {
    case 'runtime':
      return '运行时注入（window.__APP_CONFIG__）';
    case 'build':
      return '构建期变量（import.meta.env）';
    case 'default':
      return '内置默认值';
  }
}
</script>

<template>
  <section class="panel" aria-label="运行时配置明细">
    <h2 class="panel-title">运行时配置来源明细</h2>
    <p class="panel-desc">
      遵循“一次构建，运行时注入”契约，优先级为：<code>window.__APP_CONFIG__</code> &gt;
      <code>import.meta.env.VITE_*</code> &gt; 内置默认值。
    </p>
    <table class="config-table">
      <thead>
        <tr>
          <th>配置键</th>
          <th>当前生效值</th>
          <th>配置来源</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td class="mono">APP_TITLE</td>
          <td>{{ config.title }}</td>
          <td>{{ formatSourceLabel(config.sources.title) }}</td>
        </tr>
        <tr>
          <td class="mono">APP_VERSION</td>
          <td class="mono">{{ config.version }}</td>
          <td>{{ formatSourceLabel(config.sources.version) }}</td>
        </tr>
        <tr>
          <td class="mono">APP_ENV</td>
          <td class="mono">{{ config.env }}</td>
          <td>{{ formatSourceLabel(config.sources.env) }}</td>
        </tr>
        <tr>
          <td class="mono">APP_API_BASE_URL</td>
          <td class="mono">{{ config.apiBaseUrl }}</td>
          <td>{{ formatSourceLabel(config.sources.apiBaseUrl) }}</td>
        </tr>
      </tbody>
    </table>
  </section>
</template>
