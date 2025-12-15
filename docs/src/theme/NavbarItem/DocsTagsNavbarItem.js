import React from "react";
import { DEFAULT_PLUGIN_ID } from "@docusaurus/constants";
import {
    useActivePluginAndVersion,
    useDocsPreferredVersion,
    useLatestVersion,
} from "@docusaurus/plugin-content-docs/client";
import DefaultNavbarItem from "@theme/NavbarItem/DefaultNavbarItem";

export default function DocsTagsNavbarItem(props) {
    const active = useActivePluginAndVersion();
    const { preferredVersion } = useDocsPreferredVersion(DEFAULT_PLUGIN_ID);
    const latestVersion = useLatestVersion(DEFAULT_PLUGIN_ID);

    const tagsPath =
        active?.activeVersion?.tagsPath ??
        preferredVersion?.tagsPath ??
        latestVersion?.tagsPath ??
        "/docs/tags";

    return <DefaultNavbarItem {...props} to={tagsPath} />;
}
