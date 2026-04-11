# Package
version       = "0.3.0"
author        = "Ray Perry"
description   = "The Kintsugi Programming Language"
license       = "MIT"
srcDir        = "src"
bin           = @["kintsugi"]
binDir        = "bin"

# Dependencies
requires "nim >= 2.0.0"

task build, "Build the interpreter":
  exec "nim c -d:release --outdir:bin src/kintsugi.nim"

task test, "Run all tests":
  var failed: seq[string] = @[]
  for f in listFiles("tests"):
    if f.endsWith(".nim") and f.startsWith("tests/test_") and f != "tests/debug.nim":
      try:
        exec "nim c -r --outdir:bin/tests " & f
      except:
        failed.add(f)
  if failed.len > 0:
    echo "FAILED: " & $failed
    quit(1)
