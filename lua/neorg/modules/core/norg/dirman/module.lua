--[[
    File: Dirman
    Title: Directory manager for Neorg.
	Summary: This module is be responsible for managing directories full of .norg files.
    ---
It will provide other modules the ability to see which directories the user is in,
automatically changing directories, and other API bits and bobs that will allow things like telescope.nvim integration.

To use core.norg.dirman, simply load up the module in your configuration and specify the directories you want to be managed for you:

```lua
require('neorg').setup {
    load = {
        ["core.defaults"] = {},
        ["core.norg.dirman"] = {
            config = {
                workspaces = {
                    my_ws = "~/neorg", -- Format: <name_of_workspace> = <path_to_workspace_root>
                    my_other_notes = "~/work/notes",
                },
                autochdir = true, -- Automatically change the directory to the current workspace's root every time
                index = "index.norg", -- The name of the main (root) .norg file
            }
        }
    }
}
```

To query the current workspace, run `:Neorg workspace`. To set the workspace, run `:Neorg workspace <workspace_name>`.
--]]

require("neorg.modules.base")
require("neorg.modules")

local module = neorg.modules.create("core.norg.dirman")
local scan = require("plenary.scandir")

module.setup = function()
    return {
        success = true,
        requires = { "core.autocommands", "core.neorgcmd", "core.keybinds", "core.ui", "core.storage" },
    }
end

module.load = function()
    -- Go through every workspace and expand special symbols like ~
    for name, workspace_location in pairs(module.config.public.workspaces) do
        module.config.public.workspaces[name] = vim.fn.expand(workspace_location)
    end

    module.required["core.keybinds"].register_keybind(module.name, "new.note")

    -- Used to detect when we've entered a buffer with a potentially different cwd
    module.required["core.autocommands"].enable_autocommand("BufEnter", true)

    -- Enable the DirChanged autocmd to detect changes to the cwd
    module.required["core.autocommands"].enable_autocommand("DirChanged", true)

    -- Enable the VimLeavePre autocommand to write the last workspace to disk
    module.required["core.autocommands"].enable_autocommand("VimLeavePre", true)

    -- If the user has supplied a custom workspace to start in (i.e. :NeorgStart workspace=<name>)
    -- then load that custom workspace here
    if not neorg.configuration.arguments.silent then
        if neorg.configuration.arguments.workspace then
            module.public.open_workspace(neorg.configuration.arguments.workspace)
            vim.notify("Start in custom workspace -> " .. neorg.configuration.arguments.workspace)
        elseif neorg.configuration.manual then
            -- If we have loaded this module by invoking :NeorgStart then try jumping
            -- to the last cached workspace
            module.public.set_last_workspace()
        end
    end

    -- Synchronize core.neorgcmd autocompletions
    module.public.sync()
end

module.config.public = {
    -- The list of active workspaces
    workspaces = {
        default = vim.fn.getcwd(),
    },

    -- Automatically change the directory to the root of the workspace every time
    autochdir = false,

    -- The name for the index file
    index = "index.norg",

    -- The default workspace to load into when running `:NeorgStart`
    default_workspace = nil,
}

module.private = {
    current_workspace = { "default", vim.fn.getcwd() },
}

