// @ts-check
// `@type` JSDoc annotations allow editor autocompletion and type checking
// (when paired with `@ts-check`).
// See: https://docusaurus.io/docs/api/docusaurus-config

import {themes as prismThemes} from 'prism-react-renderer';

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'ClipSlop',
  tagline: 'Select text. Press a hotkey. Grammar fixed.',
  favicon: 'img/favicon.png',

  // Future flags — see https://docusaurus.io/docs/api/docusaurus-config#future
  // v4 turns on every Docusaurus v4 preparation flag at once
  // (siteStorageNamespacing, fasterByDefault, mdx1CompatDisabledByDefault).
  // `faster` enables the new Rspack/SWC/LightningCSS build pipeline.
  future: {
    v4: true,
    faster: true,
  },

  // Production URL and base path for GitHub Pages (project site at
  // https://mekedron.github.io/ClipSlop/). The canonical repo slug on GitHub
  // is `ClipSlop` (case-sensitive in the Pages path), even though `clipslop`
  // also resolves via GitHub's redirect.
  url: 'https://mekedron.github.io',
  baseUrl: '/ClipSlop/',
  trailingSlash: false,

  // GitHub Pages deployment config.
  organizationName: 'mekedron',
  projectName: 'ClipSlop',
  deploymentBranch: 'gh-pages',

  onBrokenLinks: 'throw',
  markdown: {
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },

  i18n: {
    defaultLocale: 'en',
    locales: ['en'],
  },

  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: {
          // Markdown lives at the repo root in `docs/`, while this
          // Docusaurus app lives in `docs-site/`. The path is resolved
          // relative to the Docusaurus root.
          path: '../docs',
          sidebarPath: './sidebars.js',
          routeBasePath: 'docs',
          editUrl: 'https://github.com/mekedron/ClipSlop/tree/main/docs/',
          // Internal scratch doc — not part of the published site.
          exclude: ['**/initial-prompt.md'],
        },
        // No blog — this site is documentation only.
        blog: false,
        theme: {
          customCss: './src/css/custom.css',
        },
      }),
    ],
  ],

  themeConfig:
    /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
    ({
      image: 'img/screenshot.png',
      colorMode: {
        respectPrefersColorScheme: true,
      },
      navbar: {
        title: 'ClipSlop',
        logo: {
          alt: 'ClipSlop icon',
          src: 'img/logo.png',
        },
        items: [
          {
            type: 'docSidebar',
            sidebarId: 'tutorialSidebar',
            position: 'left',
            label: 'Documentation',
          },
          {
            to: '/docs/getting-started',
            label: 'Getting Started',
            position: 'left',
          },
          {
            to: '/docs/built-in-prompts',
            label: 'Prompts',
            position: 'left',
          },
          {
            href: 'https://github.com/mekedron/ClipSlop/releases/latest',
            label: 'Download',
            position: 'right',
          },
          {
            href: 'https://github.com/mekedron/ClipSlop',
            label: 'GitHub',
            position: 'right',
          },
        ],
      },
      footer: {
        style: 'dark',
        links: [
          {
            title: 'Docs',
            items: [
              {label: 'Introduction', to: '/docs/intro'},
              {label: 'Getting Started', to: '/docs/getting-started'},
              {label: 'Built-in Prompts', to: '/docs/built-in-prompts'},
              {label: 'Keyboard Shortcuts', to: '/docs/keyboard-shortcuts'},
            ],
          },
          {
            title: 'Project',
            items: [
              {
                label: 'GitHub',
                href: 'https://github.com/mekedron/ClipSlop',
              },
              {
                label: 'Releases',
                href: 'https://github.com/mekedron/ClipSlop/releases',
              },
              {
                label: 'Issues',
                href: 'https://github.com/mekedron/ClipSlop/issues',
              },
            ],
          },
          {
            title: 'Support',
            items: [
              {
                label: 'Buy Me a Coffee',
                href: 'https://buymeacoffee.com/mekedron',
              },
            ],
          },
        ],
        copyright: `ClipSlop is free and open source. © ${new Date().getFullYear()} · MIT License.`,
      },
      prism: {
        theme: prismThemes.github,
        darkTheme: prismThemes.dracula,
      },
    }),
};

export default config;
