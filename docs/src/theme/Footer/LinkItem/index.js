import React from "react";
import clsx from "clsx";
import Link from "@docusaurus/Link";
import useBaseUrl from "@docusaurus/useBaseUrl";
import isInternalUrl from "@docusaurus/isInternalUrl";
import IconExternalLink from "@theme/Icon/ExternalLink";
import { DEFAULT_PLUGIN_ID } from "@docusaurus/constants";
import {
    useActivePluginAndVersion,
    useDocsPreferredVersion,
    useLatestVersion,
} from "@docusaurus/plugin-content-docs/client";

export default function FooterLinkItem({ item }) {
    const { to, href, label, prependBaseUrlToHref, className, ...props } = item;

    const active = useActivePluginAndVersion();
    const { preferredVersion } = useDocsPreferredVersion(DEFAULT_PLUGIN_ID);
    const latestVersion = useLatestVersion(DEFAULT_PLUGIN_ID);

    const resolvedTo =
        to === "/docs/tags"
            ? active?.activeVersion?.tagsPath ??
              preferredVersion?.tagsPath ??
              latestVersion?.tagsPath ??
              to
            : to;

    const toUrl = useBaseUrl(resolvedTo);
    const normalizedHref = useBaseUrl(href, { forcePrependBaseUrl: true });

    return (
        <Link
            className={clsx("footer__link-item", className)}
            {...(href
                ? {
                      href: prependBaseUrlToHref ? normalizedHref : href,
                  }
                : {
                      to: toUrl,
                  })}
            {...props}
        >
            {label}
            {href && !isInternalUrl(href) && <IconExternalLink />}
        </Link>
    );
}
