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

proc buildCli() =
  exec "nim c -d:release --outdir:bin src/kintsugi.nim"  

proc buildWeb() =
  exec "nim js -d:release --outdir:web src/kintsugi_js.nim"

task build, "Build everything":
  buildCli()
  buildWeb()

task build-cli, "Build the interpreter":
  buildCli()
  
task build-web, "Build the JS bundle for the web playground":
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
