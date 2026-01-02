return {
    onGetMaps = function()
        extensions.hook("returnCompatibleMap", {["east_coast_usa"] = "East Coast USA"})
    end
}