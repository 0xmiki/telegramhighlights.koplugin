local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local TextViewer = require("ui/widget/textviewer")
local ButtonDialog = require("ui/widget/buttondialog")
-- local logger = require("logger")
local _ = require("gettext")
local sendHighlightToBot = require("send_highlight")
local saveAndSendHighlightToBot = require("save_send_highlight")
local sendBookmarkToBot = require("send_from_bookmarks")
local sendBulkBookmarksToBot = require("send_from_bookmarks_bulk")
local Screenshoter = require("custom_screenshot")

local TelegramHighlights = WidgetContainer:new {
    name = "telegramhighlights",
    BOT_SERVER_URL = "https://koreader-plugin-bot-server.0xmiki.deno.net/highlight",
    verification_code = "",
}

function TelegramHighlights:init()
    self.settings = G_reader_settings:readSetting("telegramhighlights") or {}
    self.verification_code = self.settings.verification_code or ""
    self.settings.send_screenshots_to_bot = self.settings.send_screenshots_to_bot or true

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    

    if self.settings.send_screenshots_to_bot then
        -- Register the custom screenshot module
        self:replaceScreenshotModule()
    end
      
    -- Handle ReaderUI-specific initialization  
    if self.ui and self.ui.registerPostReaderReadyCallback then  
        self.ui:registerPostReaderReadyCallback(function()
            if self.settings.send_screenshots_to_bot then 
                self:replaceScreenshotModule()  
            end
        end)  
    end  
    
    -- Extend highlight menu if available
    if self.ui and self.ui.highlight then
        self:extendHighlightMenu()
    end
    -- Extend bookmark details if available
    if self.ui and self.ui.bookmark then
        self:extendBookmarkSelectionMenu()
        self:extendBookmarkDetails()
       
    end   

    if self.ui and self.ui.registerPostInitCallback then
        self.ui:registerPostInitCallback(function()
            if self.ui.highlight then
                self:extendHighlightMenu()
            end
            if self.ui.bookmark then
                self:extendBookmarkDetails()
                self:extendBookmarkSelectionMenu()
            end
        end)
    end
    
end

function TelegramHighlights:replaceScreenshotModule() 
    if not self.ui or not self.ui.screenshot then  
        return  
    end  
      
    -- Determine UI type and appropriate prefix  
    local prefix = "FileManager"  
    local extra_params = {}  
      
    -- Check if this is ReaderUI by looking for reader-specific properties  
    if self.ui.view and self.ui.dialog then  
        prefix = "Reader"  
        extra_params.dialog = self.ui.dialog  
        extra_params.view = self.ui.view  
    end  
      
    -- Remove existing screenshot module from active_widgets  
    for i = #self.ui.active_widgets, 1, -1 do
        if self.ui.active_widgets[i] == self.ui.screenshot then
            table.remove(self.ui.active_widgets, i)
            break
        end
    end
    
    -- also remove the screnshot module from the dialog for readerui 
    if prefix == "Reader" then
        for i = #self.ui.dialog, 1, -1 do  
            if self.ui.dialog[i] == self.ui.screenshot then  
                table.remove(self.ui.dialog, i)  
                break  
            end  
        end
    end
      
    -- Clear the screenshot reference  
    self.ui.screenshot = nil  
      
    -- Register custom screenshot module  
    local screenshot_params = {  
        prefix = prefix,  
        ui = self.ui,  
        verification_code = self.verification_code,
    }  
      
    -- Add extra parameters for ReaderUI  
    for k, v in pairs(extra_params) do  
        screenshot_params[k] = v  
    end  
      
    self.ui:registerModule("screenshot", Screenshoter:new(screenshot_params), true)
end



