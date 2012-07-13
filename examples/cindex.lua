package.cpath = package.cpath .. ';../build/?.so'

local clang = require 'luaclang-parser'
local sqlite3 = require 'luasql.sqlite3'.sqlite3

-- from http://stevedonovan.github.com/Penlight/api/modules/pl.text.html#format_operator
do
    local format = string.format

    -- a more forgiving version of string.format, which applies
    -- tostring() to any value with a %s format.
    local function formatx (fmt,...)
        local args = {...}
        local i = 1
        for p in fmt:gmatch('%%.') do
            if p == '%s' and type(args[i]) ~= 'string' then
                args[i] = tostring(args[i])
            end
            i = i + 1
        end
        return format(fmt,unpack(args))
    end

    -- Note this goes further than the original, and will allow these cases:
    -- 1. a single value
    -- 2. a list of values
    getmetatable("").__mod = function(a, b)
        if b == nil then
            return a
        elseif type(b) == "table" then
            return formatx(a,unpack(b))
        else
            return formatx(a,b)
        end
    end
end

do
    local start = os.clock()
    local lastTime = start
    function SECTION(...)
        local now = os.clock()
        print(("[%6.3f/%6.3f]"):format(now-start, now-lastTime), ...)
        lastTime = now
    end
end

SECTION "Start"

---[[
local DBG = function() end
--[=[]]
local DBG = print
--]=]

