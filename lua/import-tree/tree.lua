-- Expandable tree of importers in a right-hand split, drawn upward: the
-- file the tree was opened from sits at the bottom and each layer of
-- importers stacks above the file it imports, so moving up the buffer
-- is moving up the graph and pages end up at the top. Children are
-- fetched the first time a node is expanded, so the cost is one lookup
-- per layer actually looked at.

local M = {}

local core = require("import-tree")
local int = core._internals

local ns = vim.api.nvim_create_namespace("import-tree")
local WIDTH = 40

-- One tree at a time. Reopening from another file re-roots it.
local state

local function node_new(path, pos, depth)
	return {
		path = path,
		-- Where this file imports (or uses) the node below it in the tree.
		pos = pos,
		depth = depth,
		children = nil, -- nil = not fetched yet, {} = nothing imports it
		expanded = false,
		loading = false,
		failed = false,
		ceiling = depth > 0 and int.matches(state.opts.ceiling, path, depth) or false,
	}
end

-- Sorted like the pickers: pages first, then by name.
local function fetch(node, cb)
	if node.children then
		return cb(node.children)
	end
	-- Already fetching; that fetch renders when it lands.
	if node.loading then
		return
	end
	-- vtsls may have been restarted since the tree opened.
	if state.client:is_stopped() then
		local client = int.live_client(state.bufnr)
		if not client then
			node.failed = true
			node.children = {}
			return cb(node.children)
		end
		state.client = client
	end
	node.loading = true
	M._render()
	int.importers_of(state.client, state.bufnr, node.path, state.opts, node.depth + 1, function(importers, failed)
		node.loading = false
		node.failed = failed > 0
		local children = {}
		for _, imp in ipairs(importers) do
			table.insert(children, node_new(imp.path, { imp.lnum, imp.col }, node.depth + 1))
		end
		table.sort(children, function(a, b)
			if a.ceiling ~= b.ceiling then
				return a.ceiling
			end
			return a.path < b.path
		end)
		node.children = children
		cb(children)
	end)
end

