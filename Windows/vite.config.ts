import { defineConfig } from "vite";

export default defineConfig({
  build: {
    rollupOptions: {
      input: {
        main: "index.html",
        workbench: "workbench.html",
        companion: "companion.html"
      }
    }
  }
});
