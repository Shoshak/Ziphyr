-- Ziphyr - OpenComputers github interaction
-- Copyright (C) 2021 KoshakLoL

-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.

-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.

-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see https://www.gnu.org/licenses

local filesystem = require("filesystem")
local shell = require("shell")
local computer = require("computer")
local component = require("component")
local internet = component.internet
local text = require("text")
local json = require("json")
local sha = require("sha1")  -- Timestamps are being stored in sha, because global sha's are stored in the same way

local function get_handle(link, headers)  -- Get request handler
    response = internet.request(link, nil, headers)
    local start = computer.uptime()
    local timeout = 20  -- 20 seconds is the most balanced timeout
    while true do
        local status, reason = response.finishConnect()  -- Checking request status
        if status then  -- If the request went through
            return response
        elseif status == nil then  -- If there was an error in the request
            local err = ("request failed: %s"):format(reason or "unknown error")
            print(err)
            return nil, err
        elseif computer.uptime() >= start + timeout then  -- If the request timeouted
            response.close()
            print("connection timed out")
            return nil, "connection timed out"
        end
    end
end

local function get_response(handle, file_path)  -- Get handler contents
    local result = ""
    local hold_con = true
    while hold_con do  -- Read handler contents until there is no data left
        local data, reason = handle.read()
        if data then
            result = result..data
        else
            handle.close()
            hold_con = false
        end
    end
    if file_path then  -- Save to file if file_path is present
        print("Saving in: "..file_path)
        local f = io.open(file_path, "w")
        f:write(result)
        f:close()
    else
        return result
    end
end

local function get_json(string)  -- Get json of a string
    local string = text.trim(string)
    return json.decode(string)
end

local function file_to_hash(file_path)  -- Returns file modification date converted to hash
    return sha.hex(tostring(filesystem.lastModified(file_path))..":"..file_path)
end

