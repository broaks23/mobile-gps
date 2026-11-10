import { defineConfig } from 'vite';

export default defineConfig({
  base: './',
  plugins: [{
    name: 'empty-local-region-catalog',
    configureServer(server) {
      server.middlewares.use('/config.json', (_request, response) => {
        response.setHeader('Content-Type', 'application/json; charset=utf-8');
        response.setHeader('Cache-Control', 'no-store');
        response.end('{"regions":[]}');
      });
    },
  }],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    assetsInlineLimit: 0,
    target: 'es2022',
    rollupOptions: {
      output: {
        entryFileNames: 'assets/renderer.js',
        assetFileNames: 'assets/[name][extname]',
      },
    },
  },
});
