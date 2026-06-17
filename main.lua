--- @since 25.5.28
-- This plugin is now only supporting Yazi's version 25.5.28 or newer
-- since commit https://github.com/sxyazi/yazi/pull/2695
-- NOTE: This version uses dua-cli for improved performance instead of fs.calc_size()

-- TODO: Asynchronous calculating and dynamic displaying in statusline,
-- perhaps by using this:
--      https://yazi-rs.github.io/docs/plugins/utils/#ps.sub
-- and by using ui.render() method
-- See also:
--      https://github.com/sxyazi/yazi/pull/1903
--      https://yazi-rs.github.io/docs/dds/#kinds
--      https://github.com/sxyazi/yazi/pull/2210
--      https://github.com/imsi32/yatline.yazi
-- TODO: Add options to choose displaying in popup box or in statusline
-- TODO: Add spotter and previewer widget to support simpler displaying
-- TODO: Remove note [1] and [2] after add them to the setup
-- configuration

-- Get selected paths and CWD in single sync call {{{1
local get_selection_context = ya.sync(function(state)
    local result = {}
    local selected = {}

    if cx and cx.active and cx.active.selected then
        for _, url in pairs(cx.active.selected) do
            selected[#selected + 1] = url
        end
    end

    result.selected = selected
    result.is_visual = cx and cx.active and cx.active.mode and cx.active.mode.is_visual
    result.cwd = cx and cx.active and cx.active.current and cx.active.current.cwd

    return result
end)
-- }}}1
-- Function to get paths of selected files or current directory {{{1
--- @param ctx table Context from get_selection_context
--- @return paths table Table of selected urls or cwd
local function get_paths(ctx)
    if not ctx then
        return {}
    end

    -- If no files are selected, get current directory
    if #ctx.selected == 0 then
        if ctx.cwd then
            return { ctx.cwd }
        else
            -- Fallback to async fs.cwd
            local cwd, err = fs.cwd()
            if cwd then
                return { cwd }
            else
                ya.notify {
                    title = "What size",
                    content = "Cannot get current working directory: " .. (err or "unknown error"),
                    timeout = 5,
                    level = "error",
                }
            end
        end
        return {}
    else
        return ctx.selected
    end
end
-- }}}1
-- Escape shell argument safely {{{1
local function escape_shell_arg(arg)
    return "'" .. tostring(arg):gsub("'", "'\\''") .. "'"
end
-- }}}1
-- Get size of single file using fs.stat {{{1
local function get_file_size(path)
    local stat, err = fs.stat(path)
    if stat then
        return stat.size or 0
    end
    ya.dbg("fs.stat failed for " .. tostring(path) .. ": " .. (err or "unknown"))
    return nil
end
-- }}}1
-- Function to get total size using dua-cli for better performance {{{1
-- dua is a faster alternative to du for calculating directory sizes
-- Optimizations: batch paths in single call, fast-path for single files
local function get_total_size(items)
    if not items or #items == 0 then
        return 0
    end

    local total = 0

    -- Fast path: single file uses fs.stat instead of dua
    if #items == 1 then
        local stat, err = fs.stat(items[1])
        if stat then
            if stat.is_dir then
                -- Directory: use dua
                local cmd = "dua aggregate " .. escape_shell_arg(items[1])
                local handle = io.popen(cmd .. " 2>&1")
                if handle then
                    local output = handle:read("*a")
                    handle:close()
                    if output and output ~= "" then
                        local size_str = output:match("^(%d+)")
                        return size_str and tonumber(size_str) or nil
                    end
                end
                return nil
            else
                -- Regular file: return size directly
                return stat.size or 0
            end
        else
            ya.dbg("fs.stat failed: " .. (err or "unknown"))
        end
    end

    -- Batch mode: collect all paths and pass to single dua call
    local paths_str = ""
    for i, url in ipairs(items) do
        paths_str = paths_str .. escape_shell_arg(url)
        if i < #items then
            paths_str = paths_str .. " "
        end
    end

    local cmd = "dua aggregate " .. paths_str
    local handle = io.popen(cmd .. " 2>&1")
    if not handle then
        ya.err("Failed to execute dua command")
        return nil
    end

    local output = handle:read("*a")
    handle:close()

    if output and output ~= "" then
        -- Sum up all sizes from dua output (each line is "SIZE\tPATH")
        for line in output:gmatch("[^\n]+") do
            local size_str = line:match("^(%d+)")
            if size_str then
                total = total + tonumber(size_str)
            end
        end
    end

    return total ~= 0 and total or nil
end
-- }}}1
-- Function to format files/folders size {{{1
local function format_size(size)
    local units = { "B", "KB", "MB", "GB", "TB" }
    local unit_index = 1
    while size > 1024 and unit_index < #units do
        size = size / 1024
        unit_index = unit_index + 1
    end
    return string.format("%.2f %s", size, units[unit_index])
end
-- }}}1
-- Generic setter for any state field {{{1
local set_state = ya.sync(function(state, field, value)
    state[field] = value
end)
-- }}}1
-- Generic getter for any state field {{{1
local get_state = ya.sync(function(state, field)
    return state[field] or nil
end)
-- }}}1
-- Set separators {{{1
local set_separator = ya.sync(function(state, table)
    if table and table.LEFT and table.RIGHT then
        state.LEFT = table.LEFT
        state.RIGHT = table.RIGHT
    else
        state.LEFT = " "
        state.RIGHT = " "
    end
end)
-- }}}1
-- Get separators {{{1
local get_separator = ya.sync(function(state)
    return {state.LEFT, state.RIGHT}
end)
-- }}}1
-- Redraw statusline {{{1
local redraw_statusline = ya.sync(function(state)
    ui.render()
end)
-- }}}1
-- Cache state values in sync call for better performance {{{1
local get_ui_state = ya.sync(function()
    return {
        renewed_state = state.renewed_state or -1,
        is_held = state.is_held or false,
        size = state.size or "",
        is_selected = (not cx.active.mode.is_visual) and (#cx.active.selected ~= 0),
    }
end)
-- }}}1
-- Set ui line in statusline for size, clean up when no selection exists {{{1
-- @return of get_state("renewed_state") number or nil Returning -1
--     means never show the size - suitable for setup function;
--     returning 0 means the size will be shown after triggering the
--     calculation, but without unselect the selections, or it will be
--     hidden after nothing is selected; returning 1 means hidden when
--     nothing is selected as said.
local set_ui_line = function(state)
    local sep_left, sep_right = table.unpack(get_separator())
    local ui_state = get_ui_state()

    if ui_state.renewed_state == -1 then
        return ""
    else
        if not ui_state.is_selected then
            if not ui_state.is_held then
                set_state("renewed_state", 1)
                return ""
            end
            return ui.Span(sep_left .. ui_state.size .. sep_right)
        end
        if ui_state.renewed_state == 0 then
            return ui.Span(sep_left .. ui_state.size .. sep_right)
        else
            return ""
        end
    end
end
-- }}}1

--- @since 25.12.29
return {
    entry = function(self, job)
        local clipboard = job.args.clipboard or job.args[1] == '-c'

        -- Get all context in a single sync call for better performance
        local ctx = get_selection_context()
        local prepend_msg

        -- Keep showing the size after CWD calculation (no selections)
        if #ctx.selected == 0 then
            set_state("is_held", true)
            prepend_msg = "Current Dir: "
        else
            set_state("is_held", false)
            prepend_msg = "Selected: "
        end

        local items = get_paths(ctx)
        if not items or #items == 0 then
            ya.notify {
                title = "What size",
                content = "Failed to get paths",
                timeout = 5,
            }
            return
        end

        local total_size = get_total_size(items)
        if not total_size then
            ya.notify {
                title = "What size",
                content = "Failed to calculate size",
                timeout = 5,
            }
            return
        end

        local formatted_size = format_size(total_size)

        local notification_content = prepend_msg .. formatted_size
        if clipboard then
            ya.clipboard(formatted_size)
            notification_content = notification_content .. "\nCopied to clipboard."
        end
        ya.notify {
            title = "What size",
            content = notification_content,
            timeout = 4,
        }

        set_state("size", formatted_size)
        set_state("renewed_state", 0)
        redraw_statusline()
    end,

    setup = function(state, opts)
        opts = opts or {}
        local priority = opts.priority or 400
        set_separator(opts)
        set_state("renewed_state", -1)

        if Status and type(Status.children_add) == "function" then
            Status:children_add(set_ui_line, priority, Status.RIGHT)
        else
            ya.err("Failed to initialize status bar: Status or children_add not available")
        end
    end,
}
