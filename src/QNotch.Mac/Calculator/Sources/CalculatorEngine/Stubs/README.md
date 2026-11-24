# Stubs

Placeholders for C# engine areas that are not ported yet. Each file lists exactly the API the core
(parser, evaluator, sheet evaluator) calls for one area. An area's port replaces its stub file with the
real Swift files (one per C# file, same base name) and keeps these names and signatures, or updates the
core call sites in the same change. Stub bodies throw `CalcError.notPorted`, so an unported line shows an
explicit error instead of a wrong value.
