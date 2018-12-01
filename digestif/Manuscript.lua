local FileCache = require "digestif.FileCache"
local data = require "digestif.data"
local util = require "digestif.util"

local path_join, path_split = util.path_join, util.path_split
local nested_get, nested_put = util.nested_get, util.nested_put
local map, update, merge = util.map, util.update, util.merge

local Manuscript = util.class()

-- Only descendants of this class (representing various TeX formats)
-- are ever instantiated.  So we replace the constructor by a function
-- defering to the subclass indicated by the format field of the
-- argument.
local formats = {
   latex = "digestif.ManuscriptLaTeX",
   --- etc
}

local function ManuscriptFactory(_, args)
   local fmt = args.format
      or args.parent and args.parent.format
      or "latex"
   return require(formats[fmt])(args)
end

local mt = getmetatable(Manuscript)
mt.__call = ManuscriptFactory

--- Create a new manuscript object.
-- The argument is a table with the following keys:
-- - parent: a parent manuscript object (optional)
-- - filename: the manuscript source file (optional, not used if src is given)
-- - src: the contents of the file (optional)
-- - cache: a FileCache object (optional, typically retrived from parent)
-- Note also that arg.format is used by ManuscriptFactory
function Manuscript:__init(args)
   local parent, filename, src
      = args.parent, args.filename, args.src
   self.filename = filename
   self.parent = parent
   self.root = self.parent and self.parent.root or self
   self.cache = args.cache or parent and parent.cache or FileCache()
   self.src = src or self.cache:get(filename) or ""
   self.depth = 1 + (parent and parent.depth or 0)
   self.modules, self.commands, self.environments = {}, {}, {}
   if parent then
      setmetatable(self.modules,      {__index = parent.modules}     )
      setmetatable(self.commands,     {__index = parent.commands}    )
      setmetatable(self.environments, {__index = parent.environments})
   end
   self:add_module(self.format)
   self:global_scan()
end

--- Get a substring of the manuscript.
-- @param i the intial position, or a table range table (with fields
-- `pos` and `len`).
-- @param j the final position (ignored if i is a table)
function Manuscript:substring(i, j)
   if not i then return nil end
   if type(i) == "table" then
      j = i.len and (i.pos + i.len - 1)
      i = i.pos
   end
   return self.src:sub(i,j)
end

--- Get a substring of the manuscript, with surrounding white space
--- and comments removed.
function Manuscript:substring_trimmed(i, j)
   return self.parser:trim(self:substring(i,j))
end

--- Get a substring of the manuscript, with surrounding white space
--- and interspersed comments removed.
function Manuscript:substring_stripped(i, j)
   return self.parser:trim(self.parser:strip_comments(self:substring(i,j)))
end

--- Returns a list of ranges, with nested ranges `key` and, if
--- present, `value`.
function Manuscript:parse_keys(range)
   return self.parser:parse_keys(self.src, range.pos, range.len)
end

--- Returns a nested list of key/value tables
function Manuscript:read_keys(range)
   local tbl = self:parse_keys(range)
   local r = {}
   for i, v in ipairs(tbl) do
      r[i] = {
         key = self:substring_trimmed(v.key),
         value = v.value and self:substring_trimmed(v.value)
      }
   end
   return r
end

--- Returns a list of strings.
function Manuscript:read_list(range)
   return util.map(function (x) return x.key end,
      self:read_keys(range))
end

--- Parse the arguments of a macro.
-- Returns nil if pos does not point to a control sequence, or the
-- macro is unknown.
-- @number pos
-- @tresult tab
function Manuscript:parse_cs_args(pos, cs)
   local cmd = self.commands[cs]
   if cmd and cmd.args then
      pos = 1 + pos + string.len(cs)
      return self.parser:parse_args(self.src, pos, cmd.args)
   else
      return {pos = pos, len = string.len(cs or "")}
   end
end

function Manuscript:parse_env_args(pos, cs)
   local r = self:parse_cs_args(pos, cs)
   local env = self.environments[self:substring(r[1])]
   if env and env.args then
      local pos = 1 + r.pos + r.len
      return r, self.parser:parse_args(self.src, pos, env.args)
   else
      return {pos = r.pos, len = r.len}
   end
end

--- Find paragraph before a position.
-- @param pos a position in the source
-- @return the paragraph's starting position
function Manuscript:find_par(pos)
   local i, j = 1, 1
   local patt, src = self.parser.patt.next_par, self.src
   while i == j do
      j = patt:match(src, i)
      if j and j <= pos then i = j end
   end
   return i
end

--- Test if position is blank.
-- @number pos a position in the source
-- @treturn boolean
function Manuscript:is_blank(pos)
   return self.parser:blank(self.src, pos)
