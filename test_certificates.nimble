# Package

version = "0.1.0"
author = "Metacraft Labs"
description = "Reference helper tooling for the test-certificate standard: the local certificate store as a Nim library and the test-certificates command"
license = "Apache-2.0"
srcDir = "src"
installExt = @["nim"]
namedBin["test_certificates_cli"] = "test-certificates"

# Dependencies

# Nothing beyond the Nim standard library, deliberately: producers and
# frameworks link this package, and a store helper that drags a dependency
# tree along is one fewer of them will.
requires "nim >= 2.2.0"