---@class core.norg.dirman
module.public = {

    -- @Summary Returns a list of all the workspaces
    get_workspaces = function()
        return module.config.public.workspaces
    end,

    -- @Summary Returns an array of all the workspace names (without their paths)
    get_workspace_names = function()
        return vim.tbl_keys(module.config.public.workspaces)
    end,

    -- @Summary Retrieve a workspace
    -- @Description If present retrieve a workspace's path by its name, else returns nil
    -- @Param  name (string) - the name of the workspace
    get_workspace = function(name)
        return module.config.public.workspaces[name]
    end,

    -- @Summary Retrieves the current workspace
    -- @Description Returns a table in the format { "workspace_name", "path" }
    get_current_workspace = function()
        return module.private.current_workspace
    end,

    -- @Summary Sets the current workspace
    -- @Description Sets the workspace to the one specified (if it exists) and broadcasts the workspace_changed event
    --				Returns true if the workspace is set correctly, else returns false
    -- @Param  ws_name (name) - the name of a valid namespace we want to switch to
    set_workspace = function(ws_name)
        -- Grab the workspace location
        local workspace = module.config.public.workspaces[ws_name]
        -- Create a new object describing our new workspace
        local new_workspace = { ws_name, workspace }

        -- If the workspace does not exist then error out
        if not workspace then
            log.warn("Unable to set workspace to", workspace, "- that workspace does not exist")
            return false
        end

        -- Create the workspace directory if not already present
        vim.loop.fs_mkdir(workspace, 16877)

        -- Cache the current workspace
        local current_ws = vim.deepcopy(module.private.current_workspace)

        -- Set the current workspace to the new workspace object we constructed
        module.private.current_workspace = new_workspace

        -- Broadcast the workspace_changed event with all the necessary information
        neorg.events.broadcast_event(
            neorg.events.create(
                module,
                "core.norg.dirman.events.workspace_changed",
                { old = current_ws, new = new_workspace }
            )
        )

        return true
    end,

    -- @Summary Adds a new workspace
    -- @Description Dynamically defines a new workspace if the name isn't already occupied and broadcasts the workspace_added event
    --				Returns true if the workspace is added successfully, else returns false
    -- @Param  workspace_name (string) - the unique name of the new workspace
    -- @Param  workspace_path (string) - a full path to the workspace root
    add_workspace = function(workspace_name, workspace_path)
        -- If the module already exists then bail
        if module.config.public.workspaces[workspace_name] then
            return false
        end

        -- Set the new workspace and its path accordingly
        module.config.public.workspaces[workspace_name] = workspace_path
        -- Broadcast the workspace_added event with the newly added workspace as the content
        neorg.events.broadcast_event(
            neorg.events.create(module, "core.norg.dirman.events.workspace_added", { workspace_name, workspace_path })
        )

        -- Sync autocompletions so the user can see the new workspace
        module.public.sync()

        return true
    end,

    -- @Summary Returns the closes match from the cwd to a valid workspace
    -- @Description If the file we opened is within a workspace directory, returns the name of the workspace, else returns nil
    get_workspace_match = function()
        -- Cache the current working directory
        module.config.public.workspaces.default = vim.fn.getcwd()

        -- Grab the working directory of the current open file
        local realcwd = vim.fn.expand("%:p:h")

        -- Store the length of the last match
        local last_length = 0

        -- The final result
        local result = ""

        -- Find a matching workspace
        for workspace, location in pairs(module.config.public.workspaces) do
            if workspace ~= "default" then
                -- Expand all special symbols like ~ etc. and escape special characters
                local expanded = string.gsub(vim.fn.expand(location), "%p", "%%%1")

                -- If the workspace location is a parent directory of our current realcwd
                -- or if the ws location is the same then set it as the real workspace
                -- We check this last_length here because if a match is longer
                -- than the previous one then we can say it is a much more precise
                -- match and hence should be prioritized
                if realcwd:find(expanded) and #expanded > last_length then
                    -- Set the result to the workspace name
                    result = workspace
                    -- Set the last_length variable to the new length
                    last_length = #expanded
                end
            end
        end

        return result:len() ~= 0 and result or "default"
    end,

    -- @Summary Updates the current working directory to the workspace root
    -- @Description Uses the get_workspace_match() function to determine the root of the workspace, then changes into that directory
    update_cwd = function()
        -- Get the closest workspace match
        local ws_match = module.public.get_workspace_match()

        -- If that match exists then set the workspace to it!
        if ws_match then
            module.public.set_workspace(ws_match)
        else
            -- Otherwise try to reset the workspace to the default
            module.public.set_workspace("default")
        end
    end,

    -- @Summary Synchronizes the module to the Neorg environment
    -- @Description Updates completions for the :Neorg command
    sync = function()
        -- Get all the workspace names
        local workspace_names = module.public.get_workspace_names()

        -- Construct a table to be used by core.neorgcmd for autocompletion
        local workspace_autocomplete = (function()
            local result = {}

            for _, ws_name in ipairs(workspace_names) do
                result[ws_name] = {}
            end

            return result
        end)()

        -- Add the command to core.neorgcmd so it can be used by the user!
        module.required["core.neorgcmd"].add_commands_from_table({
            definitions = {
                workspace = workspace_autocomplete,
            },
            data = {
                workspace = {
                    max_args = 1,
                    name = "dirman.workspace",
                },
            },
        })
    end,

    --- Takes in a path (can include directories) and creates a .norg file from that path
    ---@param path string a path to place the .norg file in
    ---@param workspace string workspace name
    ---@param opts? table additional options
    ---  - opts.no_open (bool) if true, will not open the file in neovim after creating it
    ---  - opts.force (bool) if true, will overwrite existing file content
    create_file = function(path, workspace, opts)
        opts = opts or {}

        -- Grab the current workspace's full path
        local fullpath

        if workspace ~= nil then
            fullpath = module.public.get_workspace(workspace)
        else
            fullpath = module.public.get_current_workspace()[2]
        end

        if fullpath == nil then
            log.error("Error in fetching workspace path")
            return
        end

        -- Split the path at every /
        local split = vim.split(vim.trim(path), neorg.configuration.pathsep, true)

        -- If the last element is empty (i.e. if the string provided ends with '/') then trim it
        if split[#split]:len() == 0 then
            split = vim.list_slice(split, 0, #split - 1)
        end

        -- Go through each directory (excluding the actual file name) and create each directory individually
        for _, element in ipairs(vim.list_slice(split, 0, #split - 1)) do
            vim.loop.fs_mkdir(fullpath .. neorg.configuration.pathsep .. element, 16877)
            fullpath = fullpath .. neorg.configuration.pathsep .. element
        end

        -- If the provided filepath ends in .norg then don't append the filetype automatically
        local fname = fullpath .. neorg.configuration.pathsep .. split[#split]
        if not vim.endswith(path, ".norg") then
            fname = fname .. ".norg"
        end

        if opts.no_open then
            -- Create the file
            local fd = vim.loop.fs_open(fname, opts.force and "w" or "a", 438)

            if fd then
                vim.loop.fs_close(fd)
            end

            return
        end

        -- Begin editing that newly created file
        vim.cmd("e " .. fname .. " | w")
    end,

    -- @Summary Open a Neorg file
    -- @Description Takes in a workspace name and a path for a file and opens it
    -- @Param  workspace_name (string) - the name of the workspace to use
    -- @Param  path (string) - a path to open the file (e.g directory/filename.norg)
    open_file = function(workspace_name, path)
        local workspace = module.public.get_workspace(workspace_name)

        if workspace == nil then
            return
        end

        vim.cmd("e " .. workspace .. neorg.configuration.pathsep .. path .. " | w")
    end,

    -- @Summary Sets the current workspace to the last cached workspace
    -- @Description Reads the neorg_last_workspace.txt file and loads the cached workspace from there
    set_last_workspace = function()
        -- Attempt to open the last workspace cache file in read-only mode
        local storage = neorg.modules.get_module("core.storage")

        if not storage then
            log.trace("Module `core.storage` not loaded, refusing to load last user's workspace.")
            return
        end

        local last_workspace = storage.retrieve("last_workspace")
        last_workspace = type(last_workspace) == "string" and last_workspace
            or module.config.public.default_workspace
            or ""

        local workspace_path = module.public.get_workspace(last_workspace)

        if not workspace_path then
            log.trace("Unable to switch to workspace '" .. last_workspace .. "'. The workspace does not exist.")
            return
        end

        -- If we were successful in switching to that workspace then begin editing that workspace's index file
        if module.public.set_workspace(last_workspace) then
            vim.cmd("e " .. workspace_path .. neorg.configuration.pathsep .. module.config.public.index)

            vim.notify("Last Workspace -> " .. workspace_path)
        end
    end,

    --- Checks for file existence by supplying a full path in `filepath`
    --- @param filepath string
    file_exists = function(filepath)
        local f = io.open(filepath, "r")

        if f ~= nil then
            f:close()
            return true
        else
            return false
        end
    end,

    --- Get the bufnr for a `filepath` (full path)
    --- @param filepath string
    get_file_bufnr = function(filepath)
        if module.public.file_exists(filepath) then
            local uri = vim.uri_from_fname(filepath)
            return vim.uri_to_bufnr(uri)
        end
    end,

    --- Returns a list of all files relative path from a `workspace_name`
    --- @param workspace_name string
    --- @return table
    get_norg_files = function(workspace_name)
        local res = {}
        local workspace = module.public.get_workspace(workspace_name)
        if workspace == nil then
            log.error("Workspace " .. workspace_name .. "does not exist")
            return
        end

        local scanned_dir = scan.scan_dir(workspace)

        -- We remove the workspace path and only keep relative path.
        -- In order to prevent bugs with special characters (hyphens), we escapte them in the pattern
        -- @see https://stackoverflow.com/questions/6705872/how-to-escape-a-variable-in-lua
        local workspace_pattern = string.gsub(workspace, "%p", "%%%1")

        for _, file in pairs(scanned_dir) do
            local remove_dir = string.gsub(file, workspace_pattern .. neorg.configuration.pathsep, "")

            if string.find(remove_dir, ".norg$") then
                table.insert(res, remove_dir)
            end
        end

        return res
    end,

    --- Sets the current workspace and opens that workspace's index file
    --- @param workspace string #The name of the workspace to open
    open_workspace = function(workspace)
        -- If we have, then query that workspace
        local ws_match = module.public.get_workspace(workspace)

        -- If the workspace does not exist then give the user a nice error and bail
        if not ws_match then
            log.error('Unable to switch to workspace - "' .. workspace .. '" does not exist')
            return
        end

        -- Set the workspace to the one requested
        module.public.set_workspace(workspace)

        -- If we're switching to a workspace that isn't the default workspace then enter the index file
        if workspace ~= "default" then
            vim.cmd("e " .. ws_match .. neorg.configuration.pathsep .. module.config.public.index)
        end
    end,

    --- Touches a file in workspace
    --- TODO: make the touch file recursive
    --- @param path string
    --- @param workspace string
    touch_file = function(path, workspace)
        vim.validate({
            path = { path, "string" },
            workspace = { workspace, "string" },
        })

        local ws_match = module.public.get_workspace(workspace)

        if not workspace then
            return
        end

        local file = io.open(ws_match .. neorg.configuration.pathsep .. path, "w")

        if not file then
            return
        end

        file:write("")
        file:close()
        return true
    end,
}

module.on_event = function(event)
    -- If the workspace has changed then
    if event.type == "core.norg.dirman.events.workspace_changed" then
        -- Grab the current working directory and the current workspace
        local new_cwd = vim.fn.getcwd()
        local current_workspace = module.public.get_current_workspace()

        -- If the current working directory is not the same as the workspace root then set it
        if current_workspace[2] ~= new_cwd then
            vim.cmd("lcd! " .. current_workspace[2])
        end
    end

    -- If the user has changed directories and the autochdir flag is set then
    if event.type == "core.autocommands.events.dirchanged" then
        -- Grab the current working directory and the current workspace
        local new_cwd = vim.fn.getcwd()
        local current_workspace = module.public.get_current_workspace()

        -- If the current workspace is not the default and if the cwd is not the same as the workspace root then set it
        if module.config.public.autochdir and current_workspace[1] ~= "default" and current_workspace[2] ~= new_cwd then
            vim.cmd("lcd! " .. current_workspace[2])
            return
        end

        -- Upon changing a directory attempt to perform a match
        module.public.update_cwd()
    end

    -- Just before we leave Neovim make sure to cache the last workspace we were in (as long as that workspace wasn't "default")
    if
        event.type == "core.autocommands.events.vimleavepre"
        and module.public.get_current_workspace()[1] ~= "default"
    then
        -- Attempt to write the last workspace to the cache file
        local storage = neorg.modules.get_module("core.storage")

        if storage then
            storage.store("last_workspace", module.public.get_current_workspace()[1])
        end
    end

    -- If somebody has executed the :Neorg workspace command then
    if event.type == "core.neorgcmd.events.dirman.workspace" then
        -- Have we supplied an argument?
        if event.content[1] then
            module.public.open_workspace(event.content[1])

            vim.schedule(function()
                vim.notify(
                    "New Workspace: " .. event.content[1] .. " -> " .. module.public.get_workspace(event.content[1])
                )
            end)
        else -- No argument supplied, simply print the current workspace
            -- Query the current workspace
            local current_ws = module.public.get_current_workspace()
            -- Nicely print it. We schedule_wrap here because people with a configured logger will have this message
            -- silenced by other trace logs
            vim.schedule(function()
                vim.notify("Current Workspace: " .. current_ws[1] .. " -> " .. current_ws[2])
            end)
        end
    end

    -- If the user has executed a keybind to create a new note then create a prompt
    if event.type == "core.keybinds.events.core.norg.dirman.new.note" then
        module.required["core.ui"].create_prompt("NeorgNewNote", "New Note: ", function(text)
            -- Create the file that the user has entered
            module.public.create_file(text)
        end, {
            center_x = true,
            center_y = true,
        }, {
            width = 25,
            height = 1,
            row = 10,
            col = 0,
        })
    end

    -- If we've entered a different buffer then update the cwd for that buffer's window
    if event.type == "core.autocommands.events.bufenter" and not event.content.norg then
        module.public.update_cwd()
    end
end

module.events.defined = {
    workspace_changed = neorg.events.define(module, "workspace_changed"),
    workspace_added = neorg.events.define(module, "workspace_added"),
    workspace_cache_empty = neorg.events.define(module, "workspace_cache_empty"),
}

module.events.subscribed = {
    ["core.autocommands"] = {
        dirchanged = true,
        vimleavepre = true,
        bufenter = true,
    },

    ["core.norg.dirman"] = {
        workspace_changed = true,
    },

    ["core.neorgcmd"] = {
        ["dirman.workspace"] = true,
    },

    ["core.keybinds"] = {
        ["core.norg.dirman.new.note"] = true,
    },
}

return module
