/**
 * 定义参考应用 SPA History 路由表与路由器创建工厂。
 *
 * @author Ateng
 * @since 2026-11-27
 */
import { createRouter, createWebHistory, type Router, type RouterHistory } from 'vue-router';
import OverviewView from '../views/OverviewView.vue';
import RuntimeView from '../views/RuntimeView.vue';
import RouteFallbackView from '../views/RouteFallbackView.vue';

/**
 * 创建参考应用路由实例，支持传入内存路由历史以实现无浏览器副作用的单元测试。
 *
 * @param history 可选路由历史实现，默认使用 HTML5 History 模式
 * @return 初始化完成路由规则的 Vue Router 实例
 */
export function createAppRouter(history?: RouterHistory): Router {
  return createRouter({
    history: history ?? createWebHistory(),
    routes: [
      {
        path: '/',
        name: 'overview',
        component: OverviewView,
      },
      {
        path: '/runtime',
        name: 'runtime',
        component: RuntimeView,
      },
      {
        path: '/:pathMatch(.*)*',
        name: 'spa-fallback',
        component: RouteFallbackView,
      },
    ],
  });
}
