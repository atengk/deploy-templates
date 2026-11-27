/**
 * 参考应用启动入口，挂载全局样式、SPA 路由器与根组件。
 *
 * @author Ateng
 * @since 2026-11-27
 */
import { createApp } from 'vue';
import App from './App.vue';
import { createAppRouter } from './router';
import './style.css';

const app = createApp(App);
const router = createAppRouter();

app.use(router);
app.mount('#app');