local function rel_dir(path)
	local dir = vim.fn.fnamemodify(path, ":h")
	local root = state.root_dir
	if root and dir == root then
		return ""
	elseif root and dir:sub(1, #root + 1) == root .. "/" then
		dir = dir:sub(#root + 2)
	end
	-- Everything up to the app's `src/` is the same for every row. The
	-- slashes added around `dir` let a leading `src` or a directory that
	-- is `src` itself match too.
	local under_src = ("/" .. dir .. "/"):match("^.-/src/(.*)$")
	if under_src then
		return (under_src:gsub("/$", ""))
	end
	return dir
end

local function icon(node)
	if node.loading then
		return "…", "Comment"
	elseif node.children and #node.children == 0 then
		return "·", "Comment"
	elseif node.ceiling then
		return node.expanded and "◉" or "●", "DiagnosticOk"
	elseif node.expanded then
		return "▴", "Special"
	end
	return "▸", "Special"
end

--- Rebuilds the buffer from the tree, keeping the cursor on its node.
function M._render()
	local s = state
	if not (s and s.buf and vim.api.nvim_buf_is_valid(s.buf)) then
		return
	end
	local cur = M._node_at_cursor()
	local lines, marks, rows = {}, {}, {}

	-- Importers are emitted before (above) the file they import, in
	-- sorted order, so reading top-down within a group still gives
	-- pages first.
	local function walk(node, indent)
		if node.expanded and node.children then
			for _, child in ipairs(node.children) do
				walk(child, indent + 1)
			end
		end
		local ic, ic_hl = icon(node)
		local name = vim.fn.fnamemodify(node.path, ":t")
		local prefix = ("%s%s "):format(("  "):rep(indent), ic)
		local line = prefix .. name
		local tail
		if node.failed then
			tail = "lookup failed"
		elseif node.children and #node.children == 0 then
			tail = "root"
		elseif node.ceiling then
			tail = "page"
		end
		table.insert(lines, line)
		table.insert(rows, node)
		local row = #lines - 1
		table.insert(marks, { row, #prefix - #ic - 1, { end_col = #prefix - 1, hl_group = ic_hl } })
		if indent == 0 then
			table.insert(marks, { row, #prefix, { end_col = #line, hl_group = "Title" } })
		end
		table.insert(marks, {
			row,
			0,
			{
				virt_text = {
					{ rel_dir(node.path), "Comment" },
					tail and { "  " .. tail, node.failed and "DiagnosticError" or "Comment" } or { "" },
				},
				virt_text_pos = "eol",
			},
		})
	end
	walk(s.root, 0)

	vim.bo[s.buf].modifiable = true
	vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
	vim.bo[s.buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
	for _, m in ipairs(marks) do
		vim.api.nvim_buf_set_extmark(s.buf, ns, m[1], m[2], m[3])
	end
	s.rows = rows

	if s.win and vim.api.nvim_win_is_valid(s.win) then
		local target = #rows -- the root, on the bottom line
		for i, node in ipairs(rows) do
			if node == cur then
				target = i
				break
			end
		end
		vim.api.nvim_win_set_cursor(s.win, { target, 0 })
	end
end

function M._node_at_cursor()
	local s = state
	if not (s and s.win and vim.api.nvim_win_is_valid(s.win) and s.rows) then
		return
	end
	return s.rows[vim.api.nvim_win_get_cursor(s.win)[1]]
end

local function parent_of(node)
	local function find(n)
		for _, c in ipairs(n.children or {}) do
			if c == node then
				return n
			end
			local p = n.expanded and find(c)
			if p then
				return p
			end
		end
	end
	return find(state.root)
end

local function goto_node(node)
	for i, n in ipairs(state.rows) do
		if n == node then
			vim.api.nvim_win_set_cursor(state.win, { i, 0 })
			return
		end
	end
end

local function expand(node, cb)
	fetch(node, function(children)
		if #children == 0 then
			M._render()
			if cb then
				cb()
			end
			return
		end
		node.expanded = true
		M._render()
		if cb then
			cb()
		end
	end)
end

-- Window-local options `ensure_win` sets on the tree window.
local TREE_WIN_OPTS = {
	"number",
	"relativenumber",
	"signcolumn",
	"foldcolumn",
	"wrap",
	"cursorline",
	"winfixwidth",
	"list",
	"statuscolumn",
}

local function in_this_tab(win)
	return win
		and vim.api.nvim_win_is_valid(win)
		and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
end

local function is_float(win)
	return vim.api.nvim_win_get_config(win).relative ~= ""
end

-- The window files open in: whatever was current when the tree opened,
-- or the first regular non-tree window if that one is gone, or a new
-- split if there is none.
local function target_win()
	local s = state
	if in_this_tab(s.prev_win) and s.prev_win ~= s.win and not is_float(s.prev_win) then
		return s.prev_win
	end
	for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if w ~= s.win and not is_float(w) then
			s.prev_win = w
			return w
		end
	end
	-- The split copies the tree window's options, so put back the
	-- global values, and give the tree its width back.
	local win
	vim.api.nvim_win_call(s.win, function()
		vim.cmd("topleft vsplit")
		win = vim.api.nvim_get_current_win()
	end)
	for _, opt in ipairs(TREE_WIN_OPTS) do
		vim.wo[win][0][opt] = vim.api.nvim_get_option_value(opt, { scope = "global" })
	end
	vim.api.nvim_win_set_width(s.win, WIDTH)
	s.prev_win = win
	return win
end

-- LSP columns count in the server's encoding (UTF-16 for vtsls); the
-- cursor wants bytes.
local function byte_col(buf, lnum, col)
	local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1]
	if not line then
		return col
	end
	local encoding = state.client and state.client.offset_encoding or "utf-16"
	local ok, byte = pcall(vim.str_byteindex, line, encoding, col, false)
	return ok and byte or col
end

local function open_node(node, stay)
	local win = target_win()
	vim.api.nvim_win_call(win, function()
		vim.cmd.edit(vim.fn.fnameescape(node.path))
		if node.pos then
			local lnum = node.pos[1]
			pcall(vim.api.nvim_win_set_cursor, 0, { lnum, byte_col(0, lnum, node.pos[2]) })
			vim.cmd("normal! zz")
		end
	end)
	if not stay then
		vim.api.nvim_set_current_win(win)
	end
end

local function reroot(node)
	state.root = node_new(node.path, nil, 0)
	expand(state.root)
end

local actions = {}

function actions.expand()
	local node = M._node_at_cursor()
	if not node then
		return
	end
	if node.expanded then
		return
	end
	expand(node)
end

function actions.collapse()
	local node = M._node_at_cursor()
	if not node then
		return
	end
	if node.expanded then
		node.expanded = false
		M._render()
		return
	end
	local parent = parent_of(node)
	if parent then
		goto_node(parent)
	end
end

function actions.open()
	local node = M._node_at_cursor()
	if node then
		open_node(node, false)
	end
end

function actions.preview()
	local node = M._node_at_cursor()
	if node then
		open_node(node, true)
	end
end

function actions.reroot()
	local node = M._node_at_cursor()
	if node then
		reroot(node)
	end
end

function actions.close()
	M.close()
end

local keys = {
	["l"] = "expand",
	["<cr>"] = "expand",
	["<right>"] = "expand",
	["h"] = "collapse",
	["<left>"] = "collapse",
	["o"] = "open",
	["p"] = "preview",
	["r"] = "reroot",
	["q"] = "close",
	["<c-j>"] = "j",
	["<c-k>"] = "k",
}

local function ensure_buf()
	local s = state
	-- A `:bdelete`d buffer is still valid but unloaded, and Neovim reset
	-- its options and dropped its keymaps, so it has to be rebuilt.
	if s.buf and vim.api.nvim_buf_is_valid(s.buf) and vim.api.nvim_buf_is_loaded(s.buf) then
		return
	end
	if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
		vim.api.nvim_buf_delete(s.buf, { force = true })
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "import-tree"
	vim.bo[buf].modifiable = false
	vim.api.nvim_buf_set_name(buf, "import-tree://importers")
	for lhs, rhs in pairs(keys) do
		if actions[rhs] then
			vim.keymap.set("n", lhs, actions[rhs], { buffer = buf, nowait = true, desc = "import-tree: " .. rhs })
		else
			vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true })
		end
	end
	s.buf = buf
end

local function ensure_win()
	local s = state
	if in_this_tab(s.win) then
		vim.api.nvim_set_current_win(s.win)
		return
	end
	-- Open in another tab: move it here rather than jumping there.
	M.close()
	s.prev_win = vim.api.nvim_get_current_win()
	vim.cmd(("vertical botright %dsplit"):format(WIDTH))
	s.win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(s.win, s.buf)
	-- `[0]` sets them like `:setlocal`; plain `vim.wo[win]` would also
	-- overwrite the user's global values.
	-- Keep in sync with TREE_WIN_OPTS.
	local wo = vim.wo[s.win][0]
	wo.number = false
	wo.relativenumber = false
	wo.signcolumn = "no"
	wo.foldcolumn = "0"
	wo.wrap = false
	wo.cursorline = true
	wo.winfixwidth = true
	wo.list = false
	wo.statuscolumn = ""
end

function M.close()
	if state and state.win and vim.api.nvim_win_is_valid(state.win) then
		-- Fails when the tree is the last window; leave it showing an
		-- empty buffer instead.
		if not pcall(vim.api.nvim_win_close, state.win, true) then
			vim.api.nvim_win_set_buf(state.win, vim.api.nvim_create_buf(true, false))
		end
	end
	if state then
		state.win = nil
	end
end

--- Whether the tree is showing in the current tab.
function M.is_open()
	return state and in_this_tab(state.win) or false
end

--- Opens the tree rooted at the current buffer's file. Called from the
--- tree window itself, closes it instead.
function M.open(overrides)
	if M.is_open() and vim.api.nvim_get_current_win() == state.win then
		return M.close()
	end
	local client, bufnr, opts, start = int.start_from(0, overrides)
	if not client then
		return
	end
	state = state or {}
	state.client, state.bufnr, state.opts = client, bufnr, opts
	state.root_dir = vim.fs.root(start, ".git")
	state.root = node_new(start, nil, 0)
	ensure_buf()
	ensure_win()
	expand(state.root)
end

--- Toggle: closes when open, otherwise opens from the current buffer.
function M.toggle(overrides)
	if M.is_open() then
		return M.close()
	end
	M.open(overrides)
end

return M
