import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
  assetsInclude: ['**/*.dmg'],
  plugins: [sveltekit()]
});