do
    local cache = setmetatable({}, {__mode="k"})
    function getExtent(file, fromRow, fromCol, toRow, toCol)
        if not file then
            DBG(file, fromRow, fromCol, toRow, toCol)
            return ''
        end
        if toRow - fromRow > 3 then
            return ('%s: %d:%d - %d:%d'):format(file, fromRow, fromCol, toRow, toCol)
        end
        if not cache[file] then
            local f = assert(io.open(file))
            local t, n = {}, 0
            for l in f:lines() do
                n = n + 1
                t[n] = l
            end
            cache[file] = t
        end
        local lines = cache[file]
        if not (lines and lines[fromRow] and lines[toRow]) then
            DBG('!!! Missing lines '..fromRow..'-'..toRow..' in file '..file)
            return ''
        end
        if fromRow == toRow then
            return lines[fromRow]:sub(fromCol, toCol-1)
        else
            local res = {}
            for i=fromRow, toRow do
                if i==fromRow then
                    res[#res+1] = lines[i]:sub(fromCol)
                elseif i==toRow then
                    res[#res+1] = lines[i]:sub(1,toCol-1)
                else
                    res[#res+1] = lines[i]
                end
            end
            return table.concat(res, '\n')
        end
    end
end

function findChildrenByType(cursor, type)
    local children, n = {}, 0
    local function finder(cur)
        for i,c in ipairs(cur:children()) do
            if c and (c:kind() == type) then
                n = n + 1
                children[n] = c
            end
            finder(c)
        end
   end
   finder(cursor)
   return children
end

function translateType(cur, typ)
    if not typ then
        typ = cur:type()
    end

    local typeKind = tostring(typ)
    if typeKind == 'Typedef' or typeKind == 'Record' then
        return typ:declaration():name()
    elseif typeKind == 'Pointer' then
        return translateType(cur, typ:pointee()) .. '*'
    elseif typeKind == 'LValueReference' then
        return translateType(cur, typ:pointee()) .. '&'
    elseif typeKind == 'Unexposed' then
        local def = getExtent(cur:location())
        DBG('!Unexposed!', def)
        return def
    else
        return typeKind
    end
end



SECTION 'Creating index'
local index = clang.createIndex(false, true)

SECTION 'Creating translation unit'
---[[
 local tu = assert(index:parse(arg))
--[=[]]
 local tu = assert(index:load('precompiled.ast'))
--]=]

SECTION "Writing code.xml - raw AST"

local function trim(s)
 local from = s:match"^%s*()"
 local res = from > #s and "" or s:match(".*%S", from)
 return (res:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;'))
end

local xml = assert(io.open('code.xml', 'w'))
local function dumpXML(cur)
    local tag = cur:kind()
    local name = trim(cur:name())
    local attr = ' name="' .. name .. '"'
    local dname = trim(cur:displayName())
    if dname ~= name then
        attr = attr .. ' display="' .. dname .. '"'
    end
    attr = attr ..' text="' .. trim(getExtent(cur:location())) .. '"' 
    local children = cur:children()
    if #children == 0 then
        xml:write('<', tag, attr, ' />\n')
    else
        xml:write('<', tag, attr, ' >\n')
        for _,c in ipairs(children) do
            dumpXML(c)
        end
        xml:write('</',tag,'>\n')
    end
end
dumpXML(tu:cursor())

SECTION "Finished"

local default_table_meta = {}
function new_default_table(t)
    return setmetatable(t or {}, default_table_meta)
end
function default_table_meta.__index(t,k)
    local v = {}
    rawset(t, k, v)
    return v
end

local DB = new_default_table()

function dumpChildren(cur, indent)
    indent = indent or '\t\t@'
    local children = cur:children()
    for i,c in ipairs(children) do
        DBG(indent, i..'/'..#children, c:kind(), c:name(), getExtent(c:location()))
        dumpChildren(c, indent..'\t')
    end
end

function processArgument(idx, arg)
    local name = arg:name()
    local type = translateType(arg, arg:type())
    
    local children = arg:children()

    local const, default

    if tostring(type) == 'LValueReference' then
        const = type:pointee():isConst()
    end

    if #children > 0 then
        if #children == 1 and children[1]:kind() ~= 'TypeRef' then
            default = getExtent(children[1]:location())
        else
            local newtype = {}
            for i,c in ipairs(children) do
                local kind = c:kind()
                if kind == 'NamespaceRef' or kind == 'TypeRef' then
                    newtype[#newtype+1] = c:referenced():name()
                elseif kind == 'DeclRef' then
                    default = getExtent(c:location())
                end
            end
            if #newtype > 0 then type = table.concat(newtype, '::') end
        end
    end

    DBG('', '', idx, name, type)

    return {
        name = name,
        type = type,
        const = const,
        default = default,
    }
end

function processMethod(method, kind, access)
    DBG('', '=>', access, kind, method:displayName(), getExtent(method:location()))

    -- process argument
    local argTable = {}
    local args = method:arguments()
    for i, arg in ipairs(args) do
        argTable[i] = processArgument(i, arg)
    end

    -- check for signal / slot, courtesy of qt4-qobjectdefs-injected.h
    local signal, slot
    for _, child in ipairs(method:children()) do
        if child:kind() == 'AnnotateAttr' then
            local name = child:name()
            if name == 'qt_signal' then
                signal = true
            elseif name == 'qt_slot' then
                slot = true
            end
        end
    end

    -- get return type
    local result
    if kind == 'CXXMethod' then
        result = translateType(method, method:resultType())
    end

    -- virtual / static
    local virtual, static
    if method:isVirtual() then
        virtual = true
    elseif method:isStatic() then
        static = true
    end

    return {
        name = method:name(),
        access = access,
        signature = method:displayName(),
        kind = kind,
        args = argTable,
        result = result,
        signal = signal,
        slot = slot,
        virtual = virtual,
        static = static
    }
end

SECTION "Processing classes"

local classes = findChildrenByType(tu:cursor(), 'ClassDecl')
for _, class in ipairs(classes) do
    local name = class:name()
    local dname = class:displayName()

    if name ~= dname then
        DBG(name, '->', dname)
    else
        DBG(name)
    end

    local DBClass = DB[class:displayName()]
    DBClass.methods = DBClass.methods or {}

    local children = class:children()
    local access = 'private'
    for _, method in ipairs(children) do
        local kind = method:kind()
        DBG('=>', kind)
        if kind == 'CXXMethod' then
            table.insert(DBClass.methods, processMethod(method, kind, access))
        elseif kind == 'Constructor' then
            table.insert(DBClass.methods, processMethod(method, kind, access))
            -- table.insert(DBClass.constructors, processMethod(method, kind, access))            
        elseif kind == 'Destructor' then
            table.insert(DBClass.methods, processMethod(method, kind, access))
            -- table.insert(DBClass.destructors, processMethod(method, kind, access))
        elseif kind == 'CXXAccessSpecifier' then
            access = method:access()
        elseif kind == 'EnumDecl' then
            DBG('', 'enum', method:displayName())
            for _,enum in ipairs(method:children()) do
                DBG('', '->', enum:name())
            end
        elseif kind == 'VarDecl' or kind == 'FieldDecl' then
            DBG(name, access, kind, method:name(), translateType(method))
        elseif kind == 'UnexposedDecl' then
            DBG('!!!', name, getExtent(method:location()))
        elseif kind == 'CXXBaseSpecifier' then
            local parent = method:referenced()
            DBClass.parent = parent:name()
        else
            DBG('???', name, kind, getExtent(method:location()))
        end
    end
end

SECTION "Processing functions"

function processFunction(func)
    DBG('=>', func:displayName(), getExtent(func:location()))

    -- process argument
    local argTable = {}
    local args = func:arguments()
    for i, arg in ipairs(args) do
        argTable[i] = processArgument(i, arg)
    end

    local result = translateType(func, func:resultType())

    return {
        name = func:name(),
        signature = func:displayName(),
        args = argTable,
        result = result,
    }
end

local functions = findChildrenByType(tu:cursor(), "FunctionDecl")
local FUNC = {}
for _, func in ipairs(functions) do
    local name = func:name()
    local dname = func:displayName()
    if not FUNC[dname] then
        DBG(_, name, dname)
        for i,arg in ipairs(func:arguments()) do
            DBG('', i, arg:name(), translateType(arg, arg:type()))
            FUNC[dname] = processFunction(func)
        end
    end
end


SECTION "Saving results"

local env = sqlite3()
local db = env:connect('code.db')
local E = function(s)
    if type(s) == 'nil' or (type(s) == "string" and #s == 0) then
        return 'NULL'
    elseif type(s) == 'string' then
        return "'"..s:gsub("'", "''").."'"
    else
        print('???', s, type(s))
        return 'NULL'
    end
end
local B = function(b) return b and '1' or '0' end

for _,tab in ipairs{"modules", "classes", "methods", "functions", "args"} do
    assert(db:execute("DROP TABLE IF EXISTS %s" % tab))
end
assert(db:execute("CREATE TABLE modules (name PRIMARY KEY)"))
assert(db:execute("CREATE TABLE classes (module, name, parent)"))
assert(db:execute("CREATE TABLE methods (class, name, kind, access, result, signature, static, virtual, signal, slot)"))
assert(db:execute("CREATE TABLE functions (module, name, result, signature)"))
assert(db:execute("CREATE TABLE args (ismethod, parent, name, idx, type, const, defval)"))

db:execute("BEGIN")

assert(db:execute("INSERT INTO modules VALUES ('test')"));
local modId = db:getlastautoid()

for name, class in pairs(DB) do
    assert(db:execute("INSERT INTO classes VALUES (%d, %s, %s)" % {modId, E(name), E(class.parent)}))
    local cid = db:getlastautoid()

    for _, m in ipairs(class.methods) do
        assert(db:execute(
            "INSERT INTO methods VALUES (%d, %s, %s, %s, %s, %s, %s, %s, %s, %s)" % {
            cid, E(m.name), E(m.kind), E(m.access), E(m.result), E(m.signature),
            B(m.static), B(m.virtual), B(m.signal), B(m.slot)
        }))
        local mid = db:getlastautoid()
        for i, a in ipairs(m.args) do
            local cmd = "INSERT INTO args VALUES (1, %d, %s, %d, %s, %d, %s)" % {
                mid, E(a.name), i, E(a.type), B(a.const), E(a.default)
            }
            local ok, err = db:execute(cmd)
            if not ok then print(cmd) error(err) end
        end
    end
end


for _, f in pairs(FUNC) do
    assert(db:execute(
        "INSERT INTO functions VALUES (%d, %s, %s, %s)" % {
        modId, E(f.name), E(f.result), E(f.signature)
    }))
    local fid = db:getlastautoid()
    for i, a in ipairs(f.args) do
        local cmd = "INSERT INTO args VALUES (0, %d, %s, %d, %s, %d, %s)" % {
            fid, E(a.name), i, E(a.type), B(a.const), E(a.default)
        }
        local ok, err = db:execute(cmd)
        if not ok then print(cmd) error(err) end
    end
end


db:execute("COMMIT")
