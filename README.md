# import-tree

Shows where the file you're in ends up. Press `<leader>cp` in a component
and a tree opens on the right with that file on the bottom line and
everything that imports it stacked above. Expand upward until you reach a
page. It follows explicit imports and auto-registered components alike, so
it works across a Vue/TypeScript project in `.vue`, `.ts`, and `.tsx` buffers.

https://github.com/user-attachments/assets/eed44d63-ba70-468c-be9e-271b8e873cc2

Built on vtsls's `typescript.findAllFileReferences` rather than call
hierarchy: a component used in a template is an import plus a property
lookup, never a "call".

## Workflow

1. `<leader>cp` opens the tree from the current file. Its direct importers
   are already listed above it.
2. `j` / `k` move. Up on screen is up the graph.
3. `l` (or `<cr>`) expands a row: its importers appear above it, one level
   further in.
4. Pages are `●` and sort to the top of each group. The dim text on the
   right is the directory under `src/`, so `pages/receiving` and
   `pages/floor/receiving` tell apart.
5. `o` opens the row's file in your editing window with the cursor on the
   line that uses the node below it, so from a page row you land on the
   `<my-component />` tag. `p` does the same but keeps focus in the tree,
   handy for stepping through rows and watching the editor follow.
6. `h` collapses an expanded row; on a collapsed row it jumps to the parent
   below.
7. `r` re-roots on the row under the cursor. `q` or `<leader>cp` closes.

## Keys

| Key                          | Action                                        |
| ---------------------------- | --------------------------------------------- |
| `j` / `k`, `<c-j>` / `<c-k>` | move                                          |
| `l`, `<cr>`, `→`             | expand (fetches importers on first expand)    |
| `h`, `←`                     | collapse; on a collapsed row, go to parent    |
| `o`                          | open file in the editing window, on the usage |
| `p`                          | same, but stay in the tree                    |
| `r`                          | re-root the tree on this row                  |
| `q`                          | close                                         |

## Markers

| Marker          | Meaning                                                      |
| --------------- | ------------------------------------------------------------ |
| `▸` / `▴`       | collapsed / expanded                                         |
| `●` / `◉`       | page, collapsed / expanded (expanding one shows the router)  |
| `·` `root`      | nothing imports this file                                    |
| `…`             | lookup in progress                                           |
| `lookup failed` | vtsls errored; try `r` on it, or `<leader>lt` to restart tsserver |

## Install

Requires Neovim 0.11+ and vtsls attached to the buffer. With lazy.nvim,
from a local checkout:

```lua
{
	dir = vim.fn.expand("~/repos/personal/import-tree.nvim"),
	keys = {
		{ "<leader>cp", function() require("import-tree").tree() end, desc = "Importer tree (upward)" },
	},
	opts = {
		-- Per-project settings, keyed by a Lua pattern matched against the
		-- repo root (so worktrees are covered).
		projects = {
			["my%-app"] = { ceiling = { "/src/pages/" } },
		},
	},
}
```

`opts.defaults` overrides the defaults below for every project; a
project's entries override those. The first matching pattern wins. In a
map, longer patterns are tried first; to set the order yourself, pass a
list of `{ pattern, opts }` pairs instead.

## Config

Defaults, in `lua/import-tree/init.lua`:

| Option              | Default                                | Meaning                                                  |
| ------------------- | -------------------------------------- | -------------------------------------------------------- |
| `ceiling`           | `{}`                                   | Files marked as pages (`●`, sorted first)                |
| `ignore`            | `spec`, `test`, `stories` files        | Never listed as importers                                |
| `global_components` | `components.d.ts`                      | Generated declarations to resolve through (see below)    |

Each may be a list of Lua patterns against the absolute path, or a
`function(path, depth) -> boolean`.

## Things to know

- Each layer is one tsserver lookup, and a lookup vtsls doesn't answer
  within 15 seconds shows `lookup failed`. The first time a session touches an
  auto-registered component it waits a second or two for `components.d.ts`
  to load; after that each layer is quick and results are cached until you
  close the tree.
- vtsls insists on opening each file it looks up, so after a session `:ls!`
  lists them as hidden, unlisted buffers. Harmless.
- Composables show up as layers (`Page → useOrdersTable.ts → TableCell`)
  when they import a component, e.g. for a column renderer.

## How it works

- `init.lua`: one-level lookup (`importers_of`), config, and the vtsls
  plumbing. `tree.lua`: the buffer, rendering, and keys.
- An auto-registered component's only "importer" is its entry in the
  generated `components.d.ts`. Template usages resolve through that entry,
  so when a lookup lands there, the tree runs `textDocument/references` on
  the entry instead and lists those files.
- `findAllFileReferences` mirrors VS Code's command, which opens the file
  being looked up before finding its references, so vtsls sends a
  `window/showDocument` for every lookup and reads the language id off the
  document that opens. While a lookup is in flight the file is loaded into
  a hidden buffer instead of shown, which is what leaves the unlisted
  buffers behind.
