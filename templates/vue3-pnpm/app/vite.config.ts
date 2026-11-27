/**
 * 配置 Vite 构建与 Vitest 单元测试执行上下文。
 *
 * @author Ateng
 * @since 2026-11-27
 */
import { defineConfig } from 'vitest/config';
import vue from '@vitejs/plugin-vue';

export default defineConfig({
  plugins: [vue()],
  test: {
    environment: 'happy-dom',
    include: ['src/__tests__/**/*.spec.ts'],
  },
});
