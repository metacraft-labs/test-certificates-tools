## The ``test-certificates`` executable: the process's arguments and streams
## handed to ``runCli``, and its answer handed back as the exit status. All
## behaviour lives in the library (``test_certificates/cli``).

import std/os
import test_certificates/cli

when isMainModule:
  quit runCli(commandLineParams(), CliIo(input: stdin, output: stdout, errors: stderr))
