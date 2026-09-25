-- Import graph lookups for `import-tree.tree`: who imports a file, one
-- layer at a time, up to a ceiling (e.g. a page) or a file nothing
-- imports. Built on vtsls's `typescript.findAllFileReferences` rather
-- than call hierarchy, because a component used in a template is an
-- import plus a property lookup, never a "call".

local M = {}

local defaults = {
	-- Files marked as the top of the graph (pages). Lua patterns against
	-- the absolute path, or a function(path, depth) -> boolean.
	ceiling = {},
	-- Never listed as importers.
	ignore = { "%.spec%.", "%.test%.", "%.stories%." },
	-- Generated global-component declarations (unplugin-vue-components).
	-- Seen as an importer, they're replaced by references to the entry.
	global_components = { "components%.d%.ts$" },
	-- The tree window, laid out like trouble.nvim's: a full-width panel
	-- at the bottom. `size` is lines for top/bottom, columns for
	-- left/right; a value of 1 or less is a fraction of the editor.
	win = {
		---@type "bottom"|"top"|"left"|"right"
		position = "bottom",
		size = 10,
	},
	-- stylua: ignore
	icons = {
		-- Guides run from a file up to its importers, so the topmost
		-- importer is where a line ends.
		indent = {
			top         = "│ ", -- line continuing up past this row
			middle      = "├╴",
			first       = "┌╴",
			fold_open   = " ", -- importers shown above
			fold_closed = " ",
			ws          = "  ",
		},
		loading = "… ",
	},
}

local config = { defaults = defaults, projects = {} }

-- Lookups in flight; see `hook_show_document`.
local suppress = 0

-- How long a single LSP request may take before it counts as failed.
-- Neovim never calls back a request to a server that stopped or
-- crashed, so without this a lookup would stay in flight forever.
local REQUEST_TIMEOUT = 15000

-- How long to wait for tsserver to load a declaration file's project.
local WARMUP_TIMEOUT = 8000

-- Loads a file into a hidden buffer so the LSP attaches to it (and sends
-- didOpen) without it appearing in any window. Buffers created here are
-- unlisted; an existing buffer keeps its listing. Returns the buffer and
-- whether it was already loaded.
local function load_hidden(file)
	local existed = vim.fn.bufexists(file) == 1
	local buf = vim.fn.bufadd(file)
	if vim.api.nvim_buf_is_loaded(buf) then
		return buf, true
	end
	vim.fn.bufload(buf)
	if not existed then
		vim.bo[buf].buflisted = false
	end
	return buf, false
end

-- `client:request` that always calls back exactly once: with an error if
-- the request couldn't be sent or got no answer in time.
local function request(client, method, params, bufnr, cb)
	local done = false
	local function finish(err, result)
		if done then
			return
		end
		done = true
		cb(err, result)
	end
	local sent = not client:is_stopped() and client:request(method, params, finish, bufnr)
	if not sent then
		return finish(("%s is not running"):format(client.name))
	end
	vim.defer_fn(function()
		finish(("%s timed out"):format(method))
	end, REQUEST_TIMEOUT)
end

-- `projects` as an ordered list of { pattern, opts }. A list is kept in
-- the order given. A map has no order, so its patterns are tried longest
-- first, which puts the more specific of two overlapping patterns first.
local function normalize_projects(projects)
	if vim.islist(projects) then
		return projects
	end
	local list = {}
	for pattern, popts in pairs(projects) do
		table.insert(list, { pattern, popts })
	end
	table.sort(list, function(a, b)
		if #a[1] ~= #b[1] then
			return #a[1] > #b[1]
		end
		return a[1] < b[1]
	end)
	return list
end

--- opts.defaults: overrides for every project.
--- opts.projects: { [lua_pattern_against_root] = project_opts }, or a list
--- of { pattern, project_opts } to control the order. First match wins, so
--- a pattern also covers worktrees of the same repo.
function M.setup(opts)
	opts = opts or {}
	config.defaults = vim.tbl_deep_extend("force", defaults, opts.defaults or {})
	config.projects = normalize_projects(opts.projects or {})
end

local function resolve_opts(root, overrides)
	local project = {}
	for _, entry in ipairs(config.projects) do
		if root and root:find(entry[1]) then
			project = entry[2]
			break
		end
	end
	-- Lists replace rather than merge, so a project's `ceiling` isn't
	-- appended to the defaults' by index.
	local opts = vim.tbl_extend("force", config.defaults, project, overrides or {})
	return opts
end

local function matches(rules, path, depth)
	if type(rules) == "function" then
		return rules(path, depth)
	end
	for _, rule in ipairs(rules) do
		if type(rule) == "function" then
			if rule(path, depth) then
				return true
			end
		elseif path:find(rule) then
			return true
		end
	end
	return false
end

local function get_vtsls(bufnr)
	return vim.lsp.get_clients({ bufnr = bufnr, name = "vtsls" })[1]
end

