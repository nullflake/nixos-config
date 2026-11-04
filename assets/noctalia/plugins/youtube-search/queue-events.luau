-- Forward player updates to the launcher through the plugin's shared state.
function onIpc(event, token)
    if event == "queue-changed" then noctalia.state.set("queue_revision", token) end
end