end

--- Scan the Manuscript, executing callbacks for each document element.
-- Each callback is a function taking at least two arguments (a
-- Manuscript object and a source position) and returns at least one
-- value, a position to continue scanning or nil to interrupt the
-- process.  When this happens, scan function returns the remaining
-- return values of the callback.  The remaining arguments and return
-- values of a callback can be used to keep track of an internal
-- state.
--
-- Indices of the callback table can be either the "action" field of a
-- command, or a "type" field of a thing ("cs", "mathshift" or "par").
--
-- @tab callbacks a table of callback functions
-- @number pos the starting position
function Manuscript:scan(callbacks, pos, ...)
   if not pos then return ... end
   local pos1, kind, detail, pos2 = self.parser.patt.next_thing3:match(self.src, pos)
   if not pos then return ... end

   local cmd = kind == "cs" and self.commands[detail]
   local callback = cmd and callbacks[cmd.action] or callbacks[kind]

   if callback then
      return self:scan(callbacks, callback(self, pos1, detail, ...))
   else
      return self:scan(callbacks, pos2, ...)
   end
end

-- function Manuscript:scan(callbacks, pos, ...) -- with while loop instead of tail calls
--    local patt = self.parser.patt.next_thing3
--    local match = patt.match
--    local src, commands = self.src, self.commands
--    local v1, v2, v3
--    while pos do -- note: this is never false (?)
--       local pos1, kind, detail, pos2 = match(patt, src, pos)
--       if not pos1 then
--          return v1, v2, v3
--       end
--       local cmd = kind == "cs" and commands[detail]
--       local callback = cmd and callbacks[cmd.action] or callbacks[kind]
--       if callback then
--          pos, v1, v2, v3 = callback(self, pos1, detail, v1, v2, v3)
--       else
--          pos = pos2
--       end
--    end
--    return v1, v2, v3 --this never happens
-- end

--- Global scanning

function Manuscript:add_module(name)
   local m = data(name)
   if (not m) or self.modules[name] then return end
   self.modules[name] = m
   for _, n in ipairs(m.dependencies or {}) do
      self:add_module(n)
   end
   if m.commands then util.update(self.commands, m.commands) end
   if m.environments then util.update(self.environments, m.environments) end
end

function Manuscript:add_children(filename)
   if self.depth > 15 then return end
   filename = path_join(path_split(self.filename), filename)
   self.children[filename] = true
end

function Manuscript:find_manuscript(filename)
   if self.filename == filename then return self end
   for _, m in pairs(self.children) do
      local c = m:find_manuscript(filename)
      if c then return c end
   end
   return nil
end

