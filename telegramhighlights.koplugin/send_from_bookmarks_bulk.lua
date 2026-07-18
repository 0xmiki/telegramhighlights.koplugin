local JSON = require("json")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local functions = require("functions")
local InfoMessage = require("ui/widget/infomessage")
local util         = require("util")

local MAX_AUTO_RETRIES = 2 -- Total 3 attempts: 1 initial + 2 retries

local function sendBulkBookmarksToBot(self, items,  _current_attempt)
    _current_attempt = _current_attempt or 1

    if not items or #items == 0 then
        UIManager:show(Notification:new { text = _("No bookmarks selected to send."), timeout = 2 })
        functions.handleWifiTurnOff()
        return
    end

    local file_path = self.ui.document.file
    local path, filename = util.splitFilePathName(file_path)

    local title = self.ui.doc_props and self.ui.doc_props.title or filename or _("Unknown Book")
    local author = self.ui.doc_props and self.ui.doc_props.authors or _("Unknown Author")

    if not self.verification_code or self.verification_code == "" then
        UIManager:show(InfoMessage:new {
            title = _("Configuration Error"),
            text = _("Please set your verification code in the Telegram Highlights settings menu."),
            timeout = 7
        })
        functions.handleWifiTurnOff()
        return
    end
    local verification_code = self.verification_code:upper()


    local payload = {
        code = verification_code,
        title = title,
        author = author,
        bookmarks = items,
    }

    local ok_encode, json_payload_or_err = pcall(JSON.encode, payload)
    if not ok_encode then
        logger.info("Failed to encode JSON payload for bulk send:", json_payload_or_err)
        UIManager:show(InfoMessage:new { title = _("Internal Error"), text = _("Failed to prepare data for sending."), timeout = 3 })
        functions.handleWifiTurnOff()
        return
    end
    local json_payload = json_payload_or_err

    local function actual_send_request()
        if not items or #items == 0 then -- Should have been caught earlier, but defensive
            UIManager:show(Notification:new { text = _("No bookmarks found"), timeout = 2 })
            functions.handleWifiTurnOff()
            return
        end

        local sink = {}
        socketutil:set_timeout(30)
        local BOT_BULK_SERVER_URL = "https://koreader-plugin-bot-server.0xmiki.deno.net/bulk_create"
        local req_params = {
            url = BOT_BULK_SERVER_URL,
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = #json_payload,
                ["User-Agent"] = "KOReader Telegram Highlights Plugin",
            },
            source = ltn12.source.string(json_payload),
            sink = ltn12.sink.table(sink),
        }

        local pcall_success, result1_http, result2_http_status = pcall(http.request, req_params)
        socketutil:reset_timeout()

        local response_body_str = table.concat(sink)

        if pcall_success and result2_http_status == 200 then
            logger.info("Successfully sent bulk bookmarks to the bot.")
            UIManager:show(InfoMessage:new {
                text = T(_("Successfully sent %1 bookmarks."), #items),
                timeout = 3,
            })
            functions.handleWifiTurnOff()
        else
            logger.warn("Bulk Send: Failed. Attempt:", _current_attempt, "pcall_success:", pcall_success, "HTTP Status:", result2_http_status, "Body:", response_body_str)
            if _current_attempt <= MAX_AUTO_RETRIES then
                logger.info("Bulk Send: Scheduling automatic retry", _current_attempt + 1)
                UIManager:scheduleIn(3, function()
                    sendBulkBookmarksToBot(self, items, _current_attempt + 1)
                end)
            else
                logger.warn("Bulk Send: Max auto retries reached. Showing dialog.")
                local dialog_title = _("Sending Error")
                local dialog_message

                if not pcall_success then
                    dialog_title = _("Network Error")
                    local pcall_error_message = result1_http or _("Unknown network issue.") -- result1_http is error message from pcall
                    dialog_message = _("Failed to send bookmarks due to a network issue after multiple attempts. Would you like to retry?")
                    if pcall_error_message ~= "" then
                        dialog_message = dialog_message .. "\n\n" .. _("Details: ") .. tostring(pcall_error_message)
                    end
                else -- pcall_success is true, but http status is not 200
                    if result2_http_status == 403 then
                         dialog_title = _("Authorization Error")
                         dialog_message = _("Server rejected the request: Invalid verification code.") ..
                                         "\n\n" .. _("Please check your verification code in the settings menu.") ..
                                         "\n\n" .. _("Would you like to retry?")
                    elseif result2_http_status == 400 then
                        dialog_title = _("Bad Request")
                        dialog_message = T(_("Server reported bad data (Error %1).", result2_http_status)) ..
                                         "\nError: " .. tostring(response_body_str) ..
                                         "\n\n" .. _("Would you like to retry?")
                    elseif result2_http_status == 500 then
                        dialog_title = _("Server Error")
                        dialog_message = T(_("Server encountered an internal error (Error %1). Please try again later.", result2_http_status)) ..
                                         "\n\n" .. _("Would you like to retry?")
                    else
                        dialog_message = T(_("Failed to send bookmarks. Server responded with code: %1 after multiple attempts. Would you like to retry?"), result2_http_status or "Unknown")
                        if response_body_str and response_body_str ~= "" then
                             dialog_message = dialog_message .. "\n\n" .. _("Server message: ") .. response_body_str
                        end
                    end
                end
                functions.showNetworkErrorDialog(
                    dialog_title,
                    dialog_message,
                    function()
                        sendBulkBookmarksToBot(self, items,  1) -- Reset attempts
                    end,
                    nil 
                )
            end
        end
    end

    if not NetworkMgr:isConnected() then    
        logger.info("Send to Bot: Network not connected. Using WiFi action setting.")    
          
        -- Add error handling for LIPC issues  
        local success, result = pcall(function()  
            NetworkMgr:beforeWifiAction(function()    
                sendBulkBookmarksToBot(self, items, 1) -- Start fresh  
            end)  
        end)  
          
        if not success then  
            logger.warn("WiFi action failed:", result)  
            -- Fall back to manual prompt  
            NetworkMgr:promptWifiOn(function()  
                sendBulkBookmarksToBot(self, items, 1) -- Start fresh  
            end, _("Connect to Wi-Fi to send the screenshot?"))  
        end  
        return    
    end

    actual_send_request()
end

return sendBulkBookmarksToBot
