import { defineConfig } from 'vitepress'
import intentSidebar from './generated/intent-sidebar.json' with { type: 'json' }

const REPO = 'https://github.com/nguyenvanduocit/tenon'

export default defineConfig({
  title: 'Tenon',
  description:
    'The human supervision layer for parallel CLI-agent work. A native macOS terminal workspace where agents keep their own harness and you keep the judgment.',
  lang: 'en-US',

  // Fail the build on a link to a page that does not exist, rather than
  // shipping it. Documentation that lies about its own structure is worse
  // than documentation that refuses to build.
  ignoreDeadLinks: false,

  // README.md here is for whoever maintains this site, not for its readers.
  // VitePress renders every Markdown file under the source root, so without
  // this it ships as a public page at /README.
  srcExclude: ['README.md'],

  lastUpdated: true,
  cleanUrls: true,

  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/mark.svg' }],
    ['meta', { name: 'theme-color', content: '#E6A33A' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:title', content: 'Tenon — supervise parallel coding agents' }],
    [
      'meta',
      {
        property: 'og:description',
        content:
          'A native macOS terminal workspace for people running several CLI coding agents at once.',
      },
    ],
  ],

  // The sitemap tells search engines which URLs exist, so it has to name the
  // host that actually serves them. Set SITE_URL when a custom domain lands;
  // until then this is where the site really is, and a sitemap pointing at a
  // domain nobody owns is worse than no sitemap.
  sitemap: { hostname: process.env.SITE_URL ?? 'https://tenon-docs.pages.dev' },

  themeConfig: {
    logo: '/mark.svg',

    nav: [
      { text: 'Guide', link: '/guide/what-is-tenon', activeMatch: '/guide/' },
      { text: 'Concepts', link: '/concepts/', activeMatch: '/concepts/' },
      { text: 'Plugins', link: '/plugins/', activeMatch: '/plugins/' },
      { text: 'Reference', link: '/reference/cli', activeMatch: '/reference/' },
      {
        text: 'pre-alpha',
        items: [
          { text: 'Releases', link: `${REPO}/releases` },
          { text: 'Changelog', link: `${REPO}/blob/main/CHANGELOG.md` },
          { text: 'Vision', link: `${REPO}/blob/main/VISION.md` },
        ],
      },
    ],

    sidebar: {
      '/guide/': [
        {
          text: 'Start here',
          items: [
            { text: 'What Tenon is', link: '/guide/what-is-tenon' },
            { text: 'Install', link: '/guide/install' },
            { text: 'Your first workspace', link: '/guide/first-workspace' },
          ],
        },
        {
          text: 'Using Tenon',
          items: [
            { text: 'Workspaces, tabs, panes', link: '/guide/workspaces-tabs-panes' },
            { text: 'Keyboard and pointer', link: '/guide/keyboard' },
            { text: 'Running agents in panes', link: '/guide/running-agents' },
            { text: 'Agent Lens', link: '/guide/agent-lens' },
            { text: 'The command palette', link: '/guide/command-palette' },
            { text: 'Managing plugins', link: '/guide/managing-plugins' },
            { text: 'Driving Tenon from a terminal', link: '/guide/cli' },
          ],
        },
        {
          text: 'When something is wrong',
          items: [{ text: 'Troubleshooting', link: '/guide/troubleshooting' }],
        },
      ],

      '/concepts/': [
        {
          text: 'Concepts',
          items: [
            { text: 'Overview', link: '/concepts/' },
            { text: 'Supervision, not orchestration', link: '/concepts/supervision' },
            { text: 'The spatial canvas', link: '/concepts/spatial-canvas' },
            { text: 'The intent bus', link: '/concepts/intent-bus' },
            { text: 'The plugin boundary', link: '/concepts/plugin-boundary' },
            { text: 'Evidence and claims', link: '/concepts/evidence' },
          ],
        },
      ],

      '/plugins/': [
        {
          text: 'Writing a plugin',
          items: [
            { text: 'Overview', link: '/plugins/' },
            { text: 'Quickstart', link: '/plugins/quickstart' },
            { text: 'The manifest', link: '/plugins/manifest' },
            { text: 'Choosing a mechanism', link: '/plugins/choosing-a-mechanism' },
          ],
        },
        {
          text: 'Building blocks',
          items: [
            { text: 'Sending intents', link: '/plugins/sending-intents' },
            { text: 'Providing intents', link: '/plugins/providing-intents' },
            { text: 'Events', link: '/plugins/events' },
            { text: 'Views', link: '/plugins/views' },
            { text: 'Palette contributions', link: '/plugins/palette' },
            { text: 'Settings and storage', link: '/plugins/settings-and-storage' },
            { text: 'Resources and lifetime', link: '/plugins/resources' },
            { text: 'Automations', link: '/plugins/automations' },
            { text: 'Starting agents', link: '/plugins/starting-agents' },
          ],
        },
        {
          text: 'Shipping',
          items: [
            { text: 'Hot reload and generations', link: '/plugins/hot-reload' },
            { text: 'Distributing a plugin', link: '/plugins/distributing' },
          ],
        },
      ],

      '/reference/': [
        {
          text: 'Reference',
          items: [
            { text: 'tenon-cli', link: '/reference/cli' },
            { text: 'The tenon global', link: '/reference/tenon-global' },
            { text: 'Manifest schema', link: '/reference/manifest-schema' },
            { text: 'Permissions', link: '/reference/permissions' },
            { text: 'Environment variables', link: '/reference/environment' },
            { text: 'Errors', link: '/reference/errors' },
          ],
        },
        {
          text: 'Intents',
          collapsed: false,
          items: [{ text: 'All intents', link: '/reference/intents/' }, ...intentSidebar],
        },
      ],
    },

    socialLinks: [{ icon: 'github', link: REPO }],

    editLink: {
      pattern: `${REPO}/edit/main/website/:path`,
      text: 'Edit this page on GitHub',
    },

    search: {
      provider: 'local',
      options: {
        detailedView: true,
      },
    },

    outline: { level: [2, 3] },

    footer: {
      message:
        'Pre-alpha. Interfaces still change between builds. Released under the terms in the repository.',
      copyright: `<a href="${REPO}">github.com/nguyenvanduocit/tenon</a>`,
    },
  },
})
