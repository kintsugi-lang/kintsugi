## Integration tests for CLI entry points

import std/unittest
import std/osproc
import std/strutils
import std/os

const binPath = "bin/kintsugi"

# Build first if needed
proc ensureBuild() =
  if not fileExists(binPath):
    let (_, exitCode) = execCmdEx("nimble build")
    doAssert exitCode == 0, "Failed to build kintsugi"

suite "CLI: -e flag":
  setup:
    ensureBuild()

  test "evaluate expression":
    let (output, code) = execCmdEx(binPath & " -e \"1 + 2\"")
    check code == 0

  test "evaluate print":
    let (output, code) = execCmdEx(binPath & " -e \"print 42\"")
    check code == 0
    check "42" in output

  test "evaluate string expression":
    let (output, code) = execCmdEx(binPath & """ -e "print \"hello\"" """)
    check code == 0
    check "hello" in output

suite "CLI: -c --dry-run":
  setup:
    ensureBuild()

  test "dry-run emits Lua to stdout":
    # Create a temp .ktg file
    let tmpFile = getTempDir() / "test_cli_dryrun.ktg"
    writeFile(tmpFile, "x: 42")
    defer: removeFile(tmpFile)
    let (output, code) = execCmdEx(binPath & " -c " & tmpFile & " --dry-run")
    check code == 0
    check "local x = 42" in output

  test "dry-run with function":
    let tmpFile = getTempDir() / "test_cli_fn.ktg"
    writeFile(tmpFile, "add: function [a b] [a + b]")
    defer: removeFile(tmpFile)
    let (output, code) = execCmdEx(binPath & " -c " & tmpFile & " --dry-run")
    check code == 0
    check "function add(a, b)" in output

suite "CLI: file execution":
  setup:
    ensureBuild()

  test "run .ktg file":
    let tmpFile = getTempDir() / "test_cli_run.ktg"
    writeFile(tmpFile, "print 99")
    defer: removeFile(tmpFile)
    let (output, code) = execCmdEx(binPath & " " & tmpFile)
    check code == 0
    check "99" in output

  test "nonexistent file errors":
    let (output, code) = execCmdEx(binPath & " /tmp/does_not_exist_12345.ktg")
    check code != 0

suite "CLI: -c compile to file":
  setup:
    ensureBuild()

  test "compile produces .lua file":
    let tmpFile = getTempDir() / "test_cli_compile.ktg"
    let outFile = getTempDir() / "test_cli_compile.lua"
    writeFile(tmpFile, "x: 42\nprint x")
    defer:
      removeFile(tmpFile)
      removeFile(outFile)
    let (output, code) = execCmdEx(binPath & " -c " & tmpFile & " -o " & outFile)
    check code == 0
    check fileExists(outFile)
    let lua = readFile(outFile)
    check "local x = 42" in lua
