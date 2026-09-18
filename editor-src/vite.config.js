import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { viteSingleFile } from 'vite-plugin-singlefile'

// 打成「单文件 HTML」：所有 JS/CSS 内联。
// 这样 WKWebView 用 loadFileURL 直接加载即可，绕开 file:// 下 ES module / CORS 的限制。
export default defineConfig({
  plugins: [react(), viteSingleFile()],
  base: './',
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    cssCodeSplit: false,
    assetsInlineLimit: 100000000,
    chunkSizeWarningLimit: 8000,
    rollupOptions: {
      output: { inlineDynamicImports: true }
    }
  }
})
