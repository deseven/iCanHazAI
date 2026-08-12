// Tree overview mode: a full-cover layer showing the conversation as a tree
// of its splitting points, rendered by our own TreeView (see treeLayout.ts /
// TreeView.ts). The host sends the nested `TreeNode` projection directly; each
// node is a drawn card, and everything between drawn nodes collapses into a
// "{n} messages" badge on the card (via the node's `messageCount`).
import { useEffect, useRef } from "preact/hooks";
import { X } from "lucide-preact";
import type { TreeNode } from "../types";
import { sendToHost } from "../bridge";
import { TreeView } from "./TreeView";

interface Props {
    root: TreeNode | null;
    onClose: () => void;
}

export function TreeOverview({ root, onClose }: Props) {
    const containerRef = useRef<HTMLDivElement>(null);
    const viewRef = useRef<TreeView | null>(null);

    // (Re)render the tree whenever the root changes.
    useEffect(() => {
        if (!root || !containerRef.current) return;
        const view = new TreeView(containerRef.current, {
            onNodeClick: (id) => sendToHost({ type: "gotoMessage", messageId: id }),
        });
        view.render(root);
        viewRef.current = view;
        return () => {
            viewRef.current?.destroy();
            viewRef.current = null;
        };
    }, [root]);

    // Escape closes the overview.
    useEffect(() => {
        const onKey = (e: KeyboardEvent) => {
            if (e.key === "Escape") {
                e.preventDefault();
                e.stopPropagation();
                onClose();
            }
        };
        window.addEventListener("keydown", onKey, true);
        return () => window.removeEventListener("keydown", onKey, true);
    }, [onClose]);

    if (!root) {
        return (
            <div class="tree-overview-overlay">
                <div class="tree-overview-empty">
                    <p>This chat has no branches yet.</p>
                    <p class="tree-overview-empty-hint">Regenerate or edit a message to create branches.</p>
                </div>
                <button type="button" class="tree-overview-close-btn" title="Close" onClick={onClose}>
                    <X size={16} />
                </button>
            </div>
        );
    }

    return (
        <div class="tree-overview-overlay">
            <div class="tree-overview-canvas" ref={containerRef} />
            <button type="button" class="tree-overview-close-btn" title="Close" onClick={onClose}>
                <X size={16} />
            </button>
        </div>
    );
}
