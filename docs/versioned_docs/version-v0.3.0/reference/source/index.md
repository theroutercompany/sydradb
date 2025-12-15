---
sidebar_position: 1
---

import React from "react";
import DocCardList from "@theme/DocCardList";
import {
    filterDocCardListItems,
    useCurrentSidebarCategory,
} from "@docusaurus/plugin-content-docs/client";
import { useLocation } from "@docusaurus/router";

export function BrowseByArea() {
    const { pathname } = useLocation();
    const items = filterDocCardListItems(useCurrentSidebarCategory().items).filter(
        (item) => item?.href !== pathname,
    );
    return <DocCardList items={items} />;
}

# Source reference

This section documents SydraDB’s source tree at the module level, with a focus on:

- What each file/module does
- Public surfaces and key internal helpers
- Key types, constants, and invariants
- How modules interact

This is written against the repository sources (e.g. `src/**`, `cmd/**`) without modifying them.

## Conventions used in these pages

- **Module path** refers to the repository-relative path, e.g. `src/sydra/server.zig`.
- **Public API** refers to `pub` declarations exported by the module.
- “Definitions” include: functions, structs/enums/unions, variables, and constants.

## Where to start

- For process startup and CLI routing: [Entrypoints](./entrypoints/src-main.md).
- For HTTP endpoints: [src/sydra/http.zig](./sydra/http.md).
- For core ingest/query mechanics: [src/sydra/engine.zig](./sydra/engine.md).

## Browse by area

<BrowseByArea />
