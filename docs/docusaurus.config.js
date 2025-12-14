const prism = require("prism-react-renderer");
const lightCodeTheme = prism.themes.github;
const darkCodeTheme = prism.themes.dracula;

/** @type {import('@docusaurus/types').Config} */
const config = {
    title: "SydraDB",
    tagline: "A database engine written in Zig",
    favicon: "img/favicon.svg",

    url: "https://theroutercompany.github.io",
    baseUrl: "/sydradb/",

    organizationName: "theroutercompany",
    projectName: "sydradb",

    onBrokenLinks: "throw",
    markdown: {
        hooks: {
            onBrokenMarkdownLinks: "warn",
        },
    },

    i18n: {
        defaultLocale: "en",
        locales: ["en"],
    },

    presets: [
        [
            "classic",
            /** @type {import('@docusaurus/preset-classic').Options} */
            ({
                docs: {
                    sidebarPath: require.resolve("./sidebars.js"),
                    routeBasePath: "/docs",
                },
                blog: false,
                theme: {
                    customCss: require.resolve("./src/css/custom.css"),
                },
            }),
        ],
    ],

    themeConfig:
        /** @type {import('@docusaurus/preset-classic').ThemeConfig} */
        ({
            navbar: {
                title: "SydraDB",
                items: [
                    {
                        to: "/docs/intro",
                        label: "Docs",
                        position: "left",
                    },
                    {
                        href: "https://github.com/theroutercompany/sydradb",
                        label: "GitHub",
                        position: "right",
                    },
                ],
            },
            footer: {
                style: "dark",
                links: [
                    {
                        title: "Docs",
                        items: [
                            {
                                label: "Introduction",
                                to: "/docs/intro",
                            },
                        ],
                    },
                    {
                        title: "Links",
                        items: [
                            {
                                label: "Issues",
                                href: "https://github.com/theroutercompany/sydradb/issues",
                            },
                        ],
                    },
                ],
                copyright: `Copyright © ${new Date().getFullYear()} SydraDB`,
            },
            prism: {
                theme: lightCodeTheme,
                darkTheme: darkCodeTheme,
                additionalLanguages: ["zig"],
            },
        }),
};

module.exports = config;
