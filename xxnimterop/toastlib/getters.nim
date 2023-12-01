import dynlib, macros, os, osproc, sequtils, sets, streams, strformat, strutils, tables, times

import regex

import ".."/[globals, plugin]
import ".."/build/[ccompiler, misc, nimconf, shell]

const gReserved = """
addr and as asm
bind block break
case cast concept const continue converter
defer discard distinct div do
elif else end enum except export
finally for from func
if import in include interface is isnot iterator
let
macro method mixin mod
nil not notin
of or out
proc ptr
raise ref return
shl shr static
template try tuple type
using
var
when while
xor
yield""".split(Whitespace).toHashSet()

# Types related

const
  # Enum macro read from file - written into wrapper when required
  gEnumMacroConst = staticRead(currentSourcePath.parentDir().parentDir() / "enumtype.nim")

var
  gEnumMacro* = gEnumMacroConst

  gTypeMap* = {
    # char
    "char": "cchar",
    "signed char": "cschar",
    "unsigned char": "uint8",

    # short
    "short": "cshort",
    "short int": "cshort",
    "signed short": "cshort",
    "signed short int": "cshort",
    "unsigned short": "cushort",
    "unsigned short int": "cushort",
    "uShort": "cushort",
    "u_short": "cushort",

    # int
    "int": "cint",
    "signed": "cint",
    "signed int": "cint",
    "ssize_t": "int",
    "unsigned": "cuint",
    "unsigned int": "cuint",
    "uInt": "cuint",
    "u_int": "cuint",
    "size_t": "uint",

    "int8_t": "int8",
    "int16_t": "int16",
    "int32_t": "int32",
    "int64_t": "int64",

    "intptr_t": "ptr int",

    "Int8": "int8",
    "Int16": "int16",
    "Int32": "int32",
    "Int64": "int64",

    "uint8_t": "uint8",
    "uint16_t": "uint16",
    "uint32_t": "uint32",
    "uint64_t": "uint64",

    "uintptr_t": "ptr uint",

    "Uint8": "uint8",
    "Uint16": "uint16",
    "Uint32": "uint32",
    "Uint64": "uint64",

    # long
    "long": "clong",
    "long int": "clong",
    "signed long": "clong",
    "signed long int": "clong",
    "off_t": "clong",
    "unsigned long": "culong",
    "unsigned long int": "culong",
    "uLong": "culong",
    "u_long": "culong",

    # long long
    "long long": "clonglong",
    "long long int": "clonglong",
    "signed long long": "clonglong",
    "signed long long int": "clonglong",
    "off64_t": "clonglong",
    "unsigned long long": "culonglong",
    "unsigned long long int": "culonglong",

    # floating point
    "float": "cfloat",
    "double": "cdouble",
    "long double": "clongdouble",

    # Misc Nim types
    "Bool": "bool",
    "ptrdiff_t": "ByteAddress"
  }.toTable()

  # Nim type names that shouldn't need to be wrapped again
  gTypeMapValues* = toSeq(gTypeMap.values).toHashSet()

  # Types to import from C/Nim if used in wrapper
  gTypeImport* = {
    "time_t": """
import std/time_t as std_time_t
type time_t* = std_time_t.Time
""",

    "time64_t": """
import std/time_t as std_time64_t
type time64_t* = std_time64_t.Time
""",

    "wchar_t": """
when defined(cpp):
  # http://www.cplusplus.com/reference/cwchar/wchar_t/
  # In C++, wchar_t is a distinct fundamental type (and thus it is
  # not defined in <cwchar> nor any other header).
  type wchar_t* {.importc.} = object
else:
  type wchar_t* {.importc, header:"stddef.h".} = object
""",

    "va_list": """
type va_list* {.importc, header:"<stdarg.h>".} = object
"""}.toTable()

proc getType*(gState: State, str, parent: string): string =
  if str == "void":
    return "object"

  result = str.strip(chars={'_'}).splitWhitespace().join(" ")

  if gTypeMap.hasKey(result):
    result = gTypeMap[result]
  elif parent.nBl and gTypeImport.hasKey(result) and not gState.identifierNodes.hasKey(result):
    # Include C/Nim type imports once if a field/param and not already declared
    gState.wrapperHeader &= "\n" & gTypeImport[result]
    gTypeImport.del result

# Identifier related

