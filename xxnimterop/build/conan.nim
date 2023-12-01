import json, os, strformat, strutils, tables


import ".."/globals
import "."/[ccompiler, misc, nimconf, shell]

when (NimMajor, NimMinor, NimPatch) < (1, 2, 0):
  import marshal

type
  ConanPackage* = ref object
    ## ConanPackage type that stores conan uri and recipes/builds/revisions
    name*: string
    version*: string
    user*: string
    channel*: string
    recipes*: OrderedTableRef[string, seq[ConanBuild]]

    arch*, os*, compiler*, compversion*: string

    bhash*: string
    shared*: bool
    sharedLibs*: seq[string]
    staticLibs*: seq[string]
    requires*: seq[ConanPackage]

    skipRequires*: seq[string]

  ConanBuild* = ref object
    ## Build type that stores build specific info and revisions
    bhash*: string
    settings*: TableRef[string, string]
    options*: TableRef[string, string]
    requires*: seq[string]
    recipe_hash*: string
    revisions*: seq[string]

const
  # Conan API urls
  conanBaseUrl = "https://conan.bintray.com/v2/conans"
  conanSearchUrl = conanBaseUrl & "/search?q=$query"
  conanPkgUrl = conanBaseUrl & "/$name/$version/$user/$channel/search$query"
  conanCfgUrl = conanBaseUrl & "/$name/$version/$user/$channel/revisions/$recipe/packages/$build/revisions"
  conanDlUrl = conanBaseUrl & "/$name/$version/$user/$channel/revisions/$recipe/packages/$build/revisions/$revision/files/$file"

  # Bintray download sub-URL for explicit `user/channel` (not _/_)
  conanDlAltUrl = "/download_file?file_path=$user%2F$name%2F$version%2F$channel%2F0%2Fpackage%2F$build%2F0%2F$file"

  # Strings
  conanInfo = "conaninfo.json"
  conanPackage = "conan_package.tgz"
  conanManifest = "conanmanifest.txt"

var
  # Bintray download URL for explicit `user/channel`
  conanBaseAltUrl {.compileTime.} = {
    "bincrafters": "https://bintray.com/bincrafters/public-conan",
    "conan": "https://bintray.com/conan-community/conan"
  }.toTable()

  # Reuse dependencies already downloaded
  gConanRequires {.compileTime.}: Table[string, ConanPackage]

proc addAltConanBaseUrl*(name, url: string) =
  # Add an alternate base URL for a custom conan repo on bintray
  conanBaseAltUrl[name] = url

proc jsonGet(url: string): JsonNode =
  # Make HTTP call and return content as JSON
  let
    temp = getTempDir()
    file = block:
      var
        file = temp / url.extractFilename()
      when defined(Windows):
        file = file.replace('?', '_')
      file

  downloadUrl(url, temp, quiet = true)
  try:
    result = readFile(file).parseJson()
  except JsonParsingError:
    discard
  rmFile(file)

proc `==`*(pkg1, pkg2: ConanPackage): bool =
  ## Check if two ConanPackage objects are equal
  (not pkg1.isNil and not pkg2.isNil and
    pkg1.name == pkg2.name and
    pkg1.version == pkg2.version and
    pkg1.user == pkg2.user and
    pkg1.channel == pkg2.channel and

    pkg1.arch == pkg2.arch and
    pkg1.os == pkg2.os and
    pkg1.compiler == pkg2.compiler and
    pkg1.compversion == pkg2.compversion and

    pkg1.bhash == pkg2.bhash and
    pkg1.shared == pkg2.shared)

proc newConanPackage*(name, version, user = "_", channel = "_", bhash = "", shared = true): ConanPackage =
  ## Create a new ConanPackage with specified name and version
  result = new(ConanPackage)
  result.name = name
  result.version = version
  result.user = user
  result.channel = channel
  result.recipes = newOrderedTable[string, seq[ConanBuild]](2)

  let
    (arch, os, compiler, compversion, libc) = getGccInfo()
  doAssert libc != "musl", "Conan does not provide precompiled binaries using musl"

  result.arch = arch
  result.os = os
  result.compiler = compiler
  result.compversion = compversion

  result.bhash = bhash
  result.shared = shared

proc newConanPackageFromUri*(uri: string, shared = true): ConanPackage =
  ## Create a new ConanPackage from a conan uri typically formatted as name/version[@user/channel][:bhash]
  var
    name, version, user, channel, bhash: string

    spl = uri.split(":")

  if spl.len > 1:
    bhash = spl[1]

  spl = spl[0].split('/')

  name = spl[0]
  user = "_"
  channel = "_"

  if spl.len > 2:
    channel = spl[2]
  if spl.len > 1:
    spl = spl[1].split('@')

    version = spl[0]
    if spl.len > 1:
      user = spl[1]

  result = newConanPackage(name, version, user, channel, bhash, shared)

