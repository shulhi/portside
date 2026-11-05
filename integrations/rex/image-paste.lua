local M = {}

local function inspect_local_client(ctx, options)
  if not ctx.server or ctx.server == "" then
    return rex.call("client.inspect", {client_id = ctx.client_id})
  end

  -- In a remote pane Rex routes rex.call to the pane's server, but the
  -- action's client_id belongs to the home server that ran the action.
  local socket = options.local_socket or
    (assert(os.getenv("HOME")) .. "/Library/Application Support/rex/server.sock")
  local endpoint = "unix://" .. socket:gsub("[^%w%-%._~/]", function(char)
    return string.format("%%%02X", char:byte())
  end)
  local result = rex.exec({options.rex_cli or "rex", "--server", endpoint,
    "--autostart=false", "--timeout", "3s", "api", "call", "client.inspect",
    assert(rex.json.encode({client_id = ctx.client_id}))}, {timeout = 4})
  if result and result.ok then return rex.json.decode(result.stdout) end
end

function M.setup(options)
  assert(type(options.helper) == "string" and options.helper:sub(1, 1) == "/",
    "Portside image paste needs an absolute helper path")
  rex.action {
    name = "portside_image_paste",
    title = "Paste Image with Portside",
    category = "Clipboard",
    run = function(ctx)
      if not ctx.session_id or not ctx.block_id or not ctx.client_id then
        error("Open a Rex terminal on this Mac to paste an image.", 0)
      end
      local client = inspect_local_client(ctx, options)
      local principal = client and client.client and client.client.principal
      if not principal or principal.kind ~= "peer" or principal.transport ~= "unix" then
        error("This action can only read the clipboard of the Mac running Rex.", 0)
      end

      -- Use the original target even if focus changes while the upload runs.
      local server, session, block = ctx.server, ctx.session_id, ctx.block_id
      local argv, api = {options.helper}, rex
      if server and server ~= "" then
        local destination = (options.hosts or {})[server]
        if not destination then
          error("No Portside upload server is configured for Rex host " .. server .. ".", 0)
        end
        api = assert(rex.server(server))
        local attached, attach_error = api.call("session.attach", {session_id = session})
        if not attached then
          error("Could not reach the original Rex session: " .. tostring(attach_error), 0)
        end
        argv = {options.helper, "--progress", "--host", destination.host, "--port", tostring(destination.port or 9417),
          "--folder", destination.folder or ""}
      end
      local result, err = rex.exec(argv, {timeout = 25})
      if not result or not result.ok then
        local reason = result and result.stderr or err
        error("Portside image paste: " .. tostring(reason or "upload failed"), 0)
      end
      local path = result.stdout:gsub("\n$", "")
      if path == "" then return end -- text-only clipboard: leave the pane alone
      if path:sub(1, 1) ~= "/" or path:find("%c") then
        error("Portside image paste returned an invalid file path.", 0)
      end
      local pasted, paste_error = api.call("block.event", {
        session_id = session, block_id = block,
        event = {type = "paste", payload = {text = path}},
      })
      if not pasted then error("Could not paste the saved image path: " .. tostring(paste_error), 0) end
      return {path = path}
    end,
  }
end

return M
