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

  // Hydrates the live GitHub star count in the navbar.
  // (Path is resolved relative to the Docusaurus site directory.)
  clientModules: ['./src/clientModules/github-stars.js'],

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
            to: '/docs/install',
            label: 'Install',
            position: 'left',
          },
          {
            to: '/docs/reference/built-in-prompts',
            label: 'Prompts',
            position: 'left',
          },
          {
            // Pill-styled Download button matching the GitHub and Donate
            // pills on the right. Anchors to the homepage's #download
            // section (the install block) so newcomers can compare
            // Homebrew vs .dmg before committing. Absolute path keeps
            // the link working from docs pages too — those routes don't
            // have a #download anchor of their own.
            type: 'html',
            position: 'right',
            value:
              '<a class="navbar-download" href="/ClipSlop/#download" aria-label="Jump to download options">' +
              '<svg class="navbar-download__icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
              '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path>' +
              '<polyline points="7 10 12 15 17 10"></polyline>' +
              '<line x1="12" y1="15" x2="12" y2="3"></line>' +
              '</svg>' +
              '<span class="navbar-download__label">Download</span>' +
              '</a>',
          },
          {
            // GitHub link with live star count, hydrated client-side by
            // src/clientModules/github-stars.js. The placeholder "—" is
            // what visitors see during the first paint and on offline /
            // rate-limited fetches. This pill doubles as the GitHub link
            // — no separate text-only "GitHub" entry, to keep the navbar
            // to four items on the right.
            type: 'html',
            position: 'right',
            value:
              '<a class="navbar-stars" href="https://github.com/mekedron/ClipSlop" target="_blank" rel="noopener noreferrer" aria-label="ClipSlop on GitHub — view repo and star count">' +
              '<svg class="navbar-stars__icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
              '<polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"></polygon>' +
              '</svg>' +
              '<span class="navbar-stars__label">GitHub</span>' +
              '<span class="navbar-stars__count" data-github-stars>—</span>' +
              '</a>',
          },
          {
            // Yellow Donate pill — primary call to support the project.
            // Styled in src/css/custom.css via .navbar-donate.
            type: 'html',
            position: 'right',
            value:
              '<a class="navbar-donate" href="https://buymeacoffee.com/mekedron" target="_blank" rel="noopener noreferrer" aria-label="Donate via Buy Me a Coffee">' +
              '<svg class="navbar-donate__icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
              '<path d="M18 8h1a4 4 0 0 1 0 8h-1"></path>' +
              '<path d="M2 8h16v9a4 4 0 0 1-4 4H6a4 4 0 0 1-4-4V8z"></path>' +
              '<line x1="6" y1="1" x2="6" y2="4"></line>' +
              '<line x1="10" y1="1" x2="10" y2="4"></line>' +
              '<line x1="14" y1="1" x2="14" y2="4"></line>' +
              '</svg>' +
              '<span class="navbar-donate__label">Donate</span>' +
              '</a>',
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
              {label: 'Install', to: '/docs/install'},
              {label: 'Built-in Prompts', to: '/docs/reference/built-in-prompts'},
              {label: 'Keyboard Map', to: '/docs/reference/keyboard-map'},
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
