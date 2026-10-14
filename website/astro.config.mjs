import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://qnot.ch',
  integrations: [sitemap()],
  devToolbar: { enabled: false },
});
