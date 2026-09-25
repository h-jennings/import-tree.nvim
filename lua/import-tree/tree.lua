-- Expandable tree of importers in a bottom panel, drawn upward: the
-- file the tree was opened from sits at the bottom and each layer of
-- importers stacks above the file it imports, so moving up the buffer
-- is moving up the graph and pages end up at the top. Children are
-- fetched the first time a node is expanded, so the cost is one lookup
-- per layer actually looked at.
--
-- The window and the rows are drawn the way trouble.nvim draws its
-- list: same split, window options, highlight links, indent guides and
-- count badge, so the two panels look like one family.

local M = {}

local core = require("import-tree")
local int = core._internals

local ns = vim.api.nvim_create_namespace("import-tree")

-- One tree at a time. Reopening from another file re-roots it.
local state

-- Highlight groups, linked like trouble's (`Trouble*`) so a colorscheme
-- that styles one styles both.
-- stylua: ignore
local HIGHLIGHTS = {
	Normal           = "NormalFloat",
	NormalNC         = "NormalFloat",
	Filename         = "Directory",
	Root             = "Title",
	Page             = "DiagnosticOk",
	Directory        = "Comment",
	Tail             = "Comment",
	Failed           = "DiagnosticError",
	Count            = "TabLineSel",
	Loading          = "Comment",
	Indent           = "LineNr",
	IndentFoldClosed = "CursorLineNr",
	IndentFoldOpen   = "ImportTreeIndent",
	IndentTop        = "ImportTreeIndent",
	IndentMiddle     = "ImportTreeIndent",
	IndentFirst      = "ImportTreeIndent",
	IndentWs         = "ImportTreeIndent",
}

local function link_highlights()
	for name, target in pairs(HIGHLIGHTS) do
		vim.api.nvim_set_hl(0, "ImportTree" .. name, { link = target, default = true })
	end
end
link_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("import-tree.colorscheme", { clear = true }),
	callback = link_highlights,
})

-- File icons the way trouble picks them: mini.icons, else devicons,
-- else none. Providers that error are dropped for good.
local icon_providers = {
	function(name)
		return require("mini.icons").get("file", name)
	end,
	function(name, ext)
		return require("nvim-web-devicons").get_icon(name, ext, { default = true })
	end,
}
local function file_icon(path)
	local name = vim.fn.fnamemodify(path, ":t")
	local ext = vim.fn.fnamemodify(path, ":e")
	while #icon_providers > 0 do
		local ok, icon, hl = pcall(icon_providers[1], name, ext)
		if ok then
			return icon, hl
		end
		table.remove(icon_providers, 1)
	end
end

local WIN_DEFAULTS = { position = "bottom", size = nil }

local function win_opts()
	local win = vim.tbl_extend("force", WIN_DEFAULTS, state.opts.win or {})
	local horizontal = win.position == "bottom" or win.position == "top"
	local size = win.size or (horizontal and 10 or 40)
	if size <= 1 then
		size = math.floor((horizontal and vim.o.lines or vim.o.columns) * size)
	end
	return win.position, size, horizontal
end

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

local function is_leaf(node)
	return node.children ~= nil and #node.children == 0
end

