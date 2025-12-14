import React, { useCallback, useEffect, useRef, useState } from "react";
import OriginalSearchBar from "@theme-original/SearchBar";

export default function SearchBarWrapper(props) {
    const wrapperRef = useRef(null);
    const [active, setActive] = useState(false);

    const syncActive = useCallback(() => {
        const wrapper = wrapperRef.current;
        if (!wrapper) return;
        setActive(wrapper.contains(document.activeElement));
    }, []);

    useEffect(() => {
        syncActive();
        document.addEventListener("focusin", syncActive);
        document.addEventListener("focusout", syncActive);
        return () => {
            document.removeEventListener("focusin", syncActive);
            document.removeEventListener("focusout", syncActive);
        };
    }, [syncActive]);

    useEffect(() => {
        const root = document.documentElement;
        root.classList.toggle("sydra-search-active", active);
        return () => root.classList.remove("sydra-search-active");
    }, [active]);

    const close = useCallback((event) => {
        event?.preventDefault?.();
        event?.stopPropagation?.();
        const input = wrapperRef.current?.querySelector("input.navbar__search-input");
        input?.blur();
    }, []);

    useEffect(() => {
        if (!active) return;

        const onKeyDown = (event) => {
            if (event.key === "Escape") close(event);
        };
        window.addEventListener("keydown", onKeyDown);
        return () => window.removeEventListener("keydown", onKeyDown);
    }, [active, close]);

    return (
        <>
            {active ? <div className="sydraSearchOverlay" onMouseDown={close} /> : null}
            <span ref={wrapperRef} className="sydraSearchWrapper">
                <OriginalSearchBar {...props} />
            </span>
        </>
    );
}

