local _, addon = ...

function addon.RegisterRetailAdapter(api)
  if addon.RegisterFlavorAdapter and api.WOW_PROJECT_MAINLINE ~= nil and
      api.WOW_PROJECT_ID == api.WOW_PROJECT_MAINLINE and
      (api.WOW_PROJECT_CAMELOT == nil or api.WOW_PROJECT_ID ~= api.WOW_PROJECT_CAMELOT) then
    addon.RegisterFlavorAdapter(api.WOW_PROJECT_MAINLINE, "retail", addon.CreateModernCraftAdapter)
  end
end