-- Which indent symbol a row gets, following trouble's rules mirrored
-- upward: a collapsed node shows the fold icon in place of its
-- connector, the root (trouble's depth 1) shows a fold icon or nothing,
-- and the topmost sibling is where a guide line ends.
local function symbol_for(node, is_first)
	if node.loading then
		return "loading"
	elseif node.depth == 0 then
		if is_leaf(node) then
			return "ws"
		end
		return node.expanded and "fold_open" or "fold_closed"
	elseif not node.expanded and not is_leaf(node) then
		return "fold_closed"
	end
	return is_first and "first" or "middle"
end

local function camel(s)
	return (s:gsub("^%l", string.upper):gsub("_(%l)", string.upper))
end

--- Rebuilds the buffer from the tree, keeping the cursor on its node.
function M._render()
	local s = state
	if not (s and s.buf and vim.api.nvim_buf_is_valid(s.buf)) then
		return
	end
	local cur = M._node_at_cursor()
	local icons = vim.tbl_deep_extend("force", int.defaults.icons, s.opts.icons or {})
	local lines, marks, rows = {}, {}, {}

	local function glyph(symbol)
		if symbol == "loading" then
			return icons.loading, "ImportTreeLoading"
		end
		return icons.indent[symbol], "ImportTreeIndent" .. camel(symbol)
	end

	-- One row: `<pad><guides><icon> <name> <count>  <dir>  <tail>`, the
	-- text built up segment by segment with a highlight per segment.
	local function emit(node, indent, symbol)
		local line, segs = "", {}
		local function add(text, hl)
			if text == "" then
				return
			end
			if hl then
				table.insert(segs, { #line, #line + #text, hl })
			end
			line = line .. text
		end

		add(" ")
		for _, sym in ipairs(indent) do
			add(glyph(sym))
		end
		add(glyph(symbol))
		local icon, icon_hl = file_icon(node.path)
		if icon then
			add(icon .. " ", icon_hl)
		end
		local name_hl = node.depth == 0 and "ImportTreeRoot"
			or node.ceiling and "ImportTreePage"
			or "ImportTreeFilename"
		add(vim.fn.fnamemodify(node.path, ":t"), name_hl)
		if node.children and #node.children > 0 then
			add(" ")
			add((" %d "):format(#node.children), "ImportTreeCount")
		end
		add("  ")
		add(rel_dir(node.path), "ImportTreeDirectory")
		if node.failed then
			add("  ")
			add("lookup failed", "ImportTreeFailed")
		elseif is_leaf(node) then
			add("  ")
			add("root", "ImportTreeTail")
		elseif node.ceiling then
			add("  ")
			add("page", "ImportTreeTail")
		end

		table.insert(lines, line)
		table.insert(rows, node)
		local row = #lines - 1
		for _, seg in ipairs(segs) do
			table.insert(marks, { row, seg[1], { end_col = seg[2], hl_group = seg[3] } })
		end
	end

	-- Importers are emitted before (above) the file they import, in
	-- sorted order, so reading top-down within a group still gives
	-- pages first. `indent` holds the guide symbols inherited from the
	-- ancestors; a node's importers get a continuing line unless the
	-- node is the topmost of its siblings (nothing above it to reach).
	local function walk(node, indent, is_first)
		if node.expanded and node.children and #node.children > 0 then
			table.insert(indent, (is_first or node.depth == 0) and "ws" or "top")
			for i, child in ipairs(node.children) do
				walk(child, indent, i == 1)
			end
			table.remove(indent)
		end
		emit(node, indent, symbol_for(node, is_first))
	end
	walk(s.root, {}, true)

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

-- Window-local options `ensure_win` sets on the tree window, the same
-- set trouble uses for its list window.
-- stylua: ignore
local TREE_WIN_OPTS = {
	number         = false,
	relativenumber = false,
	signcolumn     = "no",
	foldcolumn     = "0",
	wrap           = false,
	cursorline     = true,
	cursorlineopt  = "both",
	cursorcolumn   = false,
	list           = false,
	spell          = false,
	statuscolumn   = "",
	winbar         = "",
	fillchars      = "eob: ",
	winfixheight   = true,
	winfixwidth    = true,
	winhighlight   = "Normal:ImportTreeNormal,NormalNC:ImportTreeNormalNC,EndOfBuffer:ImportTreeNormal",
}

-- Split commands relative to the whole editor, as trouble uses them.
local SPLIT = {
	bottom = "botright",
	top = "topleft",
	right = "vertical botright",
	left = "vertical topleft",
}

-- Where a new editing window goes when the tree is the only window:
-- the side opposite the tree.
local OPPOSITE_SPLIT = {
	bottom = "topleft split",
	top = "botright split",
	right = "topleft vsplit",
	left = "botright vsplit",
}

local function set_size(win, size, horizontal)
	if horizontal then
		vim.api.nvim_win_set_height(win, size)
	else
		vim.api.nvim_win_set_width(win, size)
	end
end

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
	-- global values, and give the tree its size back.
	local position, size, horizontal = win_opts()
	local win
	vim.api.nvim_win_call(s.win, function()
		vim.cmd(OPPOSITE_SPLIT[position])
		win = vim.api.nvim_get_current_win()
	end)
	for opt in pairs(TREE_WIN_OPTS) do
		vim.wo[win][0][opt] = vim.api.nvim_get_option_value(opt, { scope = "global" })
	end
	set_size(s.win, size, horizontal)
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
	local position, size = win_opts()
	vim.cmd(("silent noswapfile %s %dsplit"):format(SPLIT[position], size))
	s.win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(s.win, s.buf)
	-- `[0]` sets them like `:setlocal`; plain `vim.wo[win]` would also
	-- overwrite the user's global values.
	for opt, value in pairs(TREE_WIN_OPTS) do
		vim.wo[s.win][0][opt] = value
	end
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
