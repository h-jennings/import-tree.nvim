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
}

local config = { defaults = defaults, projects = {} }

-- Global-component declaration files that have answered references at
-- least once this session, so their project is known to be loaded.
local warm = {}

-- Lookups in flight; see `hook_show_document`.
local suppress = 0

-- Loads a file into a hidden, unlisted buffer so the LSP attaches to it
-- (and sends didOpen) without it appearing in any window. Returns the
-- buffer and whether it was already loaded.
local function load_hidden(file)
	local buf = vim.fn.bufadd(file)
	if vim.api.nvim_buf_is_loaded(buf) then
		return buf, true
	end
	vim.fn.bufload(buf)
	vim.bo[buf].buflisted = false
	return buf, false
end

--- opts.defaults: overrides for every project.
--- opts.projects: { [lua_pattern_against_root] = project_opts }. First match
--- wins, so a pattern also covers worktrees of the same repo.
function M.setup(opts)
	opts = opts or {}
	config.defaults = vim.tbl_deep_extend("force", defaults, opts.defaults or {})
	config.projects = opts.projects or {}
end

local function resolve_opts(root, overrides)
	local project = {}
	for pattern, popts in pairs(config.projects) do
		if root and root:find(pattern) then
			project = popts
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
-- an unopened file, and 0 until its project finishes loading, so the
-- declaration is opened in a hidden buffer and retried until warm.
local function resolve_global(client, bufnr, loc, cb)
	local file = vim.uri_to_fname(loc.uri)
	local line = vim.fn.readfile(file, "", loc.range.start.line + 1)[loc.range.start.line + 1] or ""
	local col = line:find("%S")
	if not col then
		return cb(nil, {})
	end
	local started = vim.uv.now()

	local function request()
		client:request("textDocument/references", {
			textDocument = { uri = loc.uri },
			position = { line = loc.range.start.line, character = col - 1 },
			context = { includeDeclaration = false },
		}, function(err, result)
			result = result or {}
			if #result == 0 and not warm[file] and vim.uv.now() - started < 8000 then
				return vim.defer_fn(request, 500)
			end
			if #result > 0 then
				warm[file] = true
			end
			cb(err, result)
		end, bufnr)
	end

	local decl, was_loaded = load_hidden(file)
	if not was_loaded then
		warm[file] = nil
	end
	local function when_attached()
		if vim.lsp.get_clients({ bufnr = decl, id = client.id })[1] then
			return request()
		end
		if vim.uv.now() - started > 8000 then
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
	client:exec_cmd({
		command = "typescript.findAllFileReferences",
		arguments = { vim.uri_from_fname(path) },
	}, { bufnr = bufnr }, function(err, result)
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

--- Expandable tree of importers in a right-hand split, drawn upward from
--- the current file. See `import-tree.tree`.
function M.tree(overrides)
	require("import-tree.tree").toggle(overrides)
end

-- Shared with `import-tree.tree`.
M._internals = {
	importers_of = importers_of,
	matches = matches,
	start_from = start_from,
}

return M
