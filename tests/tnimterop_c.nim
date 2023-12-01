import std/unittest
import os
import macros
import xxnimterop/cimport
import xxnimterop/paths

static:
  cDisableCaching()
  cAddSearchDir testsIncludeDir()

cDefine("FORCE")
cIncludeDir testsIncludeDir()
cCompile cSearchPath("test.c")

cPluginPath(getProjectPath() / "tnimterop_c_plugin.nim")

cOverride:
  type
    BITMAPINFOHEADER* {.bycopy.} = object
      biClrImportant*: int

    Random = object

    ABC = pointer

    GHI = object
      f2: ptr ptr cint

    JKL = object
      f2: ptr ptr cint

  const
    BIT* = 1

  proc weirdfunc(apple: ptr ptr ptr cchar): int {.importc.}
  proc weirdfunc2(mango: ptr ptr cchar): int {.importc.}

const FLAGS {.strdefine.} = ""
cImport(cSearchPath("test.h"), flags = FLAGS)

check TEST_INT == 512
check TEST_FLOAT == 5.12
check TEST_HEX == 0x512
check TEST_CHAR == 'a'
check TEST_STR == "hello world"

when defined(osx):
  check OSDEF == 10
elif defined(Windows):
  check OSDEF == 20
else:
  check OSDEF == 30

block:
  # workaround for https://github.com/nim-lang/Nim/issues/10129
  const ok = OSDEF

var
  pt: PRIMTYPE
  ct: CUSTTYPE
  cct: CCUSTTYPE

  s0: ptr STRUCT0
  s1: STRUCT1
  s2: STRUCT2
  s3: STRUCT3
  s4: STRUCT4
  s5: STRUCT5
  s51: struct5

  e: ENUM
  e2: ENUM2 = enum5
  e3 = enum7
  e4: ENUM4 = enum11

  vptr: VOIDPTR
  iptr: INTPTR

  u: UNION1
  u2: UNION2

  i: cint

pt = 3
ct = 4
cct = 5

s1.field1 = 5
s2.field1 = 6
s3.field1 = 7
s4.field2[2] = 5

# note: simplify with `defined(c)` for nim >= 0.19.9
when defined(cpp) and defined(OSX):
  discard
else:
  s4.field3[3] = enum1

s4.field6 = 1
s4.field6 += 1
check s4.field6 == 0

s5.tci = test_call_int
s5.tcp = test_call_param
s5.tcp8 = test_call_param8
s51.tci = test_call_int
s51.tcv = test_call9
check s5.tci() == 5
check s51.tci() == 5
check s51.tcv() == nil

e = enum1
e2 = enum4

u2.field2 = 'c'.byte

i = 5

check test_call_int() == 5
check test_call_param(5).field1 == 5
check test_call_param2(5, s2).field1 == 11
check test_call_param3(5, s1).field1 == 10
when defined(cpp) and defined(OSX):
  # error: assigning to 'enum ENUM' from incompatible type 'NI' (aka 'long long')
  discard
else:
  check test_call_param4(e) == e2
check test_call_param5(5.0).field2 == 5.0
check test_call_param6(u2) == 'c'.byte
u.field1 = 4
check test_call_param7(u) == 4

when defined(cpp) and defined(OSX):
   # note: candidate function not viable: no known conversion from 'NI *' (aka 'long long *') to 'int *' for 1st argument
  # check test_call_param8(cast[ptr int](addr i)) == 25.0
  discard
else:
  check test_call_param8(addr i) == 25.0
  check i == 25

check test_call9() == nil

check enum6a == 4
check enum6b == 5

check e3 == enum7
check e4 == enum11

check enum13 == 4
check enum14 == 9
check enum15 == 2
check enum17 == '\0'.ENUM7
check enum18 == 'A'.ENUM7

# Issue #58
multiline1()
let p = multiline2()
multiline3()

# Issue #52
var
  s6: struct6
  s6p: STRUCT6
  e6: enum6t
  e6p: ENUM6
  u3: union3
  u3p: UNION3
  k: uKernel
  kp: Kernel

## failing tests
when false:
  static: # Error: undeclared identifier: 'foobar1'
    doAssert foobar1(3) == OSDEF * 3
when false: # Error: undeclared identifier: 'foobar2'
    doAssert foobar2(3) == 3 + 1

# Double pointer
var
  dv: DVOIDPTR
  di: DINTPTR
  ds: dstruct
  cstr = "Hello".cstring
  ds2: DSTRUCT2

dv = addr vptr
di = addr iptr

ds.field1 = di
ds2.field1 = addr cstr
ds2.tcv = test_call10
check ds2.tcv(di) == nil

# Issue #131
check TDEFL_OUT_BUF_SIZE == 85196
check TDEFL_BOGUS_1 == 2
check TDEFL_BOGUS_2 == 1024
check TDEFL_BOGUS_3 == (85196 / 2).int

var
  arr: array[5, cint]

check test_array_param(arr) == nil

# cOverride

var
  ca = weirdfunc
  cb: BITMAPINFOHEADER
  cc = weirdfunc2
  cd: ABC
  ce: DEF
  cf: GHI
  cg: JKL

cd = nil
ce = 5
#TODO: Error: undeclared field: 'f2=' for type tnimterop_c.GHI [type declared in /home/akito/.cache/nim/xxnimterop/toastCache/nimterop_248128505.nim(191, 3)]
# cf.f2 = nil
# cg.f2 = nil

doAssert BIT == 1
doAssert ca(nil) == 1
doAssert cc(nil) == 2
doAssert SDLK_UNDERSCORE == 95