proc getUriFromConanPackage*(pkg: ConanPackage): string =
  ## Convert a ConanPackage to a conan uri
  result = pkg.name
  if pkg.version.nBl:
    result &= "/" & pkg.version
  if pkg.user.nBl:
    result &= "@" & pkg.user
  if pkg.channel.nBl:
    result &= "/" & pkg.channel
  if pkg.bhash.nBl:
    result &= ":" & pkg.bhash

proc searchConan*(name: string, version = "", user = "", channel = ""): ConanPackage =
  ## Search for package by `name` and optional `version`, `user` and `channel`
  ##
  ## Search is quite slow so it is preferable to specify a version and use `getConanBuilds()`
  var
    query = name
  if version.nBl:
    query &= "/" & version
    if user.nBl:
      query &= "@" & user
      if channel.nBl:
        query &= "/" & channel

  gecho &"# Searching Conan.io for latest version of {name}"

  let
    j1 = jsonGet(conanSearchUrl % ["query", query])
    res = j1.getOrDefault("results").getElems()

  # Return latest comparing versions - prefer @_/_
  var
    latest = ""
    latestv = ""
  for i in 0 ..< res.len:
    let
      str = res[i].getStr()
    if "@_/_" in str:
      let
        ver = str.split('/')[1].split('@')[0]
      if latestv.Bl or compareVersions(ver, latestv) > 0:
        latestv = ver
        latest = str

  if latest.nBl:
    result = newConanPackageFromUri(latest)

proc searchConan*(pkg: ConanPackage): ConanPackage =
  ## Search for latest package based on incomplete package info
  result = searchConan(pkg.name, pkg.version, pkg.user, pkg.channel)

proc getConanBuilds*(pkg: ConanPackage, filter = "") =
  ## Get all builds for a package based on the C compiler's target OS/arch info
  ##
  ## `filter` can be used to tweak search terms
  ##    e.g. build_type=Debug&compiler=clang
  let
    vsplit = pkg.compversion.split('.')

    vfilter =
      when defined(OSX):
        vsplit[0 .. 1].join(".")
      else:
        vsplit[0]

    query =
      if pkg.bhash.Bl:
        block:
          var
            query = &"?q=arch={pkg.arch}&os={pkg.os.capitalizeAscii()}"
          if "build_type" notin filter:
            query &= "&build_type=Release"
          if "shared=" notin filter:
            query &= &"&options.shared={($pkg.shared).capitalizeAscii()}"
          if filter.nBl:
            query &= &"&{filter}"
          if "compiler=" notin filter and pkg.os != "windows":
            query &= &"&compiler={pkg.compiler}&compiler.version=" & vfilter
          if "compiler.runtime=" notin filter and pkg.os == "windows":
            query &= &"&compiler.runtime=MD"
          if "compiler.version=" notin filter and pkg.os == "windows":
            query &= &"&compiler.version=14"

          query.replace("&", "%20and%20")
      else: ""

    url = conanPkgUrl % [
      "name", pkg.name,
      "version", pkg.version,
      "user", pkg.user,
      "channel", pkg.channel,
      "query", query
    ]

    j1 = jsonGet(url)

  if not j1.isNil:
    for bhash, bdata in j1.getFields():
      if pkg.bhash.Bl or pkg.bhash == bhash:
        let
          bld = new(ConanBuild)
          settings = bdata.getOrDefault("settings")
          options = bdata.getOrDefault("options")
          requires = bdata.getOrDefault("requires")
        bld.bhash = bhash
        if not settings.isNil:
          bld.settings = newTable[string, string](8)
          for key, value in settings.getFields():
            bld.settings[key] = value.getStr()
        if not options.isNil:
          bld.options = newTable[string, string](8)
          for key, value in options.getFields():
            bld.options[key] = value.getStr()
        for req in requires.to(seq[string]):
          # Filter skipped dependencies
          if req.toLowerAscii() notin pkg.skipRequires:
            bld.requires.add req
        bld.recipe_hash = bdata.getOrDefault("recipe_hash").getStr()

        if pkg.recipes.hasKey(bld.recipe_hash):
          pkg.recipes[bld.recipe_hash].add bld
        else:
          pkg.recipes[bld.recipe_hash] = @[bld]

        # Only need first or matching build
        break

proc getConanRevisions*(pkg: ConanPackage, bld: ConanBuild) =
  ## Get all revisions of a build
  let
    url = conanCfgUrl % [
      "name", pkg.name,
      "version", pkg.version,
      "user", pkg.user,
      "channel", pkg.channel,
      "recipe", bld.recipe_hash,
      "build", bld.bhash
    ]

    j1 = jsonGet(url)

  if not j1.isNil:
    let
      revs = j1.getOrDefault("revisions")
    for i in revs:
      bld.revisions.add i.getOrDefault("revision").getStr()

proc loadConanInfo*(outdir: string): ConanPackage =
  ## Load cached package info from `outdir/conaninfo.json`
  let
    file = fixRelPath(outdir) / conanInfo

  if fileExists(file):
    when (NimMajor, NimMinor, NimPatch) < (1, 2, 0):
      result = to[ConanPackage](readFile(file))
    else:
      try:
        result = to(readFile(file).parseJson(), ConanPackage)
      except:
        discard

