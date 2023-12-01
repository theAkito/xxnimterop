import strformat

from os import parentDir, getCurrentCompilerExe, DirSep

when defined(nimdoc):
  from os import getCurrentDir, paramCount, paramStr

proc getNimRootDir(): string =
  #[
  hack, but works
  alternatively (but more complex), use (from a nim file, not nims otherwise
  you get Error: ambiguous call; both system.fileExists):
  import "$nim/testament/lib/stdtest/specialpaths.nim"
  nimRootDir
  ]#
  fmt"{currentSourcePath}".parentDir.parentDir.parentDir

const
  DirSep = when defined(Windows): '\\' else: '/'

proc execAction(cmd: string): string =
  var
    ccmd = ""
    ret = 0
  when defined(Windows):
    ccmd = "cmd /c " & cmd
  elif defined(posix):
    ccmd = cmd
  else:
    doAssert false

  (result, ret) = gorgeEx(ccmd)
  doAssert ret == 0, "Command failed: " & $ret & "\ncmd: " & ccmd & "\nresult:\n" & result

proc buildDocs*(files: openArray[string], path: string, baseDir = getCurrentDir() & $DirSep,
                defines: openArray[string] = @[], nimArgs = "") =
  ## Generate docs for all specified nim `files` to the specified `path`
  ##
  ## `baseDir` is the project path by default and `files` and `path` are relative
  ## to that directory. Set to "" if using absolute paths.
  ##
  ## `defines` is a list of `-d:xxx` define flags (the `xxx` part) that should be passed
  ## to `nim doc` so that `getHeader()` is invoked correctly.
  ##
  ## `nimArgs` is a string representing extra arguments to send to the `nim doc` call.
  ##
  ## Use the `--publish` flag with nimble to publish docs contained in
  ## `path` to Github in the `gh-pages` branch. This requires the ghp-import
  ## package for Python: `pip install ghp-import`
  ##
  ## WARNING: `--publish` will destroy any existing content in this branch.
  ##
  ## NOTE: `buildDocs()` only works correctly on Windows with Nim 1.0+ since
  ## https://github.com/nim-lang/Nim/pull/11814 is required.
  when defined(Windows) and (NimMajor, NimMinor, NimPatch) < (1, 0, 0):
    echo "buildDocs() unsupported on Windows for Nim < 1.0 - requires PR #11814"
  else:
    let
      baseDir =
        if baseDir == $DirSep:
          getCurrentDir() & $DirSep
        else:
          baseDir
      path = baseDir & path
      defStr = block:
        var defStr = ""
        for def in defines:
          defStr &= " -d:" & def
        defStr
      nim = getCurrentCompilerExe()
    for file in files:
      echo execAction(&"{nim} doc {defStr} {nimArgs} -o:{path} --project --index:on {baseDir & file}")

    echo execAction(&"{nim} buildIndex {nimArgs} -o:{path}/theindex.html {path}")
    when declared(getNimRootDir):
      #[
      this enables doc search, works at least locally with:
      cd {path} && python -m SimpleHTTPServer 9009
      ]#
      echo execAction(&"{nim} js {nimArgs} -o:{path}/dochack.js {getNimRootDir()}/tools/dochack/dochack.nim")

    for i in 0 .. paramCount():
      if paramStr(i) == "--publish":
        echo execAction(&"cd {path} && ghp-import --no-jekyll -fp {path}")
        break