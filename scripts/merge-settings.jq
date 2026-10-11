def require_object(message):
  if type == "object" then . else error(message) end;

def existing_document:
  if $initial then {}
  elif length == 1 then .[0]
  else error($target + " must contain one object") end
  | require_object("Albedo settings must contain an object");

def validate_extensions:
  if (has("enabled") and (.enabled | type != "object"))
      or (has("web-search") and (.["web-search"] | type != "object"))
  then error("Albedo extension settings must contain objects")
  else . end;

def validate_providers:
  if (has("providers") and (.providers | type != "object"))
      or (has("active") and (.active | type != "string"))
  then error("Invalid Albedo provider settings")
  elif length > 0 and (has("providers") | not)
  then error("Let Albedo migrate legacy provider settings before applying defaults")
  else . end
  | if has("providers") and any(.providers[]; type != "object")
    then error("Albedo provider profiles must contain objects")
    else . end;

def validate_capabilities:
  if has("global") then
    .global | require_object("Albedo global capabilities must contain an object")
    | [to_entries[] | select(.key == "skills" or .key == "instructions" or .key == "mcp") | .value]
    | map(require_object("Albedo capability groups must contain objects"))
    | if any(.[]; any(.[]; type != "boolean"))
      then error("Albedo capability choices must be booleans") else . end
  else . end;

def validate_document:
  . as $document
  | if $target == "extensions.json" then validate_extensions
    elif $target == "config.json" then validate_providers
    else validate_capabilities end
  | $document;

def merge_managed:
  if ($defaults | length) != 1 or ($defaults[0] | type) != "object"
  then error("Managed Albedo settings must contain one object")
  else . * $defaults[0] end;

def validate_active_provider:
  if (.providers | type) != "object"
      or (.active | type) != "string"
      or (.providers[.active] | type) != "object"
  then error("Albedo default provider must name a configured profile")
  else . end;

existing_document
| validate_document
| merge_managed
| if $target == "config.json" then validate_active_provider
  elif $target == "capabilities.json" then validate_document else . end