function TelegramHighlights:extendHighlightMenu()
    if not self.ui or not self.ui.highlight then return end
    self.ui.highlight:addToHighlightDialog("13_send_to_bot", function(this)
        local is_existing_highlight = this.selected_link and this.selected_link.note
        local has_selected_text = this.selected_text and this.selected_text.text and this.selected_text.text ~= ""
        return {
            text = _("Send to Bot"),
            enabled = (this.hold_pos ~= nil and has_selected_text) or is_existing_highlight,
            callback = function()
                UIManager:scheduleIn(0, function()
                    sendHighlightToBot(self, this)
                end)
            end,
        }
    end)
    self.ui.highlight:addToHighlightDialog("14_save_and_send_to_bot", function(this)
        return {
            text = _("Save Highlight and Send to Bot"),
            enabled = this.hold_pos ~= nil and this.selected_text ~= nil and this.selected_text.text ~= "",
            callback = function()
                UIManager:scheduleIn(0, function()
                    saveAndSendHighlightToBot(self, this)
                end)
            end,
        }
    end)
end


function TelegramHighlights:extendBookmarkSelectionMenu()
    if not self.ui or not self.ui.bookmark then return end

    -- Store original onLeftButtonTap function to extend it
    self.ui.bookmark.onShowBookmark_original = self.ui.bookmark.onShowBookmark_original or
        self.ui.bookmark.onShowBookmark
    self.ui.bookmark.onShowBookmark = function(bookmark_self)
        -- Call original function
        bookmark_self:onShowBookmark_original()

        -- Now extend the menu that was just created
        if bookmark_self.bookmark_menu and bookmark_self.bookmark_menu[1] then
            local bm_menu = bookmark_self.bookmark_menu[1]

            -- Store original function if we haven't already
            local original_onLeftButtonTap = bm_menu.onLeftButtonTap

            -- Override the onLeftButtonTap function to add our button
            bm_menu.onLeftButtonTap = function(menu_self)
                -- Save the original ButtonDialog:new function
                local original_ButtonDialog_new = ButtonDialog.new

                -- Override ButtonDialog:new to capture the buttons before dialog creation
                ButtonDialog.new = function(self_dialog, params)
                    -- Add our custom buttons before dialog creation
                    if menu_self.select_count then
                        -- Add button for select mode
                        for i, button_group in ipairs(params.buttons) do
                            for j, button in ipairs(button_group) do
                                if button.text == _("Remove") then
                                    table.insert(button_group, {
                                        text = _("Send Selected to Bot"),
                                        enabled = menu_self.select_count > 0,
                                        callback = function()
                                            -- Don't close the dialog
                                            local selected_items = {}
                                            for _, v in ipairs(menu_self.item_table) do
                                                if v.dim then
                                                    table.insert(selected_items, v)
                                                end
                                            end
                                            sendBulkBookmarksToBot(self, selected_items)
                                        end,
                                    })
                                    break
                                end
                            end
                        end
                    else
                        -- Add button for normal mode
                        for i, button_group in ipairs(params.buttons) do
                            for j, button in ipairs(button_group) do
                                if button.text == _("Export annotations") then
                                    -- Add our button after Export annotations
                                    
                                   
                                    table.insert(params.buttons, {
                                        {
                                            text = _("Send All to Bot"),
                                            enabled = #menu_self.item_table > 0,
                                            callback = function()
                                                -- Don't close the dialog
                                                sendBulkBookmarksToBot(self, menu_self.item_table)
                                            end,
                                        },
                                    })
                                    break
                                end
                            end
                        end
                    end

                    -- Call the original ButtonDialog.new
                    return original_ButtonDialog_new(self_dialog, params)
                end

                -- Call the original onLeftButtonTap function
                local result = original_onLeftButtonTap(menu_self)

                -- Restore the original ButtonDialog.new
                ButtonDialog.new = original_ButtonDialog_new

                return result
            end
        end
    end
end

