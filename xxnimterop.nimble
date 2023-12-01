# Package

version     = "0.6.14"
author      = "genotrance"
description = "C/C++ interop for Nim"
license     = "MIT"

bin = @["xxnimterop/toast", "xxnimterop/loaf"]
installDirs = @["xxnimterop"]

# Dependencies
requires "nim >= 2.0.0", "regex == 0.22.0", "cligen == 1.6.15"

import xxnimterop/docs
import os

proc execCmd(cmd: string) =
  exec "tests/timeit " & cmd

proc execTest(test: string, flags = "", runDocs = true) =
  execCmd "nim c --hints:off -f -d:checkAbi " & flags & " -r " & test
  let
    # -d:checkAbi broken in cpp mode until post 1.2.0
    cppAbi = when (NimMajor, NimMinor) >= (1, 3): "-d:checkAbi " else: ""
  execCmd "nim cpp --hints:off " & cppAbi & flags & " -r " & test

  if runDocs:
    let docPath = "build/html_" & test.extractFileName.changeFileExt("") & "_docs"
    rmDir docPath
    mkDir docPath
    buildDocs(@[test], docPath, nimArgs = "--hints:off " & flags)

task buildTimeit, "build timer":
  exec "nim c --hints:off -d:danger tests/timeit"

task buildLoaf, "build loaf":
  execCmd("nim c --hints:off -d:danger xxnimterop/loaf.nim")

task buildToast, "build toast":
  execCmd("nim c --hints:off -d:danger xxnimterop/toast.nim")

task bt, "build toast":
  buildToastTask()

task btd, "build toast":
  execCmd("nim c -g xxnimterop/toast.nim")

task docs, "Generate docs":
  buildDocs(@["xxnimterop/all.nim"], "build/htmldocs")

task minitest, "Test for Nim CI":
  exec "nim c -f -d:danger xxnimterop/loaf.nim"
  exec "nim c -f -d:danger xxnimterop/toast"
  exec "nim c -f -d:checkAbi -r tests/tast2.nim"
  exec "nim c -f -d:checkAbi -d:zlibJBB -d:zlibSetVer=1.2.11 -r tests/zlib.nim"

task basic, "Basic tests":
  execTest "tests/tast2.nim"
  execTest "tests/tast2.nim", "-d:NOHEADER"
  execTest "tests/tast2.nim", "-d:NOHEADER -d:WRAPPED"

  execTest "tests/tnimterop_c.nim"
  execTest "tests/tnimterop_c.nim", "-d:FLAGS=\"-H\""

  execCmd "nim cpp --hints:off -f -r tests/tnimterop_cpp.nim"
  execCmd "./xxnimterop/toast tests/toast.cfg tests/include/toast.h"

task wrapper, "Wrapper tests":
  execTest "tests/tpcre.nim"

  when defined(Linux):
    execTest "tests/rsa.nim"
    execTest "tests/rsa.nim", "-d:FLAGS=\"-H\""

  # Platform specific tests
  when defined(Windows):
    execTest "tests/tmath.nim"
    execTest "tests/tmath.nim",  "-d:FLAGS=\"-H\""
  if defined(OSX) or defined(Windows) or not existsEnv("TRAVIS"):
    execTest "tests/tsoloud.nim"
    execTest "tests/tsoloud.nim",  "-d:FLAGS=\"-H\""

task getheader, "getHeader tests":
  withDir("tests"):
    exec "nim e getheader.nims"

task package, "Wrapper package tests":
  if not existsEnv("APPVEYOR"):
    withDir("tests"):
      exec "nim e wrappers.nims"

task test, "Test":
  rmFile("tests/timeit.txt")

  buildTimeitTask()
  buildLoafTask()
  buildToastTask()

  basicTask()

  wrapperTask()

  getheaderTask()

  packageTask()

  docsTask()

  echo readFile("tests/timeit.txt")
