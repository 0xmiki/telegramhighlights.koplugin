local http = require("socket.http")
local ltn12 = require("ltn12")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local _ = require("gettext")
local logger = require("logger") -- Added
local functions = require("functions") -- Added
local socketutil = require("socketutil") -- Added for timeout
local T = require("ffi/util").template -- Added for translation with parameters

local MAX_AUTO_RETRIES = 2 -- Total 3 attempts: 1 initial + 2 retries

local function sendScreenshotToBot(plugin, screenshot_path, _current_attempt)
    _current_attempt = _current_attempt or 1

    local file_check = io.open(screenshot_path, "rb")
    if not file_check then
        UIManager:show(InfoMessage:new{
            text = _("Screenshot file not found."), timeout = 3,
        })
        functions.handleWifiTurnOff()
        return
    end
    file_check:close() -- Close after check

    -- get verification code from the settings 
    local plugin_settings = G_reader_settings:readSetting("telegramhighlights")
    local verification_code = plugin_settings["verification_code"]
    logger.info("Send Screenshot: Verification code:", verification_code, "Attempt:", _current_attempt)
    if not verification_code or verification_code == "" then
        UIManager:show(InfoMessage:new{
            title = _("Configuration Error"),
            text = _("Please set your verification code in the plugin settings."), timeout = 7,
        })
        functions.handleWifiTurnOff()
        return
    end

    local function actual_send_logic()
        local file_send = io.open(screenshot_path, "rb")
        if not file_send then -- Re-check, though unlikely to fail if first check passed
            logger.error("Send Screenshot: File disappeared before sending:", screenshot_path)
            UIManager:show(InfoMessage:new{ text = _("Screenshot file error."), timeout = 3})
            functions.handleWifiTurnOff()
            return
        end
        local image_data = file_send:read("*all")
        file_send:close()

        local boundary = "----formdata" .. os.time() .. math.random(1000, 9999) -- Added randomness
        local body_parts = {}
        table.insert(body_parts, "--" .. boundary)
        table.insert(body_parts, 'Content-Disposition: form-data; name="code"')
        table.insert(body_parts, "")
        table.insert(body_parts, verification_code:upper()) -- Ensure uppercase
        table.insert(body_parts, "--" .. boundary)
        table.insert(body_parts, 'Content-Disposition: form-data; name="image"; filename="screenshot.png"')
        table.insert(body_parts, "Content-Type: image/png")
        table.insert(body_parts, "")
        table.insert(body_parts, image_data)
        table.insert(body_parts, "--" .. boundary .. "--")
        local body_str = table.concat(body_parts, "\r\n") .. "\r\n"

        local response_sink = {}
        local timeout_seconds = 30 -- Increased timeout for image upload
        socketutil:set_timeout(timeout_seconds)
        local pcall_ok, http_res_val, http_status_code = pcall(http.request, {
            url = "https://koreader-plugin-bot-server.0xmiki.deno.net/send_screenshot",
            method = "POST",
            headers = {
                ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
                ["Content-Length"] = tostring(#body_str),
                ["User-Agent"] = "KOReader Telegram Highlights Plugin",
            },
            source = ltn12.source.string(body_str),
            sink = ltn12.sink.table(response_sink),
        })
        socketutil:reset_timeout()

        local response_body_concat = table.concat(response_sink)

        if pcall_ok and http_status_code == 200 then
            UIManager:show(InfoMessage:new {
                text = _("Screenshot sent successfully!"),
                timeout = 3,
            })
            functions.handleWifiTurnOff()
        else
            logger.warn("Send Screenshot: Failed. Attempt:", _current_attempt, "pcall_ok:", pcall_ok, "HTTP Status:", http_status_code, "Body:", response_body_concat)
            if _current_attempt <= MAX_AUTO_RETRIES then
                logger.info("Send Screenshot: Scheduling automatic retry", _current_attempt + 1)
                UIManager:scheduleIn(3, function()
                    sendScreenshotToBot(plugin, screenshot_path,  _current_attempt + 1)
                end)
            else
                logger.warn("Send Screenshot: Max auto retries reached. Showing dialog.")
                local dialog_title = _("Sending Error")
                local dialog_message

                if not pcall_ok then
                    dialog_title = _("Network Error")
                    local pcall_error_message = http_res_val or _("Unknown network issue.") -- http_res_val contains the error message from pcall
                    dialog_message = _("Failed to send screenshot due to a network issue after multiple attempts. Would you like to retry?")
                    if pcall_error_message ~= "" then
                        dialog_message = dialog_message .. "\n\n" .. _("Details: ") .. tostring(pcall_error_message)
                    end
                else -- pcall_ok true, but HTTP status not 200
                    if http_status_code == 403 then
                         dialog_title = _("Authorization Error")
                         dialog_message = _("Server rejected the request: Invalid verification code.") ..
                                         "\n\n" .. _("Please check your verification code in the plugin settings.") ..
                                         "\n\n" .. _("Would you like to retry?")
                    elseif http_status_code == 400 then
                        dialog_title = _("Bad Request")
                        dialog_message = T(_("Server reported bad data (Error %1).", http_status_code)) ..
                                         "\nError: " .. tostring(response_body_concat) ..
                                         "\n\n" .. _("Would you like to retry?")
                    elseif http_status_code == 413 then
                        dialog_title = _("File Too Large")
                        dialog_message = T(_("Screenshot is too large (Error %1). Please try a smaller image.", http_status_code)) ..
                                         "\nServer message: " .. tostring(response_body_concat) ..
                                         "\n\n" .. _("Would you like to retry with a different screenshot (if applicable)?") -- Retry might not make sense for same large file
                    elseif http_status_code == 500 then
                        dialog_title = _("Server Error")
                        dialog_message = T(_("Server encountered an internal error (Error %1). Please try again later.", http_status_code)) ..
                                         "\n\n" .. _("Would you like to retry?")
                    else
                        dialog_message = T(_("Failed to send screenshot. Server responded with code: %1 after multiple attempts. Would you like to retry?"), http_status_code or "Unknown")
                        if response_body_concat and response_body_concat ~= "" then
                             dialog_message = dialog_message .. "\n\n" .. _("Server message: ") .. response_body_concat
                        end
                    end
                end

                functions.showNetworkErrorDialog(
                    dialog_title,
                    dialog_message,
                    function()
                        sendScreenshotToBot(plugin, screenshot_path,  1) -- Reset attempts for manual retry
                    end,
                    nil -- No custom cancel logic for screenshot
                )
            end
        end
    end


    if not NetworkMgr:isConnected() then    
        logger.info("Send to Bot: Network not connected. Using WiFi action setting.")    
          
        -- Add error handling for LIPC issues  
        local success, result = pcall(function()  
            NetworkMgr:beforeWifiAction(function()    
                sendScreenshotToBot(plugin, screenshot_path,  1) 
            end)  
        end)  
          
        if not success then  
            logger.warn("WiFi action failed:", result)  
            -- Fall back to manual prompt  
            NetworkMgr:promptWifiOn(function()  
                sendScreenshotToBot(plugin, screenshot_path,  1) 
            end, _("Connect to Wi-Fi to send the screenshot?"))  
        end  
        return    
    end

    actual_send_logic()
end

return sendScreenshotToBot