proc saveConanInfo*(pkg: ConanPackage, outdir: string) =
  ## Save downloaded package info to `outdir/conaninfo.json`
  let
    file = fixRelPath(outdir) / conanInfo

  when (NimMajor, NimMinor, NimPatch) < (1, 2, 0):
    writeFile(file, $$pkg)
  else:
    writeFile(file, $(%pkg))

proc parseConanManifest(pkg: ConanPackage, outdir: string) =
  # Get all library info from downloaded conan package
  let
    file = outdir / conanManifest

  if fileExists(file):
    let
      data = readFile(file)
    for line in data.splitLines():
      let
        line = line.split(':')[0]
      if line.startsWith("lib/"):
        if line.endsWith(".a") or line.endsWith(".lib"):
          pkg.staticLibs.add line
        elif line.endsWith(".so") or line.endsWith(".dylib"):
          pkg.sharedLibs.add line
      elif line.startsWith("bin/") and line.endsWith("dll"):
        pkg.sharedLibs.add line

proc dlConanBuild*(pkg: ConanPackage, bld: ConanBuild, outdir: string, revision = "") =
  ## Download specific `revision` of `bld` to `outdir`
  ##
  ## If omitted, the latest revision (first) is downloaded
  doAssert bld.revisions.nBl, "No build revisions found for Conan.io package " & pkg.getUriFromConanPackage()

  let
    outdir = fixRelPath(outdir)

    revision =
      if revision.nBl:
        revision
      else:
        bld.revisions[0]

    url =
      if pkg.user == "_":
        conanDlUrl % [
          "name", pkg.name,
          "version", pkg.version,
          "user", pkg.user,
          "channel", pkg.channel,
          "recipe", bld.recipe_hash,
          "build", bld.bhash,
          "revision", revision,
          "file", conanPackage
        ]
      else:
        conanBaseAltUrl[pkg.user] & conanDlAltUrl % [
          "name", pkg.name,
          "version", pkg.version,
          "user", pkg.user,
          "channel", pkg.channel,
          "build", bld.bhash,
          "file", conanPackage
        ]

  downloadUrl(url, outdir, quiet = true)
  downloadUrl(url.replace(conanPackage, conanManifest), outdir, quiet = true)

  pkg.parseConanManifest(outdir)

  rmFile(outdir / url.extractFilename())
  rmFile(outdir / conanManifest)

proc dlConanRequires*(pkg: ConanPackage, bld: ConanBuild, outdir: string)
proc downloadConan*(pkg: ConanPackage, outdir: string, main = true) =
  ## Download latest recipe/build/revision of `pkg` to `outdir`
  ##
  ## High-level API that handles the end to end Conan process flow to find
  ## latest package binary and downloads and extracts it to `outdir`.
  let
    outdir = fixRelPath(outdir)

    pkg =
      if pkg.version.Bl:
        searchConan(pkg)
      else:
        pkg

  if main:
    let
      cpkg = loadConanInfo(outdir)

    if cpkg == pkg:
      return

    cleanDir(outdir)

  pkg.getConanBuilds()

  doAssert pkg.recipes.nBl, &"Failed to download {pkg.name} v{pkg.version} from Conan - check https://conan.io/center"

  gecho &"# Downloading {pkg.name} v{pkg.version} from Conan.io"
  for recipe, builds in pkg.recipes:
    for build in builds:
      if pkg.bhash.Bl or pkg.bhash == build.bhash:
        pkg.getConanRevisions(build)
        pkg.dlConanBuild(build, outdir)
        pkg.dlConanRequires(build, outdir)
        break
    break

  if main:
    pkg.saveConanInfo(outdir)

proc dlConanRequires*(pkg: ConanPackage, bld: ConanBuild, outdir: string) =
  ## Download all required dependencies of this `bld`
  ##
  ## This is not required for shared libs since conan builds them
  ## with all dependencies statically linked in
  let
    outdir = fixRelPath(outdir)
  if bld.options["shared"] == "False":
    for req in bld.requires:
      let
        name = req.split('/')[0]
      if gConanRequires.hasKey(name):
        # Reuse dep already downloaded
        pkg.requires.add gConanRequires[name]
      else:
        let
          rpkg = newConanPackageFromUri(req, shared = false)
        rpkg.skipRequires = pkg.skipRequires

        downloadConan(rpkg, outdir, main = false)
        pkg.requires.add rpkg
        gConanRequires[name] = rpkg

proc getConanLDeps*(pkg: ConanPackage, outdir: string, main = true): seq[string] =
  ## Get all Conan libs - shared (.so|.dll) or static (.a|.lib) in pkg, including deps
  ## in descending order
  ##
  ## `outdir` is prefixed to each entry
  let
    libs = if pkg.shared: pkg.sharedLibs else: pkg.staticLibs
    str = if pkg.shared: "shared" else: "static"

  doAssert libs.nBl, &"No {str} libs found for {pkg.name} in {outdir}"

  if not main:
    for lib in libs:
      result.add outdir / lib

  for cpkg in pkg.requires:
    result.add cpkg.getConanLDeps(outdir, main = false)
