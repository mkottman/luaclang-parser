luaclang
=========

A Lua binding to the [`libclang`](http://clang.llvm.org/doxygen/group__CINDEX.html) library, which allows you to parse C and C++ code using the Clang compiler.

`luaclang` provides an object-oriented interface over the `libclang` API. As of right now, a meaningful subset of `libclang` API is available, allowing you to write C/C++ header parsers, file diagnostics (warnings, errors) and code completion.

No more error-prone hand-written header/documentation parsers, yay! :)

Requirements
============

* Lua 5.1
* LLVM/Clang - read the [getting started](http://clang.llvm.org/get_started.html) guide to find out how to obtain Clang from source. `libclang` is built and installed along with Clang compiler.

Overview
========

`libclang` provides a cursor-based API to the abstract syntax tree (AST) of the C/C++ source files. This means that you can see what the compiler sees. These are the main classes used in `libclang`/`luaclang`:

* `Index` - represents a set of translation units that could be linked together
* `TranslationUnit` - represents a source file
* `Cursor` - represents an element in the AST in a translation unit
* `Type` - the type of an element (variable, field, parameter, return type)

Examples
========

A simple code browser demonstrating the abilities of `luaclang` is provided in `cindex.lua`. It takes command line arguments as the Clang compiler would and passes them to `TranslationUnit:parse(args)` (see below). Then it processes the headers and gathers information about classes, methods, functions and their argument, and saves this information into a SQLite3 database `code.db` with the following schema:

	CREATE TABLE args (ismethod, parent, name, idx, type, const, defval);
	CREATE TABLE classes (module, name, parent);
	CREATE TABLE functions (module, name, result, signature);
	CREATE TABLE methods (class, name, kind, access, result, signature, static, virtual, signal, slot);

References between arguments, functions/methods and classes are done through the [SQLite row identifier](http://www.sqlite.org/lang_createtable.html#rowid). For example to construct the database for `libclang`, run the following command:

	lua cindex.lua /usr/local/include/clang-c/Index.h

You can then query the functions using SQL, for example to gather all functions which take `CXCursor` as the first argument:

    SELECT *
    FROM functions F
    JOIN args A ON A.parent = F.rowid
    WHERE A.idx = 1 AND A.type = 'CXCursor'

A sample file `allqt.cpp` which takes in most Qt headers is available. Using the `qt4-qobjectdefs-injected.h` include file, annotations for signals and slots are injected into QObject, which is recognized by `cindex.lua` and it is able to mark methods as either signals or slots. For example to find all classes and their signals, run:

	SELECT C.name, M.signature
	FROM classes C
	JOIN methods M ON M.class = C.rowid
	WHERE M.signal = 1

Just for a taste on how big the Qt framework is:

	sqlite> SELECT COUNT(*) FROM classes;
	1302
	sqlite> SELECT COUNT(*) FROM methods;
	19612

Reference
=========

`luaclang`
----------

Use `local luaclang = require "luaclang"` to load the module. It exports one function:

* `createIndex(excludePch : boolean, showDiagnostics : boolean) -> Index`

    Binding for [clang_createIndex](http://clang.llvm.org/doxygen/group__CINDEX.html#func-members). Will create an `Index` into which you can parse or load pre-compiled `TranslationUnit`s.

`Index`
-------

* `Index:parse([sourceFile : string,] args : table) -> TranslationUnit`

    Binding for [clang_parseTranslationUnit](http://clang.llvm.org/doxygen/group__CINDEX__TRANSLATION__UNIT.html#ga2baf83f8c3299788234c8bce55e4472e). This will parse a given source file `sourceFile` with the command line arguments `args`, which would be given to the compiler for compilation, i.e. include paths, defines. If only the `args` table is given, the source file is expected to be included in `args`.

* `Index:load(astFile : string) -> TranslationUnit`

    Binding for [clang_createTranslationUnit](http://clang.llvm.org/doxygen/group__CINDEX__TRANSLATION__UNIT.html#gaa2e74f6e28c438692fd4f5e3d3abda97). This will load the translation unit from an AST file which was constructed using `clang -emit-ast`. Useful when repeatedly processing large sets of files (like frameworks).

`TranslationUnit`
-----------------

* `TranslationUnit:cursor() -> Cursor`

    Binding for [clang_getTranslationUnitCursor](http://clang.llvm.org/doxygen/group__CINDEX__CURSOR__MANIP.html#gaec6e69127920785e74e4a517423f4391). Returns the `Cursor` representing a given translation unit, which means you can access to classes and functions defined in a given file.

* `TranslationUnit:file(fileName : string) -> string, number`

    Binding for [clang_getFile](http://clang.llvm.org/doxygen/group__CINDEX__FILES.html#gaa0554e2ea48ecd217a29314d3cbd2085). Returns the absolute file path and a `time_t` last modification time of `fileName`.

* `TranslationUnit:diagnostics() -> { Diagnostic* }`

    Binding for [clang_getDiagnostic](http://clang.llvm.org/doxygen/group__CINDEX__DIAG.html#ga3f54a79e820c2ac9388611e98029afe5). Returns a table array of `Diagnostic`, which represent warnings and errors. Each diagnostic is a table consisting of these keys: `text` - the diagnostic message, `category` - a diagnostic category.

* `TranslationUnit:codeCompleteAt(file : string, line : number, column : number) -> { Completion* }, { Diagnostics* }`

    Binding for [code completion API](http://clang.llvm.org/doxygen/group__CINDEX__CODE__COMPLET.html). Returns the available code completion options at a given location using prior content. Each `Completion` is a table consisting of several chunks, each of which has a text and a [chunk kind](http://clang.llvm.org/doxygen/group__CINDEX__CODE__COMPLET.html#ga82570056548565efdd6fc74e57e75bbd) without the `CXCompletionChunk_` prefix. If there are any annotations, the `annotations` key is a table of strings:

        completion = {
             priority = number, priority of given completion
             chunks = {
                 kind = string, chunk kind
                 text = string, chunk text
             },
             [annotations = { string* }]
        }


`Cursor`
--------

* `Cursor:children() -> { Cursor * }`

    Binding over [clang_visitChildren](http://clang.llvm.org/doxygen/group__CINDEX__CURSOR__TRAVERSAL.html#ga5d0a813d937e1a7dcc35f206ad1f7a91). This is the main function for AST traversal. Traverses the direct descendats of a given cursor and collects them in a table. If no child cursors are found, returns an empty table.

* `Cursor:name() -> string`

    Binding over [clang_getCursorSpelling](http://clang.llvm.org/doxygen/group__CINDEX__CURSOR__XREF.html#gaad1c9b2a1c5ef96cebdbc62f1671c763). Returns the name of the entity referenced by cursor. `__tostring` for `Cursor` also points to this function.

* `Cursor:displayName() -> string`

    Binding over [clang_getCursorDisplayName](http://clang.llvm.org/doxygen/group__CINDEX__CURSOR__XREF.html#gac3eba3224d109a956f9ef96fd4fe5c83). Returns the display name of the entity, which for example is a function signature.	

* `Cursor:kind() -> string`

	Returns the [cursor kind](http://clang.llvm.org/doxygen/group__CINDEX.html#gaaccc432245b4cd9f2d470913f9ef0013) without the `CXCursor_` prefix, i.e. `"FunctionDecl"`.

* `Cursor:arguments() -> { Cursor* }`

	Binding of [clang_Cursor_getArgument](http://clang.llvm.org/doxygen/group__CINDEX__TYPES.html#ga673c5529d33eedd0b78aca5ac6fc1d7c). Returns a table array of `Cursor`s representing arguments of a function or a method. Returns an empty table if a cursor is not a method or function.

* `Cursor:resultType() -> Type`

	Binding for [clang_getCursorResultType](http://clang.llvm.org/doxygen/group__CINDEX__TYPES.html#ga6995a2d6352e7136868574b299005a63). For a function or a method cursor, returns the return type of the function.

* `Cursor:type() -> Type`

	Returns the `Type` of a given element or `nil` if not available.

* `Cursor:access() -> string`

	When cursor kind is `"AccessSpecifier"`, returns one of `"private"`, `"protected"` and `"public"`.

* `Cursor:location() -> string, number, number, number, number`

	Binding for [clang_getCursorExtent](http://clang.llvm.org/doxygen/group__CINDEX__CURSOR__SOURCE.html#ga79f6544534ab73c78a8494c4c0bc2840). Returns the file name, starting line, starting column, ending line and ending column of the given cursor. This can be used to look up the text a cursor consists of.

* `Cursor:referenced() -> Cursor`

	Binding for [clang_getCursorReferenced](http://clang.llvm.org/doxygen/group__CINDEX__CURSOR__XREF.html#gabf059155921552e19fc2abed5b4ff73a). For a reference type, returns a cursor to the element it references, otherwise returns `nil`.

* `Cursor:definition() -> Cursor`

	Binding for [clang_getCursorDefinition](http://clang.llvm.org/doxygen/group__CINDEX__CURSOR__XREF.html#gafcfbec461e561bf13f1e8540bbbd655b). For a reference or declaration, returns a cursor to the definition of the entity, otherwise returns `nil`.

* `Cursor:isVirtual() -> boolean`

	For a C++ method, returns whether the method is virtual.

* `Cursor:isStatic() -> boolean`

	For a C++ method, returns whether the method is static.

`Type`
------

* `Type:name() -> string`

	Binding of [clang_getTypeKindSpelling](http://clang.llvm.org/doxygen/group__CINDEX__TYPES.html#ga6bd7b366d998fc67f4178236398d0666). Returns one of [CXTypeKind](http://clang.llvm.org/doxygen/group__CINDEX__TYPES.html#gaad39de597b13a18882c21860f92b095a) as a string without the `CXType_` prefix. Type also has `__tostring` set to this method.

* `Type:canonical() -> Type`

	Binding of [clang_getCanonicalType](http://clang.llvm.org/doxygen/group__CINDEX__TYPES.html#gaa9815d77adc6823c58be0a0e32010f8c). Returns underlying type with all typedefs removed.

* `Type:pointee() -> Type`

	Binding of [clang_getPointeeType](http://clang.llvm.org/doxygen/group__CINDEX__TYPES.html#gaafa3eb34932d8da1358d50ed949ff3ee). For pointer type returns the type of the pointee.

* `Type:isPod() -> boolean`

	Binding of [clang_isPODType](http://clang.llvm.org/doxygen/group__CINDEX__TYPES.html#ga3e7fdbe3d246ed03298bd074c5b3703e)Returns true if the type is a "Plain Old Data" type.

* `Type:isConst() -> boolean`

	Binding of [clang_isConstQualifiedType](http://clang.llvm.org/doxygen/group__CINDEX__TYPES.html#ga8c3f8029254d5862bcd595d6c8778e5b). Returns true if the type has a "const" qualifier.

* `Type:declaration() -> Cursor`

	Binding of [clang_getTypeDeclaration](http://clang.llvm.org/doxygen/group__CINDEX__TYPES.html#ga0aad74ea93a2f5dea58fd6fc0db8aad4). Returns a `Cursor` to the declaration of a given type, or `nil`.


License
=======

Copyright (c) 2012 Michal Kottman

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.