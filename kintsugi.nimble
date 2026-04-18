# Package
include "src/core/version"
version       = VERSION
author        = "Ray Perry"
description   = "The Kintsugi Programming Language"
license       = "MIT"
srcDir        = "src"
bin           = @["kintsugi"]
binDir        = "bin"

# Dependencies
requires "nim >= 2.0.0"

proc buildCli() =
  exec "nim c -d:release --outdir:bin src/kintsugi.nim"

proc buildWeb() =
  exec "nim js -d:release --outdir:web src/kintsugi_js.nim"

# `bin` declaration means nimble's built-in `build` handles CLI and shadows any
# user-defined `task build`. Expose CLI and web as explicit tasks, plus `all`.
task cli, "Build CLI only":
  buildCli()

task web, "Build web JS bundle":
  buildWeb()

task all, "Build CLI + web":
  buildCli()
  buildWeb()


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