proc checkIdentifier(name, kind, parent, origName: string) =
  let
    parentStr = if parent.nBl: parent & ":" else: ""

  if name.nBl:
    let
      origStr = if name != origName: &", originally '{origName}' before 'cPlugin:onSymbol()'," else: ""
      errmsg = &"Identifier '{parentStr}{name}' ({kind}){origStr} $1 " &
        "which Nim does not allow. Use toast flag '$2' or 'cPlugin()' to modify."

    doAssert name[0] != '_' and name[^1] != '_', errmsg % ["has leading/trailing underscores '_'", "--prefix or --suffix"]

    doAssert (not name.contains("__")): errmsg % ["has consecutive underscores '_'", "--replace"]

    doAssert not name[0].isDigit(), errmsg % [&"starts with a digit '{name[0]}'", "--prefix"]

  # Cannot blank out symbols which are fields or params
  #
  # `IgnoreSkipSymbol` is used to `getIdentifier()` even if symbol is in `symOverride` list
  # so that any prefix/suffix/replace or `onSymbol()` processing can occur. This is only used
  # for `cOverride()` since it also depends on `symOverride`.
  if parent.nBl and parent != "IgnoreSkipSymbol":
    doAssert name.nBl, &"Blank identifier, originally '{parentStr}{origName}' ({kind}), cannot be empty"

proc getIdentifier*(gState: State, name: string, kind: NimSymKind, parent=""): string =
  doAssert name.nBl, "Blank identifier error"

  if name notin gState.symOverride or parent.nBl:
    if gState.onSymbol != nil:
      # Use onSymbol from plugin provided by user
      var
        sym = Symbol(name: name, parent: parent, kind: kind)
      gState.onSymbol(sym)

      result = sym.name
    else:
      result = name

      # Strip out --prefix from CLI if specified
      for str in gState.prefix:
        if result.startsWith(str):
          result = result[str.len .. ^1]

      # Strip out --suffix from CLI if specified
      for str in gState.suffix:
        if result.endsWith(str):
          result = result[0 .. ^(str.len+1)]

      # --replace from CLI if specified
      for name, value in gState.replace.pairs:
          if name.len > 1 and name[0] == '@':
            result = result.replace(re(name[1 .. ^1]), value)
          else:
            result = result.replace(name, value)

    checkIdentifier(result, $kind, parent, name)

    if result in gReserved or (result == "object" and kind != nskType):
      # Enclose in backticks since Nim reserved word
      result = &"`{result}`"
  else:
    # Skip identifier since in symOverride
    result = ""

proc getUniqueIdentifier*(gState: State, prefix = ""): string =
  var
    name = prefix & "_" & gState.sourceFile.extractFilename().multiReplace([(".", ""), ("-", "")])
    nimName = name[0] & name[1 .. ^1].replace("_", "").toLowerAscii
    count = 1

  while (nimName & $count) in gState.identifiers:
    count += 1

  return name & $count

proc addNewIdentifer*(gState: State, name: string, override = false): bool =
  if override or name notin gState.symOverride:
    let
      nimName = name[0] & name[1 .. ^1].replace("_", "").toLowerAscii

    if gState.identifiers.hasKey(nimName):
      doAssert name == gState.identifiers[nimName],
        &"Identifier '{name}' is a stylistic duplicate of identifier " &
        &"'{gState.identifiers[nimName]}', use 'cPlugin:onSymbol()' to rename"
      result = false
    else:
      gState.identifiers[nimName] = name
      result = true

# Overrides related

proc getOverride*(gState: State, name: string, kind: NimSymKind): string =
  # Get cOverride for identifier `name` of `kind` if defined
  doAssert name.nBl, "Blank identifier error"

  if gState.onSymbolOverride != nil:
    var
      nname = gState.getIdentifier(name, kind, "IgnoreSkipSymbol")
      sym = Symbol(name: nname, kind: kind)
    if nname.nBl:
      gState.onSymbolOverride(sym)

      if sym.override.nBl and gState.addNewIdentifer(nname, override = true):
        result = sym.override

        if kind != nskProc:
          result = "  " & result.replace("\n", "\n ")

proc getOverrideFinal*(gState: State, kind: NimSymKind): string =
  # Get all unused cOverride symbols of `kind`
  let
    typ = $kind

  if gState.onSymbolOverrideFinal != nil:
    for i in gState.onSymbolOverrideFinal(typ):
      result &= "\n" & gState.getOverride(i, kind)

proc getKeyword*(kind: NimSymKind): string =
  # Convert `kind` into a Nim keyword
  # cOverride procs already include `proc` keyword
  result = ($kind).replace("nsk", "").toLowerAscii()

proc getCurrentHeader*(fullpath: string): string =
  ("header" & fullpath.splitFile().name.multiReplace([(".", ""), ("-", "")]))

proc isIncluded(gState: State, file: string): bool {.inline.} =
  # Check if the specified file should be excluded from wrapped output
  if gState.exclude.nBl:
    for excl in gState.exclude:
      if file.startsWith(excl):
        return
  result = true