function TelegramHighlights:extendBookmarkDetails()
    if not self.ui or not self.ui.bookmark then return end

    -- Store the original function
    self.ui.bookmark.showBookmarkDetails_original = self.ui.bookmark.showBookmarkDetails_original or
        self.ui.bookmark.showBookmarkDetails

    -- Override with our extended version
    self.ui.bookmark.showBookmarkDetails = function(bookmark_self, item_or_index)
        -- Get the item details
        local item_table, item, item_idx, item_type
        local bm_menu = bookmark_self.bookmark_menu and bookmark_self.bookmark_menu[1]
        if bm_menu then -- called from Bookmark list, got item
            item_table = bm_menu.item_table
            item = item_or_index
            item_idx = item.idx
            item_type = item.type
        else -- called from Reader, got index
            item_table = bookmark_self.ui.annotation.annotations
            item_idx = item_or_index
            item = item_table[item_idx]
            item_type = bookmark_self.getBookmarkType(item)
        end

        -- Create a wrapper around the original function that captures its local variables
        local function run_original()
            -- Store original TextViewer.new to restore it later
            local original_TextViewer_new = TextViewer.new

            -- Create a modified version of TextViewer.new that adds our button
            TextViewer.new = function(self_tv, params)
                if params.text_type == "bookmark" then
                    -- Add our button to the third row (with Remove and Add/Edit note)
                    if params.buttons_table and #params.buttons_table >= 3 then
                        -- Add our button to the existing row
                        table.insert(params.buttons_table[3], {
                            text = _("Send to Bot"),
                            callback = function()
                                -- Don't close the TextViewer, just send the bookmark
                                sendBookmarkToBot(self, item)
                            end,
                        })
                    end
                end

                -- Call the original TextViewer.new
                return original_TextViewer_new(self_tv, params)
            end

            -- Call the original function
            local result = bookmark_self.showBookmarkDetails_original(bookmark_self, item_or_index)

            -- Restore the original TextViewer.new
            TextViewer.new = original_TextViewer_new

            return result
        end

        -- Run the wrapped function
        return run_original()
    end
end

function TelegramHighlights:addToMainMenu(menu_items)
    menu_items.telegramhighlights = {
        text = _("Telegram Highlights"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Set verification code"),
                keep_menu_open = true,
                callback = function()
                    local password_dialog
                    password_dialog = InputDialog:new {
                        title = _("Telegram Bot Verification Code"),
                        input = self.verification_code,
                        description = _("Enter the verification code you received from @bookshotsbot"),
                        buttons = { {
                            {
                                text = _("Cancel"),
                                id = "close",
                                callback = function()
                                    UIManager:close(password_dialog)
                                end,
                            },
                            {
                                text = _("Save"),
                                callback = function()
                                    self.verification_code = password_dialog:getInputText()
                                    self.settings.verification_code = self.verification_code
                                    G_reader_settings:saveSetting("telegramhighlights", self.settings)
                                    UIManager:close(password_dialog)
                                    UIManager:show(Notification:new {
                                        text = _("Verification code saved."),
                                        timeout = 2,
                                    })
                                end,
                            },
                        } },
                    }
                    UIManager:show(password_dialog)
                    password_dialog:onShowKeyboard()
                end,
            },
            {
                text = _("Get Send to Bot option on screenshots (requires restart)"),
                checked_func = function()
                    return self.settings.send_screenshots_to_bot 
                end,
                callback = function()
                    self.settings.send_screenshots_to_bot = not self.settings.send_screenshots_to_bot
                    G_reader_settings:saveSetting("telegramhighlights", self.settings)
                    UIManager:show(Notification:new {
                        text = self.settings.send_screenshots_to_bot and
                            _("Send to bot option enabled on screenshots") or
                            _("Send to bot option disabled on screenshots"),
                        timeout = 2,
                    })
                end,
            },
            {
                text = _("About Telegram Highlights"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new {
                        text = _("Telegram Highlights allows you to send book highlights to a Telegram bot.\n\nTo use this plugin:\n1. Start a chat with @bookshotsbot on Telegram\n2. Get your verification code\n3. Enter the code in the plugin settings\n4. Select text in a book and use 'Send to Bot' from the highlight menu\n"),
                    })
                end,
            },
        },
    }
end

return TelegramHighlights
