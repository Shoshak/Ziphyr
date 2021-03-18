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

function gh(rep_name, auth_token, folder)  -- Main class
    this = {}
    this.rep_name = rep_name  -- Raw repository name
    this.folder = folder  -- Full path to folder if supplied
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
    private._default_branch = ""  -- Default branch (later we add branches support)

    function private._get_repo()  -- Get repository info
        local rep_link = "https://api.github.com/repos/"..this.rep_name
        print("Getting info about "..rep_link)
        local handle = get_handle(rep_link, private._headers)
        local rep_info = get_json(get_response(handle))
        private._contents_link = rep_info.contents_url:sub(0, -9)  -- Removing ?ref=master or something like that
        private._default_branch = rep_info.default_branch
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
        private._hash_folder = filesystem.concat(private._folder_path, ".ziphyr")  -- Create hashes folder
        filesystem.makeDirectory(private._folder_path)
        filesystem.makeDirectory(private._hash_folder)
    end

    function private._get_contents(link)  -- Gets repository content
        local handle = get_handle(link, private._headers)
        local con_info = get_json(get_response(handle))
        for count=1, #con_info do  -- For current repository folder
            local element = con_info[count]
            print("Indexing: ", element.path)
            if element.type == "file" then
                private._contents[element.sha] = element.path  -- Add to contents with key of sha hash
            else  -- Calling a recursive function:
                print("Traversing to "..element.path)
                filesystem.makeDirectory(filesystem.concat(private._folder_path, element.path))
                private._get_contents(link.."/"..element.name:gsub("%s", "%%20")) -- Thanks to people who put spaces in filenames
                print("Traversing back...")
            end
        end
    end

    function private._store_info()  -- Stores hash info
        local f = io.open(filesystem.concat(private._hash_folder, "hashes"), "w")
        local f_l = io.open(filesystem.concat(private._hash_folder, "local_hashes"), "w")
        for k, v in pairs(private._contents) do
            print("Storing global sha hash for: "..v)
            f:write(k.." "..v.."\n")
            print("Storing local sha hash for: "..v)
            f_l:write(file_to_hash(filesystem.concat(private._folder_path, v)).." "..v.."\n")
        end
        f:close()
        f_l:close()
    end

    function private._read_info()  -- Reads local hash info
        local path = filesystem.concat(private._hash_folder, "hashes")
        local lcl_path = filesystem.concat(private._hash_folder, "local_hashes")
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
        for _, link in pairs(private._download_query) do
            print("Downloading: "..link)
            local raw_link = "https://raw.githubusercontent.com/"..this.rep_name.."/"..private._default_branch.."/"..link:gsub("%s", "%%20")
            if private._rep_private then  -- If the rep is private then we add token to the link
                raw_link = raw_link.."?token="..private._get_token()
                handle = get_handle(raw_link, private._headers)
            else
                handle = get_handle(raw_link)  -- We should send the token only if necessary
            end
            get_response(handle, filesystem.concat(private._folder_path, link))
        end
    end

    function this.clone_hub()  -- Sequence to clone
        private._get_repo()
        private._get_git_folder()
        print("Cloning "..this.rep_name.." in "..private._folder_path)
        private._get_contents(private._contents_link)
        private._download_query = private._contents
        private._download_content()
        private._store_info()
    end

    function this.pull_hub()  -- Sequence to pull
        private._get_repo()
        private._get_git_folder()
        print("Pulling "..this.rep_name.." in "..private._folder_path)
        private._get_contents(private._contents_link)
        private._read_info()
        private._compare_info()
        private._download_content()
        private._store_info()
    end

    return this
end

local function ziphyr_help()
    print("Ziphyr - github interaction tool")
    print("To clone: ziphyr clone [--dir=<directory to clone>] [rep list]")
    print("To pull: ziphyr pull [--dir=<directory to pull>] [rep list]")
end

local function main(args, options)
    local token = os.getenv("TOKEN")  -- Pulling token from env_var
    if #args < 1 then
        ziphyr_help()
    elseif #args < 2 then
        print("No arguments supplied!")
    else
        if options["d"] or options["dir"] then
            options["dir"] = shell.getWorkingDirectory()
        end
        if args[1] == "clone" then
            for i=2, #args do
                local git_thing = gh(args[i], token, options["dir"])
                git_thing.clone_hub()
            end
        elseif args[1] == "pull" then
            local git_thing = gh(args[2], token, options["dir"])
            git_thing.pull_hub()
        end
    end
end

main(shell.parse(...))