import os

import "."/build/shell

const
  cacheDir* = getProjectCacheDir("xxnimterop", forceClean = false)

proc nimteropRoot*(): string =
  currentSourcePath.parentDir.parentDir

proc nimteropSrcDir*(): string =
  nimteropRoot() / "xxnimterop"

proc toastExePath*(): string =
  nimteropSrcDir() / ("toast".addFileExt ExeExt)

proc testsIncludeDir*(): string =
  nimteropRoot() / "tests" / "include"
