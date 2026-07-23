-- toast.lua - Global bottom-left toast notifications, callable from any
-- script/gui_script in the app. Rendered by main/toast.gui_script, a
-- component that lives permanently on the same "controller" game object
-- as every screen, so "#toast" resolves from anywhere without needing a
-- full "controller#toast" address.
--
-- Auto-dismisses after 3s; never grabs input focus, so it can never block
-- taps on whatever's underneath it.

local M = {}

function M.show(text, kind)
    if not text or text == "" then return end
    msg.post("#toast", "show", { text = tostring(text), kind = kind or "error" })
end

function M.error(text) M.show(text, "error") end
function M.success(text) M.show(text, "success") end
function M.info(text) M.show(text, "info") end

return M
