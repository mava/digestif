local FileCache = require "digestif.FileCache"
local Manuscript = require "digestif.Manuscript"
local util = require "digestif.util"

local concat = table.concat
local path_join, path_split = util.path_join, util.path_split
local nested_get, nested_put = util.nested_get, util.nested_put
local map, update, merge = util.map, util.update, util.merge

local cache = FileCache()
local null = util.null
local trace, root_dir, client_capabilities

local function hex_to_char(hex)
   return string.format('%c', tonumber(hex, 16))
end

local function unescape_uri(s)
   s = s:match("^file://(.*)") or error("Invalid URI: " .. s)
   return s:gsub('%%(%x%x)', hex_to_char), nil
end

local function escape_uri(s)
   return "file://" .. s
end

local function get_manuscript(filename, tex_format)
  return Manuscript{
    filename = filename,
    cache = cache,
    format = tex_format
  }
end
get_manuscript = util.memoize(get_manuscript)

-- Convert LSP API objects to/from internal representations

--@param arg a TextDocumentPositionParam object
--@return a position in bytes, filename, root's filename
local function from_TextDocumentPositionParams(arg)
  local filename = unescape_uri(arg.textDocument.uri)
  local l, c = arg.position.line + 1, arg.position.character + 1
  return filename, cache:get_position(filename, l, c)
end

local function to_MarkupContent(str)
  return {kind = "plaintext", value = str}
end

local function to_TextEdit(filename, pos, old, new)
  local l, c_start = cache:get_line_col(filename, pos)
  local c_end = c_start + utf8.len(old)
  return {
    range = {
      start = {line = l - 1, character = c_start - 1},
      ["end"] = {line = l - 1, character = c_end - 1},
    },
    newText = new
  }
end

local function from_Range(filename, range)
  local l1, c1 = range.start.line + 1, range.start.character + 1
  local l2, c2 = range["end"].line + 1, range["end"].character + 1
  local pos1 = cache:get_position(filename, l1, c1) -- inclusive
  local pos2 = cache:get_position(filename, l2, c2) -- exclusive
  return pos1, pos2 - pos1
end
--- LSP methods

local methods = {}

methods["initialize"] = function(params)
  trace = (params.trace == null) and 0 or params.trace
  root_dir = unescape_uri(params.rootUri)
  client_capabilities = params.capabilities
  return {
    capabilities = {
      textDocumentSync = {
        openClose = true,
        change = 2
      },
      completionProvider = {
        triggerCharacters = {"\\", "{", "["},
      },
      signatureHelpProvider = {
        triggerCharacters = {"\\", "="},
      },
      hoverProvider = true,
    }
  }
end

methods["initialized"] = function() return end

methods["shutdown"] = function() return null end

methods["exit"] = function() os.exit() end

methods["workspace/didChangeConfiguration"] = function() return end

methods["textDocument/didOpen"] = function(params)
  local filename = unescape_uri(params.textDocument.uri)
  cache:put(filename, params.textDocument.text)
  cache:put_property(filename, "tex_format", params.textDocument.languageId)
  cache:put_property(filename, "version", params.textDocument.version)
  get_manuscript:forget(filename)
end

methods["textDocument/didChange"] = function(params)
  local filename = unescape_uri(params.textDocument.uri)
  for _, change in ipairs(params.contentChanges) do
    if change.range then
      local src = cache:get(filename)
      local pos, len = from_Range(filename, change.range)
      if len ~= change.rangeLength then
        error("Range length mismatch in textdocument/didChange operation")
      end
      src = src:sub(1, pos - 1) .. change.text .. src:sub(pos + len)
      cache:put(filename, src)
    else
      cache:put(filename, change.text)
    end
  end
  cache:put_property(filename, "tex_format", params.textDocument.languageId)
  cache:put_property(filename, "version", params.textDocument.version)
  get_manuscript:forget(filename)
end

methods["textDocument/didClose"] = function(params)
  local filename = unescape_uri(params.textDocument.uri)
  local rootname = cache:get_rootname(filename)
  if rootname then cache:forget(rootname) end
  cache:forget(filename)
end

methods["textDocument/signatureHelp"] = function(params)
   local filename, pos = from_TextDocumentPositionParams(params)
   local rootname = cache:get_rootname(filename) or filename
   local tex_format = cache:get_property(filename, "tex_format")
   local root = get_manuscript(rootname, tex_format)
   root:refresh()
   local script = root:find_manuscript(filename)
   local help = script:get_help(pos)
   if not nested_get(help, "data", "args") then return null end
   return {
      signatures = {
         [1] = {
            label = help.text,
            documentation = help.data.doc,
            parameters = map(
              function (arg)
                return {
                  label = arg.meta,
                  documentation = arg.doc
                }
              end,
              help.data.args),
         }
      },
      activeSignature = 0,
      activeParameter = help.arg and help.arg - 1
   }
end

methods["textDocument/hover"] = function(params)
   local filename, pos = from_TextDocumentPositionParams(params)
   local rootname = cache:get_rootname(filename) or filename
   local tex_format = cache:get_property(filename, "tex_format")
   local root = get_manuscript(rootname, tex_format)
   root:refresh()
   local script = root:find_manuscript(filename)
   local help = script:get_help(pos)
   if not help then return null end
   local contents = help.text .. (help.detail and ": " .. help.detail or "")
   return {contents = to_MarkupContent(contents)}
end

methods["textDocument/completion"] = function(params)
   local filename, pos = from_TextDocumentPositionParams(params)
   local rootname = cache:get_rootname(filename) or filename
   local tex_format = cache:get_property(filename, "tex_format")
   local root = get_manuscript(rootname, tex_format)
   root:refresh()
   local script = root:find_manuscript(filename)
   local candidates = script:complete(pos)
   if not candidates then return null end
   local with_snippets = nested_get(client_capabilities,
                                    "textDocument",
                                    "completion",
                                    "completionItem",
                                    "snippetSupport")
   local result = {}
   for i, cand in ipairs(candidates) do
      local snippet = with_snippets and cand.snippet
      result[i] = {
         label = cand.text,
         filterText = cand.filter_text,
         documentation = cand.summary,
         detail = cand.detail,
         insertTextFormat = snippet and 2 or 1,
         textEdit = to_TextEdit(filename,
                                candidates.pos,
                                candidates.prefix,
                                snippet or cand.text)
      }
   end
   return result
end

return methods