proc getPreprocessor*(gState: State, fullpath: string) =
  # Get preprocessed output from the C/C++ compiler
  var
    args: seq[string]
    start = false
    sfile = fullpath.sanitizePath(noQuote = true)

    sfileName = sfile.extractFilename()
    pDir = sfile.expandFilename().parentDir()
    includeDirs: seq[string]

  args.add @["-E", "-dD", getGccModeArg(gState.mode), "-w"]
  if not gState.noComments:
    args.add "-CC"

  for inc in gState.includeDirs:
    args.add &"-I{inc.sanitizePath}"
    includeDirs.add inc.absolutePath().sanitizePath(noQuote = true)

  for def in gState.defines:
    args.add &"-D{def}"

  # Remove gcc special calls
  # https://github.com/tree-sitter/tree-sitter-c/issues/43
  args.add @["-D__attribute__(x)=", "-D__restrict=", "-D__restrict__=", "-D__extension__=", "-D__inline__=inline",
    "-D__inline=inline", "-D_Noreturn=", &"{fullpath.sanitizePath}"]

  # Include content only from file
  var
    p = startProcess(getCompiler(), args = args, options = {poStdErrToStdOut, poUsePath})
    outp = p.outputStream()
    line = ""
    newHeaders: HashSet[string]

  # Include content only from file
  gState.code = ""
  while true:
    if outp.readLine(line):
      # We want to keep blank lines here for comment processing
      if line.len > 10 and line[0] == '#' and line[1] == ' ' and line.contains('"'):
        # # 1 "path/to/file.h" 1
        start = false
        line = line.split('"')[1].sanitizePath(noQuote = true)
        if sfile == line or
          (DirSep notin line and sfileName == line):
          start = true
        elif gState.recurse:
          if (pDir.Bl or pDir in line) and line notin gState.headersProcessed:
            newHeaders.incl line
            start = gState.isIncluded(line)
          else:
            for inc in includeDirs:
              if line.startsWith(inc) and line notin gState.headersProcessed:
                newHeaders.incl line
                start = gState.isIncluded(line)
                if start:
                  break
      elif ": fatal error:" in line:
        doAssert false,
          "\n\nFailed in preprocessing, check if `cIncludeDir()` is needed or compiler `mode` is correct (c/cpp)" &
          "\n\nERROR:$1\n" % line.split(": fatal error:")[1]
      else:
        if start:
          if "#undef" in line:
            continue
          gState.code.add line & "\n"
    elif not p.running(): break
  p.close()
  assert p.peekExitCode() == 0,
    gState.code & "\n\nFailed in preprocessing:\n  " &
    getCompiler() & " " & args.join(" ")
  gState.headersProcessed.incl newHeaders

# Plugin related

proc dll*(path: string): string =
  let
    (dir, name, _) = path.splitFile()

  result = dir / (DynlibFormat % name)

proc loadPlugin*(gState: State, sourcePath: string) =
  doAssert fileExists(sourcePath), "Plugin file does not exist: " & sourcePath

  let
    pdll = sourcePath.dll
  if not fileExists(pdll) or
    sourcePath.getLastModificationTime() > pdll.getLastModificationTime():
    let
      # Get Nim configuration flags if not already specified in a .cfg file
      flags =
        if fileExists(sourcePath & ".cfg"): ""
        else: getNimConfigFlags(getCurrentDir())

      # Always set output to same directory as source, prevents override
      outflags = &"--out:\"{pdll}\""

      # Compile plugin as library with `markAndSweep` GC
      cmd = &"{gState.nim} c --app:lib --skipParentCfg:on --gc:markAndSweep {flags} {outflags} {sourcePath.sanitizePath}"

      (output, ret) = execAction(cmd, die = false)
    doAssert ret == 0, output & "\nFailed to compile cPlugin()\n\ncmd: " & cmd
  doAssert fileExists(pdll), "No plugin binary generated for " & sourcePath

  let lib = loadLib(pdll)
  doAssert lib != nil, "Plugin $1 compiled to $2 failed to load" % [sourcePath, pdll]

  gState.onSymbol = cast[OnSymbol](lib.symAddr("onSymbol"))

  gState.onSymbolOverride = cast[OnSymbol](lib.symAddr("onSymbolOverride"))

  gState.onSymbolOverrideFinal = cast[OnSymbolOverrideFinal](lib.symAddr("onSymbolOverrideFinal"))

# Misc toast helpers

proc getSplitComma*(joined: seq[string]): seq[string] =
  for i in joined:
    result = result.concat(i.split(","))

proc expandSymlinkAbs*(path: string): string =
  try:
    result = path.expandFilename().normalizedPath()
  except:
    result = path
  result = result.sanitizePath(noQuote = true)
