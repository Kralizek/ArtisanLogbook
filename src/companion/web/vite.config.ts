import react from "@vitejs/plugin-react";
import { defineConfig } from "vitest/config";
import { localApiProxy } from "./dev-proxy.ts";

export default defineConfig({
  plugins: [localApiProxy(process.env.COMPANION_URL), react()],
  server: {
    host: "127.0.0.1",
    port: Number(process.env.PORT ?? 5173),
    strictPort: true,
    cors: false,
    allowedHosts: ["127.0.0.1", "localhost"],
    watch: {
      usePolling: process.env.VITE_USE_POLLING === "true",
      interval: 300,
    },
    proxy: process.env.COMPANION_URL
      ? {
          "^/(graphql(?:\\?|$)|api(?:/|\\?|$))": {
            target: process.env.COMPANION_URL,
            changeOrigin: true,
          },
        }
      : undefined,
  },
  test: {
    environment: "jsdom",
    setupFiles: ["src/test-setup.ts"],
    restoreMocks: true,
  },
});