function gh(mode, rep_name, auth_token, folder, ver)  -- Main class
    this = {}
    this.rep_name = rep_name  -- Raw repository name
    this.folder = folder  -- Full path to folder if supplied
    this.ver = ver  -- For what commit/release to download
    private = {}
    if auth_token then  -- Setting headers with github token
        private._headers = {["Authorization"] = "Token "..auth_token}  
    end -- Technically the script can work without tokens, so we give this option
    private._folder_path = ""  -- Path to local folder
    private._contents_link = ""  -- Link to api contents folder
    private._contents = {}  -- All github repository contents
    private._download_query = {}  -- To-download query
    private._global_hashes = {}  -- Hashes from github repository contents
    private._local_hashes = {}  -- Hashes from local repository contents
    private._rep_private = false  -- Checks if the rep is private
    private._clone_token = ""  -- Clone token for private repositories

    function private._get_repo()  -- Get repository info
        if mode:lower() == "pull" then  -- If pull
            local f = io.open(filesystem.concat(private._info_folder, "repository_info"), "r")
            this.rep_name = f:read("*l")
            this.ver = f:read("*l")
            f:close()
        end
        local rep_link = "https://api.github.com/repos/"..this.rep_name
        print("Getting info about "..rep_link)
        local handle = get_handle(rep_link, private._headers)
        local rep_info = get_json(get_response(handle))
        if not this.ver then  -- If no version specified - get the default branch
            this.ver = rep_info.default_branch
        end
        private._rep_private = rep_info.private
    end

    function private._get_token()  -- Gets temprorary clone token for private repositories, needs to be done right before download
        local rep_info = get_json(get_response(get_handle("https://api.github.com/repos/"..this.rep_name, private._headers)))
        return rep_info.temp_clone_token
    end

    function private._get_git_folder()  -- Sets folders
        -- Creating folder or working in an existing one:
        if this.folder then
            private._folder_path = shell.resolve(this.folder)
        else
            private._folder_path = filesystem.concat(shell.getWorkingDirectory(), this.rep_name:sub(this.rep_name:find("/")+1, this.rep_name:len()))
        end
        private._info_folder = filesystem.concat(private._folder_path, ".ziphyr")  -- Create hashes folder
        filesystem.makeDirectory(private._folder_path)
        filesystem.makeDirectory(private._info_folder)
    end

    function private._get_contents(tree_id, prev_path)  -- Gets repository content
        local link = "https://api.github.com/repos/"..this.rep_name.."/git/trees/"..tree_id
        local handle = get_handle(link, private._headers)
        local con_info = get_json(get_response(handle)).tree
        for count=1, #con_info do  -- For current repository folder
            local element = con_info[count]
            print("Indexing: ", element.path)
            if element.type == "blob" then
                private._contents[element.sha] = prev_path..element.path.."/"  -- Add to contents with key of sha hash
            else  -- Calling a recursive function:
                print("Traversing to "..element.path)
                filesystem.makeDirectory(filesystem.concat(private._folder_path, element.path))
                private._get_contents(element.sha, prev_path..element.path.."/")
                print("Traversing back...")
            end
        end
    end

    function private._store_info()  -- Stores info
        local f = io.open(filesystem.concat(private._info_folder, "hashes"), "w")
        local f_l = io.open(filesystem.concat(private._info_folder, "local_hashes"), "w")
        for k, v in pairs(private._contents) do
            print("Storing global sha hash for: "..v)
            f:write(k.." "..v.."\n")
            print("Storing local sha hash for: "..v)
            f_l:write(file_to_hash(filesystem.concat(private._folder_path, v)).." "..v.."\n")
        end
        f:close()
        f_l:close()

        local f_r_path = filesystem.concat(private._info_folder, "repository_info")
        if not filesystem.exists(f_r_path) then
            local f = io.open(f_r_path, "w")
            f:write(this.rep_name.."\n"..this.ver)
            f:close()
        end
    end

    function private._read_info()  -- Reads local hash info
        local path = filesystem.concat(private._info_folder, "hashes")
        local lcl_path = filesystem.concat(private._info_folder, "local_hashes")
        if filesystem.exists(path) and filesystem.exists(lcl_path) then
            local f = io.lines(path)
            for line in f do
                local hashname = text.tokenize(line) -- hash = hashname[1], name = hashname[2]
                private._global_hashes[hashname[1]] = hashname[2]
            end
            local f_l = io.lines(lcl_path)
            for line in f_l do
                local hashname = text.tokenize(line) -- hash = hashname[1], name = hashname[2]
                private._local_hashes[hashname[1]] = hashname[2]
            end
        else
            print("No hash file found! Reclone the repository and try again")
        end
    end

    function private._compare_info()  -- Compares local and global hashes
        print("Checking global hashes...")
        for k, v in pairs(private._contents) do
            if not private._global_hashes[k] then
                print("New file update: "..v)
                table.insert(private._download_query, v)
            end
        end
        print("Checking local hashes...")
        for k, v in pairs(private._local_hashes) do
            local u_timestamp = file_to_hash(filesystem.concat(private._folder_path, v))
            if u_timestamp ~= k and u_timestamp then
                local down = true -- To prevent redownload
                for _, existing_query in pairs(private._download_query) do
                    if v == existing_query then down = false end
                end
                if down then
                    print("File out of date: "..v)
                    table.insert(private._download_query, v)
                end
            end
        end
    end

    function private._download_content()  -- Download content from a query
        for _, file_path in pairs(private._download_query) do
            print("Downloading: "..file_path)
            local raw_file_path = "https://raw.githubusercontent.com/"..this.rep_name.."/"..this.ver.."/"..file_path:gsub("%s", "%%20"):sub(0, -2)
            if private._rep_private then  -- If the rep is private then we add token to the file_path
                raw_file_path = raw_file_path.."?token="..private._get_token()
                handle = get_handle(raw_file_path, private._headers)
            else
                handle = get_handle(raw_file_path)  -- We should send the token only if necessary
            end
            get_response(handle, filesystem.concat(private._folder_path, file_path))
        end
    end

    function this.clone_hub()  -- Sequence to clone
        private._get_git_folder()
        private._get_repo()
        print("Cloning "..this.rep_name.." in "..private._folder_path)
        private._get_contents(this.ver, "")
        private._download_query = private._contents
        private._download_content()
        private._store_info()
    end

    function this.pull_hub()  -- Sequence to pull
        private._get_git_folder()
        private._get_repo()
        print("Pulling "..this.rep_name.." in "..private._folder_path)
        private._get_contents(this.ver, "")
        private._read_info()
        private._compare_info()
        private._download_content()
        private._store_info()
    end

    if mode:lower() == "clone" then
        this.clone_hub()
    elseif mode:lower() == "pull" then
        this.pull_hub()
    end
end

local function ziphyr_help()
    print("Ziphyr - github interaction tool")
    print("To clone: ziphyr clone [--dir=<directory to clone>] [--ver=<what version to clone>] [rep list]")
    print("To pull: ziphyr pull [directory of an existing repository]")
end

local function main(args, options)
    local token = os.getenv("TOKEN")  -- Pulling token from env_var
    if #args < 1 then
        ziphyr_help()
    elseif #args < 2 then
        print("No arguments supplied!")
    else
        if options["d"] == true or options["dir"] == true then
            options["dir"] = shell.getWorkingDirectory()
        end
        if type(options["ver"]) ~= "string" then
            options["ver"] = nil
        end
        if args[1] == "clone" then
            for i=2, #args do
                gh(args[1], args[i], token, options["dir"], options["ver"]) -- Mode, repository, token, directory, version
            end
        elseif args[1] == "pull" then
            gh(args[1], nil, token, args[2], nil) -- Mode, token, folder_path
        end
    end
end

main(shell.parse(...))