-- An auto-registered component's only "importer" is the generated
-- declaration, e.g. `Foo: typeof import('./src/Foo.vue')['default']`.
-- Template usages resolve through that property, so references on it
-- are the real importers. tsserver answers nothing for a position in
-- an unopened file, and nothing until its project finishes loading, so
-- the declaration is opened in a hidden buffer and asked again until it
-- answers. The declaration itself is requested too: once the project is
-- loaded it always comes back, even for a component nothing uses, so an
-- empty answer only ever means "not loaded yet".
local function resolve_global(client, bufnr, loc, cb)
	local file = vim.uri_to_fname(loc.uri)
	local ref_line = loc.range.start.line
	local lines = vim.fn.readfile(file, "", ref_line + 1)
	-- The property name sits on the line with `: typeof`, which is the
	-- reference's own line unless a formatter wrapped the entry.
	local name_line, col
	for l = ref_line, math.max(ref_line - 5, 0), -1 do
		local text = lines[l + 1] or ""
		if text:find(":%s*typeof%f[%W]") then
			name_line, col = l, text:find("%S")
			break
		end
	end
	if not col then
		return cb(nil, {})
	end
	local started = vim.uv.now()

	local function ask()
		request(client, "textDocument/references", {
			textDocument = { uri = loc.uri },
			position = { line = name_line, character = col - 1 },
			context = { includeDeclaration = true },
		}, bufnr, function(err, result)
			result = result or {}
			if #result == 0 and not err and vim.uv.now() - started < WARMUP_TIMEOUT then
				return vim.defer_fn(ask, 500)
			end
			local refs = {}
			for _, ref in ipairs(result) do
				if ref.uri ~= loc.uri then
					table.insert(refs, ref)
				end
			end
			cb(err, refs)
		end)
	end

	local decl = load_hidden(file)
	local function when_attached()
		if vim.lsp.get_clients({ bufnr = decl, id = client.id })[1] then
			return ask()
		end
		if client:is_stopped() or vim.uv.now() - started > WARMUP_TIMEOUT then
			return cb("timed out attaching to " .. file, {})
		end
		vim.defer_fn(when_attached, 100)
	end
	when_attached()
end

--- One level: every file that imports `path`, as { path, lnum, col }
--- where lnum/col point at the import (or template usage) in the
--- importer. `cb(importers, failed)`; `failed` counts lookups that errored.
local function importers_of(client, bufnr, path, opts, depth, cb)
	local importers, seen, failed = {}, {}, 0
	local pending = 1

	local function add(locations)
		for _, loc in ipairs(locations) do
			local file = vim.uri_to_fname(loc.uri)
			-- One entry per importing file; a file importing twice
			-- (type + value) would otherwise fork every chain.
			if not seen[file] and file ~= path and not matches(opts.ignore, file, depth) then
				seen[file] = true
				table.insert(importers, {
					path = file,
					lnum = loc.range.start.line + 1,
					col = loc.range.start.character,
				})
			end
		end
	end

	local function settle()
		pending = pending - 1
		if pending == 0 then
			cb(importers, failed)
		end
	end

	suppress = suppress + 1
	request(client, "workspace/executeCommand", {
		command = "typescript.findAllFileReferences",
		arguments = { vim.uri_from_fname(path) },
	}, bufnr, function(err, result)
		suppress = suppress - 1
		if err then
			failed = failed + 1
		end
		local direct = {}
		for _, loc in ipairs(result or {}) do
			if matches(opts.global_components, vim.uri_to_fname(loc.uri), 0) then
				pending = pending + 1
				resolve_global(client, bufnr, loc, function(gerr, refs)
					if gerr then
						failed = failed + 1
					end
					add(refs)
					settle()
				end)
			else
				table.insert(direct, loc)
			end
		end
		add(direct)
		settle()
	end)
end

-- `findAllFileReferences` mirrors VS Code's command, which opens the file
-- being looked up before finding its references, so vtsls asks the
-- editor to show it with `window/showDocument` on every lookup, and
-- reads the language id off the document that opens. While a lookup is
-- in flight (`suppress`, above) the file is loaded hidden instead of
-- shown; other showDocument requests pass through.
local function hook_show_document(client)
	if client._import_tree_hooked then
		return
	end
	client._import_tree_hooked = true
	local fallback = client.handlers["window/showDocument"]
	client.handlers["window/showDocument"] = function(err, result, ctx, cfg)
		if suppress > 0 and result and result.uri and not result.external then
			load_hidden(vim.uri_to_fname(result.uri))
			return { success = true }
		end
		return (fallback or vim.lsp.handlers["window/showDocument"])(err, result, ctx, cfg)
	end
end

-- A running vtsls for `bufnr`, or any running vtsls if that buffer is
-- gone. Used to pick up a restarted server.
local function live_client(bufnr)
	local client = vim.api.nvim_buf_is_valid(bufnr) and get_vtsls(bufnr)
		or vim.lsp.get_clients({ name = "vtsls" })[1]
	if client then
		hook_show_document(client)
	end
	return client
end

local function start_from(bufnr, overrides)
	bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
	local client = get_vtsls(bufnr)
	if not client then
		vim.notify("import-tree: vtsls is not attached", vim.log.levels.WARN)
		return
	end
	hook_show_document(client)
	return client, bufnr, resolve_opts(client.root_dir, overrides), vim.api.nvim_buf_get_name(bufnr)
end

--- Expandable tree of importers in a bottom panel, drawn upward from
--- the current file. See `import-tree.tree`.
function M.tree(overrides)
	require("import-tree.tree").toggle(overrides)
end

-- Shared with `import-tree.tree`.
M._internals = {
	defaults = defaults,
	importers_of = importers_of,
	live_client = live_client,
	matches = matches,
	start_from = start_from,
}

return M
