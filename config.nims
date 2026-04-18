# --- macOS build workarounds ---
# 1. Nim 2.2.x global nim.cfg adds `-ldl` on all Unix; libdl does not exist on
#    macOS (dlopen lives in libSystem). Override to empty.
# 2. If Homebrew's llvm@N clang is first in PATH, it bakes in a
#    non-existent CommandLineTools SDK path (`-syslibroot .../MacOSX12.sdk`)
#    that overrides any `-isysroot` we pass. Force Apple's clang so the SDK
#    resolves correctly.
when defined(macosx):
  switch("clang.exe", "/usr/bin/clang")
  switch("clang.linkerexe", "/usr/bin/clang")
  switch("clang.cpp.exe", "/usr/bin/clang++")
  switch("clang.cpp.linkerexe", "/usr/bin/clang++")
  switch("clang.options.linker", "")
  switch("gcc.options.linker", "")
