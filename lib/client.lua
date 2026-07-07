local ltn12 = require("ltn12")

local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")
local ok_socket, socket = pcall(require, "socket")

-- JSON decoder: KOReader ships rapidjson; fall back to cjson/json if present.
local json
do
    for _, name in ipairs({ "rapidjson", "cjson", "json" }) do
        local ok, mod = pcall(require, name)
        if ok and mod then
            json = mod
            break
        end
    end
end

local DEFAULT_TIMEOUT_SECONDS = 15
local unpack_args = unpack or table.unpack

-- Polite rate limit: keep at least this many seconds between requests (guide §10).
local MIN_REQUEST_INTERVAL = 0.2

local Client = {}
Client.__index = Client

Client.BASE = "https://wufazhuce.com"
Client.USER_AGENT = "Mozilla/5.0 (compatible; one.koplugin/0.1)"

-- v3 JSON API (ONE App backend). Plain HTTP on port 8000; every request needs
-- the version/platform query params or the server returns "wrong args".
Client.V3_BASE = "http://v3.wufazhuce.com:8000"
Client.V3_QS = "?version=3.5.0&platform=android"

function Client:new()
    return setmetatable({ _last_request_at = 0 }, self)
end

local function header_value(headers, name)
    if not headers then
        return nil
    end
    local target = name:lower()
    for key, value in pairs(headers) do
        if tostring(key):lower() == target then
            return value
        end
    end
    return nil
end

local function absolute_url(base_url, location)
    if not location or location == "" then
        return nil
    end
    if location:match("^https?://") then
        return location
    end
    local scheme, host = base_url:match("^(https?)://([^/]+)")
    if not scheme then
        return location
    end
    if location:sub(1, 1) == "/" then
        return scheme .. "://" .. host .. location
    end
    local prefix = base_url:match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
    return prefix .. location
end

local function transport_request(transport, request, timeout)
    timeout = timeout or DEFAULT_TIMEOUT_SECONDS
    local previous_timeout = transport.TIMEOUT
    transport.TIMEOUT = timeout
    local results = { pcall(transport.request, request) }
    transport.TIMEOUT = previous_timeout
    if not results[1] then
        error(results[2])
    end
    table.remove(results, 1)
    return unpack_args(results)
end

-- Throttle so we never hammer the site faster than MIN_REQUEST_INTERVAL.
function Client:_throttle()
    if not (ok_socket and socket and socket.gettime) then
        return
    end
    local now = socket.gettime()
    local wait = MIN_REQUEST_INTERVAL - (now - (self._last_request_at or 0))
    if wait > 0 and socket.sleep then
        socket.sleep(wait)
    end
    self._last_request_at = socket.gettime()
end

function Client:request(opts)
    self:_throttle()
    local response = {}
    local headers = opts.headers or {}
    headers["User-Agent"] = headers["User-Agent"] or Client.USER_AGENT
    headers["Accept"] = headers["Accept"] or "text/html,application/xhtml+xml,*/*"

    local is_https = opts.url:match("^https:") ~= nil
    local transport = is_https and https or http
    if is_https and not ok_https then
        error("ssl.https is not available")
    elseif not is_https and not ok_http then
        error("socket.http is not available")
    end

    local _, code, resp_headers, status = transport_request(transport, {
        url = opts.url,
        method = opts.method or "GET",
        headers = headers,
        sink = ltn12.sink.table(response),
    }, opts.timeout)

    return table.concat(response), tonumber(code), resp_headers or {}, status
end

function Client:request_follow(opts, max_redirects)
    max_redirects = max_redirects or 5
    local url = opts.url
    for _i = 1, max_redirects + 1 do
        opts.url = url
        local text, code, resp_headers, status = self:request(opts)
        if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
            local location = header_value(resp_headers, "location")
            if not location then
                return text, code, resp_headers, status
            end
            url = absolute_url(url, location)
        else
            return text, code, resp_headers, status
        end
    end
    error("Too many redirects")
end

-- Fetch an HTML/text page. Returns body on 2xx, or (nil, code) otherwise so the
-- caller can distinguish 404 (skipped ids in date search) from success.
function Client:get_text(url, opts)
    opts = opts or {}
    local text, code = self:request_follow({
        url = url,
        method = "GET",
        headers = { ["Accept"] = "text/html,application/xhtml+xml,*/*" },
        timeout = opts.timeout,
    })
    if code and code >= 200 and code < 300 then
        return text, code
    end
    return nil, code
end

-- Decode a JSON string with whatever decoder is available. Returns table or nil.
local function json_decode(text)
    if not json or not text then
        return nil
    end
    local ok, result = pcall(function()
        if json.decode then
            return json.decode(text)
        end
        return json:decode(text)
    end)
    if ok and type(result) == "table" then
        return result
    end
    return nil
end

Client.has_json = json ~= nil

-- GET a v3 JSON endpoint. `path` is like "/api/hp/detail/5147"; version/platform
-- params are appended automatically. Returns the decoded `data` field on success
-- (res == 0 and data present), or nil plus an error tag ("404" when the item
-- exists-but-empty, "http:<code>", "decode", "res:<n>", "nojson").
function Client:get_json(path, opts)
    opts = opts or {}
    if not json then
        return nil, "nojson"
    end
    local text, code = self:request_follow({
        url = Client.V3_BASE .. path .. Client.V3_QS,
        method = "GET",
        headers = { ["Accept"] = "application/json" },
        timeout = opts.timeout,
    })
    if not code or code < 200 or code >= 300 then
        return nil, "http:" .. tostring(code)
    end
    local decoded = json_decode(text)
    if not decoded then
        return nil, "decode"
    end
    if decoded.res ~= 0 then
        return nil, "res:" .. tostring(decoded.res)
    end
    -- res==0 with no data means "exists but empty" == not found (guide §4).
    if decoded.data == nil then
        return nil, "404"
    end
    return decoded.data
end

-- Download binary data (images). Returns (data, code) on success, (nil, code) otherwise.
function Client:get_binary(url, opts)
    opts = opts or {}
    local text, code = self:request_follow({
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = "image/*,*/*",
            ["Referer"] = opts.referer or (Client.BASE .. "/"),
        },
        timeout = opts.timeout,
    })
    if code and code >= 200 and code < 300 then
        return text, code
    end
    return nil, code
end

return Client
