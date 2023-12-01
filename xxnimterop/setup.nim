import os, strutils

import "."/[paths]
import "."/build/[shell]

proc treesitterSetup*() =
  gitPull("https://github.com/tree-sitter/tree-sitter", cacheDir / "treesitter", """
lib/include/*
lib/src/*
""", "0.16.8")

  let
    tbase = cacheDir / "treesitter" / "lib"
    stack = tbase / "src" / "stack.c"
    parser = tbase / "include" / "tree_sitter" / "parser.h"
    tparser = parser.replace("parser", "tparser")
    language = tbase / "src" / "language.h"
    lexer = tbase / "src" / "lexer.h"
    subtree = tbase / "src" / "subtree.h"

  stack.writeFile(stack.readFile().replace("inline Stack", "Stack"))

  # parser.h
  mvFile(parser, tparser)
  language.writeFile(language.readFile().replace("parser.h", "tparser.h"))
  lexer.writeFile(lexer.readFile().replace("parser.h", "tparser.h"))
  subtree.writeFile(subtree.readFile().replace("parser.h", "tparser.h"))

proc treesitterCSetup*() =
  gitPull("https://github.com/tree-sitter/tree-sitter-c", cacheDir / "treesitter_c", """
src/*.h
src/*.c
src/*.cc
src/tree_sitter/parser.h
""", "0.16.1")

proc treesitterCppSetup*() =
  gitPull("https://github.com/tree-sitter/tree-sitter-cpp", cacheDir / "treesitter_cpp", """
src/*.h
src/*.c
src/*.cc
src/tree_sitter/parser.h
""", "v0.16.0")