function Manuscript:add_outline(e, tree)
   tree = tree or self.outline
   local last = tree[#tree]
   if last == nil or last.level >= e.level then
      tree[#tree + 1] = e
   else
      self:add_outline(e, last.children)
   end
end

---
-- Scan the whole document, initializing the macro and label list,
-- outline, etc.

Manuscript.global_callbacks = {}

function Manuscript:global_scan()
   self.children, self.bibitems, self.labels, self.outline
      = {}, {}, {}, {}
   self.input_index, self.label_index, self.section_index = {}, {}, {} --experiment
   self:scan(self.global_callbacks, 1)
   for _, input in ipairs(self.input_index) do
       self.children[input.name] = Manuscript{
         filename = input.name,
         parent = self
      }
   end
end

--- Local scanning

Manuscript.local_callbacks = {}

---
-- Scan the current paragraph, returning the context.  This is a list
-- of nested annotated ranges, starting from the innermost.
-- @param pos a source position
-- @return a nested list of annotated ranges
function Manuscript:local_scan(pos)
   return self:scan(self.local_callbacks, self:find_par(pos), nil, pos)
end

local function local_scan_parse_keys(m, context, pos)
   local keys = m:parse_keys(context)
   for _, k in ipairs(keys) do -- are we inside a key/list item?
      if k.pos and k.pos <= pos and pos <= k.pos + k.len then
         local key = m:substring_trimmed(k.key)
         context = {
            key = key,
            data = util.nested_get(context.data.keys, key), -- or fetch context-dependent keys, say on a usepackage
            pos = k.pos,
            len = k.len,
            parent = context
         }
         local v = k.value
         if v and v.pos and v.pos <= pos and pos <= v.pos + v.len then -- are we inside the value of a key?
            local value = m:substring_trimmed(v)
            context = {
               value = value,
               data = util.nested_get(context.data.values, value), -- what if "value" is command-like?
               pos = v.pos,
               len = v.len,
               parent = context
            }
         end
         break
      end
   end
   return context
end

local local_callbacks = Manuscript.local_callbacks

function local_callbacks.cs(m, pos, cs, context, end_pos)
   if pos > end_pos then return nil, context end -- stop parse
   local r = m:parse_cs_args(pos, cs)
   if end_pos <= r.pos + r.len then
      context = {
         cs = cs,
         data = m.commands[cs],
         pos = pos,
         len = r.pos + r.len - pos,
         parent = context
      }
   elseif cs == "begin" then
      local env_name = m:substring(r[1])
      local env = m.environments[env_name] or {}
      local q = m.parser:parse_args(m.src, r.pos + r.len, env.args or {})
      if q.pos + q.len < end_pos then
         return q.pos + q.len, context, end_pos -- end_pos is after current thing
      end
      context = {
         env = env_name,
         data = m.environments[env_name],
         pos = pos,
         len = r.pos + r.len - pos,
         parent = context
      }
      r = q
   else -- pos is after current thing
      return r.pos + r.len, context, end_pos
   end

   for i, arg in ipairs(r) do -- are we inside an argument?
      if arg.pos and arg.pos <= end_pos and end_pos <= arg.pos + arg.len then
         context = {
            arg = i,
            data = util.nested_get(context.data, "args", i),
            pos = arg.pos,
            len = arg.len,
            parent = context
         }
         if context.data and context.data.keys then
            context = local_scan_parse_keys(m, context, end_pos)
         end
         return context.pos, context, end_pos
      end
   end
   return nil, context -- stop parse
end

function local_callbacks.tikzpath(m, pos, cs, context, end_pos)
   if pos > end_pos then return nil, context end -- stop parse
   local r = m:parse_cs_args(pos, cs)
   if end_pos <= r.pos + r.len then
      context = {
         cs = cs,
         data = m.commands[cs],
         pos = pos,
         len = r.pos + r.len - pos,
         parent = context
      }
      local p = r[1].pos
      local args = {{delims={"","["}}, {delims={"","]"}}}
      while p <= end_pos do
         local q = m.parser:parse_args(m.src, p, args)
         if q and q[2].pos <= end_pos and end_pos <= q[2].pos + q[2].len then
            context = {
               arg = true,
               data = {keys = data"tikz-extracted".keys},
               pos = q[2].pos,
               len = q[2].len,
               parent = context
            }
            context = local_scan_parse_keys(m, context, end_pos)
         end
         p = q and q.pos + q.len or math.huge
      end
   end
   return r.pos + r.len, context, end_pos
end

function local_callbacks.par (_, _, _, context)
   return nil, context
end

-- recursively iterate over each (numeric index of) self.name and its
-- children
function Manuscript:each_of(name)
   local stack = {}
   local script = self
   local items, inputs = script[name], script.input_index
   local i, j = 1, 1
   local function f()
      local item, input = items[i], inputs[j]
      if item and not (input and item.pos > input.pos) then
         i = i + 1
         return item
      elseif input then
         stack[#stack+1] = {i, j + 1, script, items, inputs}
         script = script.children[input.name]
         items = script and script[name] or {}
         inputs = script and script.inputs or {}
         i, j = 1, 1
         return f()
      elseif #stack > 0 then
         i, j, script, items, inputs = table.unpack(stack[#stack])
         stack[#stack] = nil
         return f()
      else
         return nil
      end
   end
   return f
end

--- Resolution

function Manuscript:get_resolution()
   local resol = {}
   local child_resol = util.map(Manuscript.get_resolution, self.children)
   for _, field in ipairs{"labels", "commands", "environments", "bibitems"} do
      local f = function(r) return r[field] end
      resol[field] = util.update({}, self[field], table.unpack(util.map(f, child_resol)))
   end
   return resol
end
--- Return a copy of the Manuscript, with all dependencies resolved
--- explicitly
-- function Manuscript:resolved()
--    local copy = util.update({}, self)
--    setmetatable(copy, getmetatable(self))
--    return util.update(copy, copy:get_resolution())
-- end

-- function Manuscript:refresh()
--    local cached = self.cache:get(self.filename) or ""
--    if cached ~= self.src then
--       -- rewrite the constructor so that this is the same as self = Manuscript(self)
--       self.src = cached
--       self:global_scan()
--    else
--       for _, m in ipairs(self.children) do
--          m:refresh()
--       end
--    end
-- end

-- version that returns true if something changed
function Manuscript:refresh()
   local cached = self.cache:get(self.filename) or ""
   if cached == self.src then
      local v = false
      for _, m in pairs(self.children) do
         v = m:refresh() or v
      end
      return v
   else
      -- rewrite the constructor so that this is the same as self = Manuscript(self)
      self.src = cached
      self:global_scan()
      return true
   end
end

return Manuscript
